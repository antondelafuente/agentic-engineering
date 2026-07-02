# cloud-ship: productize cloud dispatch + gated box-side close

## Problem

`ship-change` assumes ONE machine: `wf.sh` opens a worktree, runs the cross-family reviews, and merges,
all with the engineer-App private keys on that box. But the highest-leverage way to run the author+review
legs is on a **Claude Code cloud VM** — a fresh, isolated container that can hold a big change in one
context and run codex as the foreign reviewer — while the **box** (which holds the bot merge keys) does the
gated PR/approve/merge. That split was hand-rolled twice to prove it end-to-end (automated-researcher #304
→ PR #307): a **dispatch brief** pasted into `claude --remote`, and a **box-side close script** that read a
hand-written record comment and drove the bot PR. Neither is a product piece; both are load-bearing and
easy to get subtly wrong (a `| tee` that breaks TTY detection; a close that merges work the reviewer never
saw). This change turns the two hand-rolled halves into proper `aar-engineering` pieces, following the
repo's conventions, so a zero-context agent can run the flow without re-deriving it.

The cloud VM has **no engineer keys** by construction — it cannot mint a bot token, so it can neither open
the PR nor cast the opposite-family native approval branch protection requires. The connecting human can't
approve his own cloud PR either (GitHub forbids self-approval). So the cloud leg must **stop at a pushed
branch + a machine-readable record**, and a **box-side gate** must decide, from that record alone, whether
the work is safe to merge as the bots. The seam between the two halves is the load-bearing contract.

## Approach

Add a **new sibling skill `cloud-ship`** in the `aar-engineering` plugin (`skills/cloud-ship/`), alongside
`ship-change`, with three box-runtime bash scripts and one offline smoke:

- `scripts/cloud-ship-brief.tmpl` — the dispatch brief, parameterized by `@@REPO@@` / `@@ISSUE@@` /
  `@@BRANCH@@` / `@@SPEC@@`. This is the templatized form of the very brief that ran #304 and this change:
  environment facts → codex setup + `CODEX-WORKS` check → branch + bot commit identity → the change spec →
  adversarial codex review loop to `VERDICT: PASS` → push → post the `CLOUD-SHIP RUN` record → final report.
- `scripts/dispatch-cloud-ship.sh` — runs on the box. Fills the template, runs the **GitHub App preflight**,
  and launches `claude --remote` with the correct TTY mechanics. The launcher, not the cloud agent, owns the
  preflight because a failed preflight means the cloud session can never push.
- `scripts/close-cloud-ship.sh` — runs on the box. A fail-closed **gate** (`gate` subcommand, offline,
  smoke-tested) plus the **close** path (`close` subcommand) that mints the bot tokens and drives
  PR/approve/merge, consuming the SAME `WF_ENGINEER_*` seams `wf.sh` already uses.
- `scripts/close_cloud_ship_smoke.sh` — offline smoke over every gate refuse path (no network), wired into
  `.aar-ci/checks.sh` by the same per-file-trigger pattern the other smokes use.

### Shape: new sibling skill (recommended), NOT a mode inside ship-change

`cloud-ship` is a **sibling skill in the same plugin**, not a new subcommand family inside `wf.sh` and not a
new plugin. The deciding factor is the **machine boundary**:

- `wf.sh`'s whole design is a **single-machine worktree lifecycle** with in-process state (the worktree path,
  the merge-base, the disposition cache under the gitdir) threaded through `start → open → …-review →
  finish`. The cloud flow has **no shared state across the boundary**: the author/review leg runs in an
  ephemeral cloud container and the close leg runs on the box minutes-to-hours later, connected only by an
  async GitHub comment. Folding cloud verbs into `wf.sh` would mean adding a stateless, keyless,
  worktree-less code path into a 2400-line driver built on the opposite assumptions — the seam every reader
  would then have to hold in their head.
- The two halves are **box-runtime self-contained bash**, invoked by an operator on the box, not steps an
  agent runs between judgment calls. `ship-change`'s SKILL.md is "you do the judgment BETWEEN these
  subcommands"; `cloud-ship`'s dispatch/close are "the operator runs these two commands and the cloud agent
  does the judgment on the other machine." Different actor, different runtime — a different skill.
- A **whole new plugin** is wrong the other way: `cloud-ship` reuses `aar-engineering`'s engineer-identity
  seams, its cross-family philosophy, and (transitively) its packaged `DISPOSITIONS.md`. A new plugin would
  duplicate that packaging and split one pipeline across two install units for no benefit.

So: same plugin (shares the seams + the SWE-pipeline layer), separate skill (different actor + runtime +
statelessness). `wf.sh` is untouched — which also keeps its dense composition smokes (locate-audit,
gh-guard, identity, …) out of scope.

### The dispatch half (runs on the BOX)

`dispatch-cloud-ship.sh -R <owner/repo> -i <issue> -b <branch> --spec <file|->` does three things:

