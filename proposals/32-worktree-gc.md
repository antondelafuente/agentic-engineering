# Proposal: `wf.sh gc` — sweep abandoned worktrees/branches (#32)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh finish` removes its `/tmp/wf-*` worktree + local `change/*` branch on merge (best-effort, after the
squash-merge). But a run that never reaches `finish` — blocked at a gate, superseded, withdrawn, or the
implementor session died — leaves its worktree and branch behind forever. Nothing sweeps them. Evidence
(2026-07-03, consuming instance): 11 stale worktrees found in `~/automated-researcher`, every one from a
CLOSED (unmerged) PR or a branch with no PR at all; a 12th (`wf-317`) was abandoned the same day mid-run.
Pruned by hand. Shaping is researcher-directed (Anton, 2026-07-03 fleet conversation — "those should
automatically get cleaned up"); mechanism is implementation detail, hence `ready` with design-in-PR.

## Approach

Add a `wf.sh gc [repo]` subcommand. `repo` defaults to `ORIGIN_REPO` (the cwd's git root), matching the
convention `doctor`/`start` already use for the main checkout.

For each directory matching `${WF_WORKTREE_ROOT:-/tmp}/wf-*`:

1. **Scope to this repo.** Resolve the candidate's main checkout via the existing `main_checkout` helper
   (same one `finish` uses) and skip (silently — not an error, just not ours) anything whose main checkout
   isn't this repo's. `/tmp` is shared across repos (e.g. `automated-researcher` and `agentic-engineering`
   both create `wf-*` dirs there) — `gc` must never touch another repo's worktree.
2. **Never touch a dirty worktree.** If `git status --porcelain` is non-empty, leave it — uncommitted work
   is never gc'd regardless of PR state. This is stricter than the issue's minimum bar but matches
   `require_clean`'s existing philosophy (`finish` already refuses to merge dirty content) and the
   "must NEVER remove … work" directive.
3. **Look up the branch's PR** via `gh pr view <branch> --json number,state` (ambient read-only auth is
   sufficient — `gh pr view` resolves OPEN/CLOSED/MERGED alike, confirmed against this repo's own merged/closed
   PRs during design). Three outcomes:
   - **PR found, `MERGED` or `CLOSED`** → eligible for removal.
   - **PR found, `OPEN`** → never touch.
   - **No PR found** (gh's `no pull requests found for branch "…"` message specifically) → eligible only if
     the branch is fully merged into main (`git merge-base --is-ancestor <branch> <base>`, base = origin/main
     falling back to local main, mirroring `base_ref`). Otherwise it's unpushed/unmerged work with no PR
     protecting it — never touch.
   - **Any other lookup failure** (auth/network/API error — anything whose message isn't the specific
     "no pull requests found" string) → fail closed, leave it. A transient API hiccup must never read as
     "no PR" and trigger a removal.
4. **Remove.** `git worktree remove --force`, then delete the local branch — mirroring `finish`'s existing
   cleanup block exactly (same `change/*` guard, same "still checked out elsewhere" guard, same best-effort
   `branch -D`).
5. **Report** a one-line summary (swept / kept / skipped counts) at the end; per-worktree `note()` lines
   explain every decision (so a dry inspection is just reading stderr).

No new flags for a dry-run: `gc`'s own logic already refuses to guess (fail-closed on ambiguity), and every
disposition is logged via `note()`, so running it is itself low-risk and inspectable. Safe to run any time,
repeatedly (idempotent — nothing left to sweep on a second run is a silent no-op).

**Docs**: point `finish`'s "cleans the worktree" guidance and the escape-hatches area at `gc` as the sweep for
runs that *don't* reach `finish` — one line each in `SKILL.md` and `RUNBOOK.md`.

## Alternatives considered

- **Time-based TTL sweep** (rm anything older than N days) — rejected: cheap but blind to PR state, so it
  could delete a worktree behind a long-lived-but-legitimately-open PR, or (converse) leave a same-day
  abandoned run (`wf-317`) sitting for the full TTL. The issue's evidence includes exactly that same-day case.
- **`gc` as part of every `start`** (auto-sweep on each new run) — rejected: `start` is meant to be fast and
  side-effect-free besides creating the new worktree; folding in a full PR-status sweep would slow every
  `start` and couple two unrelated operations. A standalone subcommand composes better with the docs' pointer
  ("run `gc` when you abandon/close a run") and with an optional future cron/periodic call.
- **Only sweep worktrees with a resolvable PR, treat "no PR" as always unsafe** — rejected: the issue
  explicitly asks to cover "no PR and the branch is fully contained in main" (a `start` that got as far as a
  worktree + branch but never `open`ed a PR, and whose content is a no-op or was independently merged some
  other way) — the `wf-317` evidence is the mirror case (no PR, NOT contained → correctly left alone).

## Blast radius

SWE pipeline only (`plugins/aar-engineering/skills/ship-change/scripts/wf.sh` + `SKILL.md`/`RUNBOOK.md`
docs). No change to `start`/`open`/`finish`/review/merge behavior. `gc` only ever removes a `/tmp/wf-*`
worktree + its local `change/*` branch — it never touches GitHub state (no PR/issue writes), so it needs no
engineer identity, only ambient read-only `gh`.

## Rollout + rollback

Additive subcommand; nothing else in the lifecycle depends on it or changes behavior. Revert is a plain
revert of this PR's commit. Escape hatch if `gc` is ever wrong about a specific worktree: don't run it there
— it's opt-in, invoked by hand (or by doc pointer), never part of the enforced merge/close gates.
