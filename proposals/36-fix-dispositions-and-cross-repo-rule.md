# Proposal: fix dangling "`#49`'s to define" + absorb the cross-repo-reference rule (#36)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Two independent rough edges in this repo's constitution:

1. The `ready` bullet in the DISPOSITIONS block ends with "...the precise boundary of which `ready`
   Issues it acts on autonomously (especially by blast radius) is `#49`'s to define." That `#49` is a
   bare, un-qualified reference: in *this* repo it resolves to whatever antondelafuente/agentic-engineering#49
   happens to be, not the issue the sentence actually means
   (antondelafuente/automated-researcher#49, which is CLOSED as not-aligned-with-current-direction).
   The sentence is not just wrong, it's a live instance of the exact footgun item 2 below documents:
   a bare `#N` auto-links against whichever repo renders it.

2. The instance constitution (`~/AGENTS.md`) carries a general engineering-etiquette rule — cross-repo
   references must be fully qualified — that isn't instance-specific at all. Per the router in
   `~/AGENTS.md` ("home keeps vision + router + wiring, everything else moves to its product"), this
   rule belongs in the product it actually governs: this repo, since ship-change is where PRs/Issues/commits
   referencing other repos' Issues get written.

The DISPOSITIONS block is dual-maintained by design (`AGENTS.md` is canonical per the product constitution;
`plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md` is the packaged copy shipped with the
plugin so the skill doesn't have to reach outside its own tree to read it) and `.aar-ci/checks.sh` drift-checks
that the two `<!-- DISPOSITIONS:START --> ... <!-- DISPOSITIONS:END -->` blocks stay byte-identical. Any edit
to the block must land in both files identically or CI fails.

## Approach

**1. Fix the dangling reference.** Replace the `#49` sentence with a self-contained statement that doesn't
depend on any external issue resolving correctly, since the boundary genuinely hasn't been decided yet:

> `ready` is the only disposition **eligible** for auto-handling — but eligibility is not blind auto-merge:
> the auto-handler still runs the full cross-family review + checks. No Issue is auto-implemented without an
> explicit dispatch (a human or a dispatcher session naming it); the precise boundary of which `ready` Issues
> get acted on with less oversight (especially by blast radius) is undecided and will be revisited if/when a
> standing auto-handler is actually proposed.

This keeps the substance (auto-handling eligibility isn't blind auto-merge) while dropping the forward
reference entirely rather than pointing at a new placeholder Issue — the prior attempt at "cite the open
question" is exactly what produced a dangling ref once the referent closed. A plain prose statement of the
current state (undecided, revisit when proposed) can't go stale the same way.

Apply the identical edit to both copies of the block:
- `AGENTS.md` (canonical)
- `plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md` (packaged, synced copy)

## Alternatives considered

- **Point `#49` at a fresh, correctly-scoped Issue in this repo instead of dropping the sentence.** Rejected:
  it re-introduces the same fragility (a sentence's correctness depends on an external Issue's future state)
  for no real benefit — nothing is currently proposing a standing auto-handler, so there's no live Issue to
  point at honestly. Filing a placeholder Issue just to have something to reference would be manufacturing a
  forward ref rather than fixing the underlying problem.
- **Drop the sentence entirely instead of rephrasing.** Considered; rejected in favor of rephrasing because
  the sentence carries real content (the auto-handler boundary is genuinely undecided, which matters context
  for the auto-handling eligibility distinction the bullet establishes) — dropping it silently would lose that
  signal rather than just fixing the dangling ref.
- **Put the cross-repo-reference rule under "The pipeline (ship-change)" instead of its own section.** Rejected:
  it's a general engineering-etiquette norm that applies to every interaction with this repo (commits, PRs,
  docs, chat), not specifically to the ship-change pipeline mechanics — a standalone section reads clearer and
  matches how `~/AGENTS.md` scoped it (a standalone bullet under "operating rules", not folded into another
  topic).

**2. Absorb the cross-repo-reference rule.** Add a new section to `AGENTS.md` (this repo only — the
DISPOSITIONS drift-check does not cover this section, so it needs no packaged-copy sync):

> ## Cross-repo references
>
> Cross-repo issue/PR references are fully qualified (`owner/repo#N` or a full URL) **everywhere** they're
> written — commits, PRs, docs, and chat — never a bare `#N`. A bare `#N` auto-links against whatever repo
> happens to be rendering it, not the repo the writer meant, and silently resolves to the wrong Issue or
> 404s. This repo's own DISPOSITIONS block once carried exactly this failure — a `#49` meant for a different
> repo, fixed above.

(Dropped "the journal" from the original instance wording — that's a research/instance-specific surface this
general engineering-team repo shouldn't name; "docs" already covers it generically.)

This is placed as its own top-level section (after "The merge gate", before the DISPOSITIONS block) since it's
a general norm, not pipeline mechanics.

## Blast radius

Docs-only change to `AGENTS.md` and the packaged copy `plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md`.
No code changes, no behavior change to the ship-change pipeline itself — the auto-handler eligibility rule
(`ready` is eligible, not auto-merged) is unchanged in substance, only its wording. The DISPOSITIONS
drift-check (`.aar-ci/checks.sh`) requires the two blocks to stay byte-identical, which this change satisfies
by construction (same text landed in both files). Because this PR edits a non-manifest file inside the
`aar-engineering` plugin, `plugins/aar-engineering/.claude-plugin/plugin.json`'s version is bumped
(0.4.6 -> 0.4.7) per `.aar-ci/checks.sh`'s version-bump check.

Does not touch `~/AGENTS.md` (the instance constitution) — that's a different repo (`hetzner-home`) with its
own shared, currently-dirty working tree owned by other running sessions; editing it isn't safe or in scope
from this worktree. `~/AGENTS.md:106` still carries the now-duplicated cross-repo-reference bullet after this
PR merges; pruning it (or replacing it with a pointer to this repo's new canonical section) is a follow-up,
instance-owned edit for whoever next holds the single-writer hat on that file.

## Rollout + rollback

Docs-only; no staged rollout needed. Rollback is a plain revert of the PR if the wording needs revisiting.