1. **Fill the brief.** Read `cloud-ship-brief.tmpl`, substitute `@@REPO@@`/`@@ISSUE@@`/`@@BRANCH@@`/`@@SPEC@@`.
   Substitution is literal (the spec can contain any shell metacharacters — never `eval`/`envsubst` it).
2. **GitHub App preflight — fail closed.** Launch from a **clean, repo-associated clone** of `<repo>` (a
   checkout whose `origin` points at the target and that is associated with the Claude Code GitHub App). If
   the app isn't installed / the clone isn't associated, the cloud session **bundles** its work and can
   **never push** — so a wasted, unrecoverable run. The launcher verifies association up front and refuses
   to dispatch otherwise, with the fix (install the app on `<repo>`) in the message.
3. **Launch with correct TTY mechanics.** `claude --remote "$(cat "$brief")"` run **directly** — no
   `| tee`, no pipe. `claude --remote` detects an interactive TTY to attach the session; a pipe makes stdout
   a non-TTY and the launch silently degrades (no attach). The script documents and enforces this: it writes
   the filled brief to a file and execs `claude --remote "$(cat brief)"` without redirection. (Capture the
   brief in the file if you want a copy; do not capture the launch.)

The cloud agent then runs the brief autonomously: never opens a PR, never touches `main`, prints progress,
and reports which fallbacks fired. Its terminal deliverables are the **pushed branch** and the **record
comment** — see the record contract.

### The close half (runs on the BOX)

`close-cloud-ship.sh` has two subcommands so the gate is testable in isolation:

- `close-cloud-ship.sh gate <record-file> <remote-head> <branch>` — the **pure, offline gate**. Refuses
  unless: the record is a well-formed `CLOUD-SHIP RUN` block, its `Verdict:` is exactly `PASS`, its
  `Reviewed-Head:` is a 40-hex sha, its `Branch:` **equals** the requested `<branch>`, and `<remote-head>`
  (the actual current branch head) **equals** `Reviewed-Head`. Prints `CLOUD-SHIP-GATE: PASS` (exit 0) or
  `CLOUD-SHIP-GATE: REFUSE <reason>` (exit 2). Fail-closed: any missing field, non-`PASS` verdict, malformed
  sha, **branch mismatch**, or head mismatch → REFUSE.
  - The head-equality check is the **anti-post-review-push** guard: if someone pushed a commit AFTER the
    reviewed sha, the branch head moves off `Reviewed-Head` and the gate refuses — the box only ever merges
    the exact reviewed sha.
  - The branch-equality check is the **anti-record-replay** guard: a `PASS` record copied from another
    branch (whose `Reviewed-Head` might happen to be reachable/current elsewhere) cannot be used to close a
    different branch — the gate binds the record to the branch it names.
- `close-cloud-ship.sh close -R <owner/repo> -i <issue> -b <branch>` — the **full close**. Reads the latest
  issue comment beginning `CLOUD-SHIP RUN` (as the ambient read-only gh), fetches the current branch head
  via `git ls-remote <repo> refs/heads/<branch>`, runs `gate` on `(record, remote-head, branch)`, and only
  on PASS:
  1. **replicate `ship-change`'s close-gate** (fail-closed, BEFORE any PR/approve): the closing issue
     `#<issue>` must carry disposition `ready` — read its labels as the ambient read-only gh and refuse
     otherwise (`WF_ALLOW_NONREADY_CLOSE=1` is the same documented override `wf.sh` honors). `<issue>` is in
     `<repo>`, so `Closes #<issue>` is same-repo by construction; the script rejects an `-R`/issue pairing
     that would force a cross-repo `Closes` (drop the keyword to a mention), exactly as `finish` refuses a
     cross-repo closing ref;
  2. mint the **authoring-family** bot token (default `claude`, since the cloud author is Claude) →
     `gh pr create --head <branch> --base main` with title = the branch head commit subject and body linking
     the record comment + `Closes #<issue>`;
  3. copy the record comment verbatim onto the PR (the review trail lands on the PR, as `ship-change` does);
  4. mint the **opposite-family** bot token → `gh pr review --approve` (the cross-family native approval
     branch protection requires — the author bot cannot self-approve);
  5. **re-read the remote head and pin the merge to `Reviewed-Head`**: `gh pr merge --squash
     --delete-branch --match-head-commit <Reviewed-Head>` as the **authoring** bot. `--match-head-commit`
     aborts the merge if the head moved between the gate and the merge (a push in that window), so the
     **TOCTOU** window is closed exactly the way `finish` closes it — the box only ever squash-merges the
     precise reviewed sha, never "whatever is on the branch now".

**Seam reuse — no new config.** Token minting mirrors `wf.sh` exactly and invents nothing: the authoring bot
token comes from `WF_ENGINEER_TOKEN_CMD_CLAUDE` (with `WF_ENGINEER_TOKEN_CMD_CODEX`, legacy alias
`WF_REVIEWER_TOKEN_CMD`, for the opposite side), read via the same `family_suffix` → `WF_ENGINEER_TOKEN_CMD_<FAM>`
lookup, minted fresh per use, fail-closed on missing/empty. The script re-expresses the *minimal* mint
mechanic in self-contained bash (`eval "$cmd"`, require non-empty) because `wf.sh` is a top-level `case`
dispatch, **not** a sourceable library — sourcing it would execute the dispatch. This is deliberate
duplication of ~5 lines of mechanic, not of the *config*: the env-var names are the ship-change seams,
so an instance wires the bots once and both `wf.sh` and `close-cloud-ship.sh` consume them.

