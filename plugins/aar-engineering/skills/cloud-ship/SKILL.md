---
name: cloud-ship
description: >-
  Ship a scaffold/product change whose AUTHOR + cross-family REVIEW legs run on a Claude Code cloud VM, with a
  gated bot close on the box. The sibling of ship-change for the two-machine case: the cloud VM authors the
  change and runs the foreign-family (codex) review, then STOPS at a pushed branch + a machine-readable
  CLOUD-SHIP RUN record comment (a cloud VM has no engineer keys — it can neither open the bot PR nor cast the
  opposite-family native approval). The box (which holds the engineer-App keys) runs close-cloud-ship.sh to
  GATE on that record + the live branch head (fail-closed: refuse unless Verdict PASS, branch matches, and the
  head is still the reviewed sha), then opens the PR as the authoring bot, approves as the opposite-family
  bot, and squash-merges pinned to the reviewed sha. Reuses ship-change's engineer-identity seams
  (WF_ENGINEER_TOKEN_CMD_CLAUDE/CODEX); invents no new config. Use when the author+review must run on a cloud
  VM (a big change that wants a fresh isolated context) rather than in-process on the box.
---

# cloud-ship — cloud dispatch + gated box-side close

The **two-machine** sibling of `ship-change`. Where `ship-change` runs the whole lifecycle in one place
(`wf.sh`: worktree → reviews → merge, with the engineer keys on that box), `cloud-ship` splits it across the
machine boundary:

- **The cloud VM** (a Claude Code `--remote` session) AUTHORS the change and runs the cross-family (codex)
  review to `VERDICT: PASS`, pushes the branch, and posts a `CLOUD-SHIP RUN` record — then stops.
- **The box** (which holds the engineer-App merge keys) GATES on that record and does the bot
  PR/approve/merge.

It belongs to the **SWE pipeline** layer (see `AGENTS.md`), same as `ship-change`, and reuses the same
engineer-identity seams and cross-family philosophy. It is a **separate skill, not a `wf.sh` mode**, because
the two halves run on different machines with no shared in-process state, connected only by an async GitHub
comment — see `proposals/18-cloud-ship.md` for the full design and the load-bearing choices.

## Why the split is forced (not a preference)

A cloud VM has **no engineer/bot keys** by construction. So the cloud leg **cannot**:
- mint a bot token → it cannot open the PR as the authoring bot, and
- cast the **opposite-family native approval** branch protection requires (the connecting human can't
  approve his own cloud PR either — GitHub forbids self-approval).

Therefore the cloud leg **must** stop at a pushed branch + a machine-readable record, and the box **must**
decide from that record alone whether to merge. The record + the pushed branch are the ONLY completion
signals — there is no transcript readback from the cloud session.

## The two halves (both are box-runtime bash)

### 1. Dispatch (on the box) — `scripts/dispatch-cloud-ship.sh`

```
dispatch-cloud-ship.sh -R <owner/repo> -i <issue> -b <branch> -s <spec-file|-> [-C <clone-dir>] [--dry-run]
```

