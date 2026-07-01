# Proposal: Fix wf.sh `open` design-doc path derivation for untracked proposals/ (#13)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh open <worktree> <author>` needs the path of the design doc it should commit and open the draft PR from. It derives that path with:

```sh
DOC=$(cd "$WT" && git status --porcelain proposals/ | sed 's/^...//' | head -1)
[ -n "$DOC" ] || DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
```

When `proposals/` is **entirely untracked** (a fresh repo, or before any proposal is committed), `git status --porcelain proposals/` does not list individual files — it collapses to the directory entry `?? proposals/`. So `DOC` becomes the bare string `proposals/`, not `proposals/<issue>-<slug>.md`. Everything downstream is then corrupt: `ISSUE=$(basename "$DOC" | sed -E 's/^([0-9]+)-.*/\1/')` yields `proposals`, the commit message becomes `design: proposals (#proposals)`, the PR title/body are garbage, and `git add -- proposals/` stages the whole directory instead of the one doc.

This was worked around in agentic-engineering by committing `proposals/` (README + prior docs) so the directory is tracked and `git status` lists the new file individually — but the driver should not depend on that incidental state. This is the port of automated-researcher#257 bug (1) into the self-hosted copy here. (Bug (2) of that upstream issue — the hardcoded marketplace name in the post-merge hint — was already fixed in this repo in commit 2b6008f; only bug (1) remains, hence this issue is scoped to `open`.)

## Approach

Derive the doc path **deterministically from the branch**, which `open` already reads, instead of inferring it from working-tree status. `wf.sh start <issue> <slug>` creates branch `change/<issue>-<slug>` and scaffolds `proposals/<issue>-<slug>.md`; the two are locked together by construction. So in `open`:

```sh
BR=$(wt_branch "$WT")
# Primary: the scaffolded path implied by the branch name (change/<issue>-<slug> -> proposals/<issue>-<slug>.md).
# This is what `start` created and is correct even when proposals/ is entirely untracked (git status would
# collapse to the bare 'proposals/' directory entry).
DOC=""
case "$BR" in
  change/*) [ -f "$WT/proposals/${BR#change/}.md" ] && DOC="proposals/${BR#change/}.md" ;;
esac
# Fallback (non-standard branch, or hand-authored doc): discover via git, but restrict to real .md files so the
# bare 'proposals/' directory entry can never be selected.
[ -n "$DOC" ] || DOC=$(cd "$WT" && git status --porcelain proposals/ | sed 's/^...//' | grep -E '\.md$' | head -1)
[ -n "$DOC" ] || DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | grep -E '\.md$' | head -1)
[ -n "$DOC" ] || die "no design doc under proposals/ found (write proposals/<issue>-<slug>.md first)"
```

Two changes, defense in depth:
1. **Branch-derived primary**, gated on the file actually existing so a mistyped/absent doc still errors rather than committing a phantom path.
2. **`.md` filter on both fallbacks**, so even on a non-`change/` branch the bare directory entry `proposals/` is never mistaken for a doc.

The rest of `open` (issue extraction from the basename, the doc-only `git add -- "$DOC"` commit, PR creation) is unchanged and now always receives a real file path.

## Alternatives considered

- **Filter the `git status` output to `.md` only, keep it as primary.** Fixes the garbage-directory symptom but does not solve the fresh-repo case: when `proposals/` is untracked, `git status --porcelain` emits only the collapsed directory line, so the `.md` filter yields empty and `open` dies with "no design doc found" even though the scaffolded doc is right there. The branch-derived path is what actually makes the untracked case work.
- **Require `proposals/` to be tracked (keep the workaround).** Leaves a latent footgun for the next repo that adopts ship-change; the whole point of the self-hosted port is to not depend on incidental tracking state.

## Blast radius

SWE pipeline only — one subcommand (`open`) in `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`. No change to `start`, `finish`, review gates, or any product/research scaffold. Behavior is identical for the normal path (tracked `proposals/`, standard `change/<issue>-<slug>` branch), and strictly more robust for untracked/fresh repos and non-standard branches. No manifest change (no install refresh needed).

## Rollout + rollback

Low risk; single-file, single-function change. Revert = restore the two-line derivation. Verified by reproducing the untracked-`proposals/` case (bare `proposals/` selected before, correct `proposals/<issue>-<slug>.md` after) plus a `bash -n` syntax check.