### The record contract (the machine-readable seam between the halves)

The cloud agent posts, and the box reads, exactly one comment shape on the issue:

```
CLOUD-SHIP RUN (do not merge by hand — box closes the loop)
Branch: <branch>
Reviewed-Head: <40-hex sha of the final reviewed commit>
Verdict: PASS
Rounds: design=<n> code=<n>

<final codex design-review verdict text>

<final codex code-review text>
```

The parseable header lines (`Branch:` / `Reviewed-Head:` / `Verdict:`) are the machine seam; the review text
below is the durable human/audit trail the box copies onto the PR. `Reviewed-Head` pins the merge to a sha,
not "latest" — the gate's head-equality check makes a post-review push fail closed rather than sneak in.

### Known constraints encoded (from the #304 → #307 proof)

- **Cloud writes are always the connecting user.** Bots cannot act from the cloud VM (no keys there); the
  human cannot approve his own cloud PR (self-approval is forbidden). Hence the split: cloud pushes the
  branch + posts the record as the connecting user; the box mints the bots and does PR/approve/merge. The
  SKILL.md states this so no one wires a bot token into the cloud brief expecting it to work.
- **No transcript readback.** The box cannot read the cloud session's transcript. The **record comment +
  the pushed branch ARE the only completion signals** — which is exactly why the record is a strict,
  parseable contract and the gate keys off it alone.
- **Never delete remote branches mid-session.** Deleting the remote branch while the cloud session may still
  reference it races GitHub's stale-ref cache (a 403). The close path lets `gh pr merge --delete-branch` do
  the deletion **at merge time**; nothing deletes the branch earlier.
- **Box = fallback policy.** The box is the authority when the halves disagree: if the record is absent,
  malformed, non-PASS, or the head moved, the box **refuses and does nothing** (fail-closed) rather than
  guessing. There is no "cloud said it was fine" override.

## Alternatives considered

- **A `cloud` mode inside `wf.sh`** (e.g. `wf.sh cloud-dispatch` / `wf.sh cloud-close`). Rejected above:
  it forces a stateless/keyless/worktree-less path into a driver built on the opposite assumptions, and it
  drags `wf.sh`'s whole composition-smoke surface into a change that is conceptually separate. The sibling
  skill keeps each script small and box-local.
- **A new `cloud-ship` plugin.** Rejected: it would duplicate `aar-engineering`'s seam wiring and packaged
  `DISPOSITIONS.md`, and split one SWE pipeline across two install units. `cloud-ship` is the same pipeline
  run across two machines, not a second product.
- **Have the close script `source wf.sh` to reuse `engineer_token`/`gh_author`.** Not possible cleanly:
  `wf.sh` runs its `case` dispatch at top level (no `main` guard), so sourcing executes it. Re-expressing
  the ~5-line mint mechanic while reusing the exact env-seam *names* is the pragmatic seam-reuse.
- **Gate on "latest branch head" instead of pinning `Reviewed-Head`.** Rejected: it would merge a
  post-review push the foreign reviewer never saw — the exact fail-open the head-equality check closes.
- **Let the cloud VM open the PR (draft) and the box only approve+merge.** Rejected: the cloud VM has no
  engineer token, so it can't open the PR as a bot; a PR opened as the connecting human then needs the human
  to *not* be the approver, and muddles who authored it. Cleaner to keep the cloud leg to push + record and
  let the box own every bot GitHub action.

## Blast radius

- **Additive**: a new skill directory + one edit to `.aar-ci/checks.sh` (a new per-file smoke trigger,
  mirroring sections 7–11) + the `aar-engineering` plugin version bump. `wf.sh`, `verify-claims`,
  `ship-change`'s scripts, and `AGENTS.md` are **untouched** — so no existing lifecycle behavior changes and
  no wf.sh composition smoke is affected.
- The new scripts are **box-runtime**: they run only when an operator invokes dispatch/close. They add no
  code to any auto-merge path and cannot regress `ship-change`.
- The fake-HOME behavior smoke will now also resolve the new `cloud-ship` skill (frontmatter name +
  description), which the change provides.

## Rollout + rollback

Land as one PR. The skill is inert until an operator runs `dispatch-cloud-ship.sh` / `close-cloud-ship.sh`,
so landing it changes nothing for existing `ship-change` users. Rollback is a plain revert of this PR
(remove the skill dir + the checks.sh trigger + restore the version); nothing else references it.
Instance wiring (the engineer Apps + `WF_ENGINEER_TOKEN_CMD_*`) is the same wiring `ship-change` already
needs — no new instance config to provision or tear down.