Fills `scripts/cloud-ship-brief.tmpl` (literal substitution of `@@REPO@@`/`@@ISSUE@@`/`@@BRANCH@@`/`@@SPEC@@`
— the spec may contain any shell metacharacters, so it is never `eval`/`envsubst`'d), runs the **GitHub App
preflight**, and launches `claude --remote "$(cat <brief>)"`.

- **TTY mechanics (load-bearing):** the launch is run **directly, with no pipe**. `claude --remote` detects
  an interactive TTY to attach the session; piping it (`... | tee`) makes stdout a non-TTY and the launch
  silently degrades. Capture the brief **file** if you want a copy; never capture the launch.
- **App preflight, fail-closed:** launch from a **clean, repo-associated clone** of the target repo. If the
  Claude Code GitHub App isn't installed / the clone isn't associated, the cloud session **bundles** its work
  and can **never push** — an unrecoverable run. The launcher refuses to dispatch unless the launch clone's
  `origin` is the target repo, the tree is clean, and `repos/<repo>` is reachable.

The cloud session then runs the brief: codex `CODEX-WORKS` check → branch + bot commit identity → implement →
adversarial codex review to `VERDICT: PASS` → `.aar-ci` checks → push → post the record → final report. It
**never opens a PR, never touches main**, prints progress, and reports which fallbacks fired.

### 2. Close (on the box) — `scripts/close-cloud-ship.sh`

```
close-cloud-ship.sh gate  <record-file> <remote-head> <branch>          # pure, offline, fail-closed
close-cloud-ship.sh close -R <owner/repo> -i <issue> -b <branch> [-a claude|codex]
```

`close` reads the latest `CLOUD-SHIP RUN` issue comment (ambient **read-only** gh), reads the live branch
head via `git ls-remote`, and runs the **gate** (fail-closed):

- Verdict is exactly `PASS`; `Reviewed-Head` is a 40-hex sha; record `Branch` equals the requested branch
  (**anti-replay** — a PASS record copied from another branch can't authorize this one); live branch head
  **equals** `Reviewed-Head` (**anti-post-review-push** — the box merges only the reviewed sha).

Only on a clean gate does `close` proceed, in this order:

1. **Ready-only close-gate** (replicated from `ship-change`, fail-closed BEFORE any PR/approve): the closing
   issue must be disposition `ready`; `WF_ALLOW_NONREADY_CLOSE=1` is the same documented override `wf.sh`
   honors. `Closes #<issue>` is same-repo by construction.
2. Mint the **authoring-family** bot token → `gh pr create` (title = the reviewed commit subject; body links
   the record + `Closes #<issue>`).
3. Copy the record comment verbatim onto the PR (the durable review trail, as `ship-change` posts).
4. Mint the **opposite-family** bot token → native `--approve` (the author bot cannot self-approve).
5. `gh pr merge --squash --delete-branch --match-head-commit <Reviewed-Head>` as the authoring bot — the
   `--match-head-commit` pin **aborts** if the head moved between the gate and the merge (closing the TOCTOU
   window exactly as `finish` does). Branch deletion happens here, at merge time — never mid-session.

**Engineer identity — no new config.** Token minting consumes the SAME seams `wf.sh` uses:
`WF_ENGINEER_TOKEN_CMD_CLAUDE` / `WF_ENGINEER_TOKEN_CMD_CODEX` (legacy `WF_REVIEWER_TOKEN_CMD` alias for
codex), fresh per use, fail-closed on a missing/empty token. `close-cloud-ship.sh` does **not** source
`wf.sh` (that is a top-level `case` dispatch, not a sourceable library); it re-expresses the ~5-line mint
mechanic while reusing the seam **names** verbatim. See `RUNBOOK.md` for the engineer-App wiring.

## The record contract (the seam between the halves)

The single machine-readable comment the cloud leg posts and the box reads is specified in
`references/RECORD.md`. Its header lines (`Branch:` / `Reviewed-Head:` / `Verdict:`) are the machine seam;
the review text below is the audit trail the box copies onto the PR.

## Constraints encoded (from the #304 → PR #307 proof)

- Cloud writes are always the **connecting user** (bots can't act from cloud; the human can't approve his own
  cloud PR). Don't wire a bot token into the cloud brief expecting it to work.
- **No transcript readback** — the record comment + the pushed branch ARE the completion signals.
- **Never delete the remote branch mid-session** (a stale-ref 403 race); deletion is `gh pr merge
  --delete-branch`'s job at merge time.
- **Box = fallback policy.** If the record is absent, malformed, non-PASS, names a different branch, or the
  head moved, the box **refuses and does nothing** — there is no "cloud said it was fine" override.

## Composes

- **ship-change** — the single-machine sibling; `cloud-ship` reuses its engineer seams + `RUNBOOK.md` App
  wiring, and its close mirrors `finish`'s pinned-sha merge + ready-only close-gate.
- **gh** — the ambient credential must be **read-only** (record + label reads); every write goes through the
  minted engineer bot tokens.
- **`.aar-ci/checks.sh`** — runs `close_cloud_ship_smoke.sh` (the offline gate smoke) when the cloud-ship
  scripts change.
