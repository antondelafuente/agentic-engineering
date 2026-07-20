# RUNBOOK — aar-engineering workflow operations

Operational record for the GitHub-backed scaffold-change lifecycle (`ship-change` / `wf.sh`): the **as-built
enforcement config** now in force, the **escape hatches** if the automation wedges (the load-bearing part),
and token rotation. Branch protection is a **repo-wide gate** — if the reviewer identity or a rule breaks it
can block EVERY merge — so the escape hatches matter as much as the config.

## What's enforced (as-built)

The repo is **public**, and branch protection on `main` is **active** with:

- **Require a pull request before merging.**
- **Require 1 approving review** — satisfied by a cross-family native engineer review (author identity ≠
  reviewer identity, so GitHub allows it). The driver posts `--code` as an Approve (clean) / Request-changes
  (findings); only `finish`'s final-SHA review approves.
- **Dismiss stale approvals when new commits are pushed** — an approval is bound to its reviewed SHA.
- **Require conversation resolution** — our reviews post as review *bodies* (not line threads), so nothing
  to resolve in practice; if it ever blocks a clean merge, drop just this rule (see escape hatches).
- **Block force pushes + block deletions** on `main`.
- **Include administrators (`enforce_admins`)** — **ON**. This is load-bearing: any ambient admin token used by
  the driver must still have an opposite-family approval to merge.
- **Require status checks** — the `checks` context (the `checks.yml` Action, which runs `.aar-ci/checks.sh`
  on the PR's changed paths) is a **required** GitHub-reported status on `main`, in addition to the
  `.aar-ci` checks + behavior smoke that already run driver-side in `finish` before the approval.

## Engineer identities (as-built)

- **`codex-engineer`** — a GitHub App, installed on `agentic-engineering`. It can author Codex work and review
  Claude-authored changes. This instance currently exposes its token through the legacy `WF_REVIEWER_TOKEN_CMD`
  seam, which `wf.sh` treats as a fallback alias for `WF_ENGINEER_TOKEN_CMD_CODEX`.
- **`claude-engineer`** — a GitHub App, installed on `agentic-engineering` (its token seam `WF_ENGINEER_TOKEN_CMD_CLAUDE`
  + `WF_ENGINEER_GIT_AUTHOR_CLAUDE` are wired on this box). It authors Claude work and reviews Codex-authored
  changes — verified live: it posted the cross-family reviews on PR #57 and authored issue #62 (both read as
  `claude-code-engineer[bot]` / `app/claude-code-engineer`).
- **Permissions: `contents: write` + `pull_requests: write`.** ⚠️ **Gotcha (cost a round-trip):** an App's
  approval only **counts** toward "require approvals" if the App has **`contents: write`**. With
  `pull_requests: write` *alone* it can *post* a review, but it reads as `author_association: NONE` and the
  approval does **not** satisfy the gate (`reviewDecision: REVIEW_REQUIRED`). Grant `contents: write` and
  re-accept the installation's permission request.
- **`issues: read` — only for PRIVATE installs.** The close-gate (`finish` enforcing the close
  contract, #50/#85) reads each closing issue's disposition labels. On a **public** repo (like `automated-researcher`)
  this works under the existing `contents`+`pull_requests` perms — no change needed. A **private** install must
  add **`issues: read`** to both engineer Apps (+ re-accept), or the gate fails closed and blocks every merge.
- **`issues: write` — for `wf.sh issue` (agent-filed Issues, #89).** `wf.sh issue <fam> create|comment`
  authors Issues / issue-comments as the engineer App. Creating or commenting on an Issue needs the App to
  have **`issues: write`** (on private *and* public repos — unlike the read above). Without it the App can't
  open the Issue; `wf.sh` now fails closed by default instead of falling back to ambient/human auth. Grant
  `issues: write` to both engineer Apps (+ re-accept) when using `wf.sh issue`.
- **Instance wiring (not product):** each App's id + private key live on the instance under e.g.
  `~/.config/<family>-engineer/`. `WF_ENGINEER_TOKEN_CMD_CLAUDE` / `WF_ENGINEER_TOKEN_CMD_CODEX` mint fresh
  installation tokens per use (they expire ~1h); `WF_ENGINEER_GIT_AUTHOR_CLAUDE` /
  `WF_ENGINEER_GIT_AUTHOR_CODEX` provide `Name <email>` for strict commit attribution. `wf.sh` consumes only these
  seams — no App specifics in product code. Protected workflow mutations are strict by default: missing author
  or reviewer engineer identity now blocks without needing `WF_REQUIRE_ENGINEER_IDENTITY=1` or
  `WF_REQUIRE_NATIVE_REVIEW=1` (legacy/no-longer-needed). Use `wf.sh doctor <claude|codex> [repo-or-worktree]`
  to check ambient gh, author/reviewer token repo access, git-author wiring, and author-aware model reviewer readiness
  without printing token values.

## Model reviewer environment

`AUDIT_VERIFIER_CMD` is a model-family override, not a blanket workflow default. For Codex-authored changes it
must point at a Claude-family CLI, and `wf.sh doctor codex` / the review commands reject a Codex-family value
before starting the reviewer. For Claude-authored changes the default Codex verifier is the cross-family path;
`wf.sh` clears `BASH_ENV` for the audit subprocess and drops an inherited Claude-family `AUDIT_VERIFIER_CMD`,
logging a one-line note when it does so. This keeps instance-wide shell convenience from turning a
Claude-authored PR into a same-family Claude review.

## Ambient gh vs workflow identity

It is fine — and expected — for agent shells to have ordinary `gh` access for **reading** Issues/PRs. That
ambient credential is **read-only by construction** (canonical rule + the `WF_READONLY_TOKEN_CMD` seam:
`AGENTS.md` "The ambient agent GitHub credential MUST be read-only") and is not the workflow identity:
it can never write. Owner/admin **writes** are NOT ambient — they go through the explicit elevated-owner-token
+ `WF_GH_ALLOW_OWNER_WRITE=1` maintenance path (see escape hatches below), so elevation is deliberate, never
the silent default. `wf.sh` protected mutations that name an author (`open`, reviews, `comment`, `issue`,
`finish`) use the family engineer App tokens by default and fail closed if those seams are
missing. An instance may source a small read-only `gh.env`/`GH_TOKEN` for ambient CLI convenience; it must
still source the engineer-token env before ship-change workflow writes.

`WF_ALLOW_AMBIENT_IDENTITY=1` is the explicit escape hatch for a deliberate permissive workflow run on an
install without engineer Apps. When used, the driver emits a terminal warning and leaves a best-effort PR/Issue
trail when there is a natural target. Treat that warning like the close-gate override: acceptable for bootstrap
or rescue, not the normal path.

## Abandoned worktrees/branches

`finish` only cleans up its `/tmp/wf-*` worktree + local `change/*` branch on a successful merge. A run that
gets blocked, superseded, withdrawn, or whose implementing session just dies leaves both behind — nothing
else sweeps them. Run `wf.sh gc [repo]` (default `repo`: the cwd's git root) to sweep: it removes a worktree
only when its branch's PR is closed/merged AND local HEAD exactly matches the PR's last known head
(`headRefOid` — proven necessary because a squash-merge's landed commit is never an ancestor of the branch,
so "PR merged" alone doesn't prove local content is represented), or when there's no PR at all and the branch
is fully merged into main. A dirty worktree, an open PR, unmerged/unpushed work with no PR, or any
unresolvable PR lookup is left alone. Idempotent and safe to run any time — including as routine housekeeping
after abandoning or closing a run, not just as a one-off cleanup.

## Escape hatches (when the automation wedges)

Because `enforce_admins` is ON, there is **no standing admin merge-bypass** — that's intentional (the agent
shouldn't be able to bypass its own gate). Instead the owner edits the rule:

- **Disable a rule fast.** Repo → Settings → Branches → the `main` rule → uncheck the offending requirement
  (e.g. require-approvals, or conversation-resolution) → Save. Or via API:
  `gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input <relaxed.json>`. Merges flow again;
  re-tighten once fixed. (Editing protection settings is available to the repo owner/admin even with
  `enforce_admins` ON — that only gates push/merge to the branch, not the settings API.)
- **Remove branch protection entirely (nuclear).** `gh api -X DELETE repos/<owner>/<repo>/branches/main/protection`.
  The repo reverts to driver-side-gate-only behavior. Fully reversible — re-PUT the rule to restore.
- **Revoke an engineer App.** Uninstalling / revoking an engineer App immediately stops it authoring/reviewing —
  the clean unwind for a compromised identity (combined with relaxing require-approvals so merges aren't trapped).

## Reviewer latency / debug policy

Claude-family reviews can be quiet while the model is working. On this fleet, treat 0-5 minutes as normal for
`wf.sh design-review`, `wf.sh code-review`, and the final review inside `wf.sh finish`: do not kill, retry, or
narrate concern during that window. Re-measure these thresholds for other installs; they are this fleet's
as-built operating policy, not a provider SLA.

At 5 minutes, inspect state once without interrupting the reviewer. For the default Claude verifier, check that
the verifier process is still alive; do not treat an empty log as a hang signal. For streaming verifier commands,
also check the run log, remembering that it is a shared driver/verifier log. At 10 minutes, treat the run as
suspicious unless there is concrete evidence of progress.

The underlying `verify-claims` engine writes through an internal temp file and atomically moves it to the final
findings path only after the verifier exits successfully. In `wf.sh`, that means the final review file
(`/tmp/wf_*.md`) can remain missing or empty until the full response completes; that alone is not evidence of a
hang.

## Token / identity rotation

- **`GH_TOKEN`** (ambient READ-ONLY driver auth). The ambient agent credential MUST be read-only (#149): mint a
  new fine-grained PAT with **read-only** repo scopes (contents:read + metadata:read; pull_requests:read /
  issues:read for the reads the workflow inspection needs — **no write scope**), and supply it via the
  instance's `WF_READONLY_TOKEN_CMD` (paired with `WF_READONLY_TOKEN_INFO_CMD` so `wf.sh doctor --readonly` can
  authoritatively confirm it). Replace it wherever your environment provides `GH_TOKEN` *(this instance:
  `~/.env`, re-`source`)*. `wf.sh` sources no env file itself. This ambient-gh env does NOT satisfy the engineer
  identity seams (writes go through `WF_ENGINEER_TOKEN_CMD_*`). NEVER print it; scrub from captured output
  (`sed "s/${GH_TOKEN}/***/g"`).
- **Verify the ambient credential is read-only** after any rotation: `wf.sh doctor <claude|codex> <owner/repo>
  --readonly` probes `GH_TOKEN`, `GITHUB_TOKEN`, and the stored `gh auth` credential independently plus the
  ambient `git push` surface (all non-mutating), and **exits non-zero** if any is not authoritatively read-only
  (a write-capable or unattested token FAILS — fail closed). Plain `wf.sh doctor` prints the same section as a
  labeled reporter alongside the engineer-identity readiness.
- **Engineer Apps** (author/reviewer identities). Rotate the App's private key in the App settings and replace
  the matching `~/.config/<family>-engineer/key.pem`; the minter picks it up. Revoking an App stops that
  identity immediately.

## One-command revert of a merged change

A shipped change is one squash commit on `main`. To undo:

```
git -C <repo> checkout main && git -C <repo> pull --ff-only
git -C <repo> revert <merge-commit-sha>        # creates a revert commit
# then ship the revert through the normal lifecycle (it's just another change).
```

If a plugin manifest changed, after a revert/merge refresh installed plugins:
`claude plugin marketplace update <marketplace> && claude plugin update <name>@<marketplace>`.

## Self-hosting

agentic-engineering ships its own changes through this `ship-change` (self-hosted). From Phase 2 on, its `main`
is branch-protected like any product repo. Self-hosting this pipeline on another repo takes more than
installing the skills, because the GitHub-native SWE pipeline (`implement-on-ready.yml` ->
`review-on-pr.yml` -> `address-review.yml` -> `reconcile-prs.yml`, gated by `checks.yml`) is Actions/App
infrastructure that lives outside any plugin: the target repo needs those workflow assets and prompts
copied in; the identity substitutions the workflows hard-code throughout (the allowlisted researcher
account, the engineer Apps' slugs, and the git author used for commits) replaced with the new owner's own;
the `ready`/`needs-human`/`needs-dispatcher`/`needs-senior-engineer` labels created; two GitHub Apps
installed with the documented permissions; the six Actions secrets provisioned; and branch protection on
`main` set up alongside the repository's "Allow auto-merge" setting.

**`scripts/bootstrap-self-host.sh`** (agentic-engineering#61) automates the parts of this that are pure file
templating or plain API calls:

```
scripts/bootstrap-self-host.sh --target-dir <path-to-fresh-repo-checkout> \
  --researcher-login <your-github-login> \
  --claude-slug <claude-app-slug> --claude-bot-id <numeric-id> --codex-slug <codex-app-slug> \
  [--senior-engineer-slug <senior-engineer-app-slug>] \
  [--repo <owner/name> --create-labels --branch-protection --enable-auto-merge]
```

It copies `implement-on-ready.yml` / `review-on-pr.yml` / `address-review.yml` / `reconcile-prs.yml` /
`checks.yml`, `.github/prompts/{implement,address-review}.md`, `.github/scripts/canonical-login.sh` (+ its
smoke), and `.aar-ci/*` into the target, substituting every hard-coded identity string for the ones
supplied (verified by a built-in leftover check — the run fails loudly rather than silently shipping this
repo's own researcher login or bot slugs into the target) and qualifying every bare/repo-only issue
reference the copied files' provenance comments carry (`#N` / `agentic-engineering#N` /
`automated-researcher#N`) into `antondelafuente/<repo>#N`, per AGENTS.md's "Cross-repo references" rule —
a same-repo bare ref becomes exactly the hazard that rule describes the moment it's copied into a different
repo. It also ensures the target's `AGENTS.md` carries the `<!-- CODEX-REVIEW-GUIDANCE:BEGIN/END -->` block
`review-on-pr.yml` reads its P0/P1 severity convention from (failing loudly instead of silently accepting an
existing block that's missing, duplicates, or reverses either of its two markers). Only a `--target-dir`
that resolves to a checkout's actual root is accepted — a subdirectory is rejected, since every asset path
this script writes is relative to that root. With `--repo` plus the three optional flags, it also
creates the four labels above, applies this repo's own branch-protection ruleset, and turns on "Allow
auto-merge" via `gh api`.

`reconcile-prs.yml` (the reconciler) is always installed alongside the other four workflows: without it, a
PR that goes `CONFLICTING`, or whose review-round auto-dispatch mention silently fails to post, never gets
another pipeline event (`pull_request` never re-fires against an unmergeable PR — see that workflow's own
header comment). Its conflict-nudge and mergeable-re-review legs need only the two Apps this script already
requires (the `CLAUDE_APP` App additionally needs `Actions: write`, so it can `workflow_dispatch`
`review-on-pr.yml`/`senior-engineer.yml`); only its round-limit/stranded-label paths call out to
`senior-engineer.yml`, and degrade to a harmless logged warning (never a crash) when that leg isn't
installed. `--senior-engineer-slug` additionally installs the senior-engineer leg (in-flight PR
adjudication, `senior-engineer.yml` + its prompt): without it, review-on-pr.yml's round-limit and
reconcile-prs.yml's own escalations still apply `needs-senior-engineer`, but nothing consumes it — the same
graceful "label lands, nothing handles it yet" state this repo's own pipeline is in before
`SENIOR_ENGINEER_APP_ID`/`SENIOR_ENGINEER_APP_PRIVATE_KEY` are provisioned (see AGENTS.md's "Senior-engineer
leg"), not a self-hosting-specific defect; a human clears it per AGENTS.md's Dispatcher playbook until the
leg is installed and configured.

What it deliberately does **not** do — no GitHub API can create an App non-interactively: creating the
GitHub Apps (author, reviewer, and optionally the senior-engineer adjudicator; permissions — see "Engineer
identities" above and the script's own printed checklist) and provisioning the six-or-eight Actions secrets
(`CLAUDE_APP_ID`, `CLAUDE_APP_PRIVATE_KEY`, `CODEX_APP_ID`, `CODEX_APP_PRIVATE_KEY`, `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, plus `SENIOR_ENGINEER_APP_ID`/`SENIOR_ENGINEER_APP_PRIVATE_KEY` if that leg is installed)
from their real values. The script prints the exact remaining checklist at the end of its run.

One asset-coupling gap the script's copy step resolves at the source rather than by including more files:
`checks.sh` unconditionally runs `.aar-ci/skill_consistency_check.sh`, which validates every
`plugins/*/skills/*/SKILL.md` against `plugins/aar-engineering/skills/ship-change/scripts/wf.sh` — a
self-hosted install that (deliberately) takes only the pipeline's workflow assets, not the `aar-engineering`
plugin itself, has neither. The checker now no-ops that validation (passes 1 and 4) whenever
`plugins/aar-engineering` itself isn't present, instead of hard-failing on the absent `wf.sh`/denylist — not
whenever there happen to be zero `SKILL.md` files anywhere, which broke the moment a self-hosted target added
its own unrelated skill (`plugins/otherplug/skills/hello/SKILL.md`): every plugin-agnostic pass (`scripts/`
resolution, routing, frontmatter/body agreement) still runs over a target's own `SKILL.md` docs, and a
`wf.sh <verb>` a target doc prescribes still correctly fails pass 1, since that tool genuinely isn't present.
The target's copy of `.aar-ci/checks.sh` additionally guards its fake-HOME smoke's plugin-list computation on
`.claude-plugin/marketplace.json` existing, so a target's own `plugins/` tree doesn't crash that smoke's
fixture asserts before the target has adopted the marketplace product — the third existence guard alongside
the two described below, same self-activation pattern. Verified by
`.aar-ci/skill_consistency_check_smoke.sh`'s no-plugins-tree, target-owned-skills, wf-sh-deleted, and
denylist-deleted scenarios, and by running the templated output's own `.aar-ci/checks.sh` against a throwaway
fresh repo with a target-owned skill added.

`checks.sh` also carries two OTHER path-gated checks that are inline in the script itself (not a separate,
patchable helper like `skill_consistency_check.sh`) and stay coupled to this repo's own `aar-engineering`
plugin/marketplace/disposition-triage product: the packaged-disposition-reference sync check (given
`AGENTS.md` as a changed path, expects a `<!-- DISPOSITIONS:START/END -->` block and a
`plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md`), and the install-namespace check
(given `README.md` as a changed path, expects a `.claude-plugin/marketplace.json`). Neither file exists in a
self-hosted target that hasn't adopted that product, so both checks would otherwise fail any ordinary
target PR touching those paths — including this script's own initial commit, which always writes/appends
`AGENTS.md`.

The script resolves this at the source: after copying `.aar-ci/checks.sh` verbatim, it post-processes only
the target's copy, prepending an existence guard for the product file each check actually depends on (`[ -f
"$ROOT/.claude-plugin/marketplace.json" ] &&` / `[ -f
"$ROOT/plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md" ] &&` in front of the check's
own path-match condition). Both checks self-activate automatically if the target later adopts the
marketplace/dispositions product; until then they're unreachable, since the file they guard on doesn't
exist. The anchors are matched as fixed strings and asserted to occur exactly once each, so a future edit to
`checks.sh`'s own gate lines that moves them fails this script loudly instead of silently shipping an
unguarded copy. This transforms only the bytes written into `--target-dir`; this repo's own
`.aar-ci/checks.sh` (a restricted file) is untouched, and the guard conditions are provably no-ops here —
both guard files exist in this repo on every branch.

What was actually verified (this repo, not a second live GitHub install — creating a second live repo,
Apps, and secrets is outside what an automated implementation run does on its own authority): the script
run against a fresh local git checkout produces valid YAML, every identity string substituted with none of
this repo's own left over, cross-repo references qualified (including bare `#N` refs, not just
`repo#N`/`owner/repo#N` forms), and the templated `.aar-ci/checks.sh` + `.github/scripts/canonical_login_smoke.sh`
+ the skill-consistency smoke all pass clean against the result when run over those templated files' own
paths. Running the templated `.aar-ci/checks.sh` given `AGENTS.md` as the changed path, and again given
`README.md`, both now pass clean — confirming the existence guards above actually make the target's copy
diverge from upstream only where upstream could never pass anyway. Also verified: bootstrapping a throwaway
target, adding a target-owned `plugins/myplugin/skills/hello/SKILL.md`, and confirming
`.aar-ci/skill_consistency_check.sh`, `.aar-ci/checks.sh` against that new file, and `.aar-ci/checks.sh`
against `AGENTS.md`/`README.md` all now pass (they previously failed permanently once such a file existed,
since check 1f runs the skill checker unconditionally on every invocation).
The remaining acceptance bar — flip `ready` on a real fresh repo and get a merged PR — needs the
Apps/secrets/branch-protection above in place first; treat this repository's own configuration as the
reference implementation for what "working" looks like end-to-end.
