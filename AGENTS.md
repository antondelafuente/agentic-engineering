# agentic-engineering — the engineering team

This repo is the **engineering team**: agents that build and ship software through a GitHub-backed,
cross-family-reviewed lifecycle. It is **general** — it could build a video game as well as research tooling;
*how* it builds is the point, *what* it builds is incidental. It is independent of the products it builds
(per the box-level vision in `~/AGENTS.md`): a product never depends back on this team's tooling at runtime.

## The pipeline (ship-change)

The agents ARE the engineers. Every change is **authored by one model family and reviewed by the OTHER**
(Claude-authored -> Codex reviews; vice-versa) — a foreign family is the safeguard. The human is the
staff-engineer / PM: sets **direction** (the Issue + the `needs-shaping -> ready` shaping) and gates *which*
work happens, **not each PR's merge**. Architectural and mechanical changes alike merge on the cross-family
review + checks; there is no per-change classification or human design approval.

`ship-change` (plugin `aar-engineering`) drives it: Issue -> worktree branch -> design doc -> draft PR ->
cross-family `--scaffold` design review -> implement -> cross-family `--code` review -> tracked `.aar-ci`
checks + behavior smoke -> fail-closed merge-when-clean. The cross-family review engine is **verify-claims**
(`--scaffold`/`--code`), self-contained in this repo (it does not depend back on any product).

## Two layers

- **Build the product** — this team (ship-change) builds/reviews/ships changes to *products*.
- **Use the product** — that is the product's own concern, not this team's. This team ships software; it
  doesn't run research.

## The merge gate (fail-closed)

A change merges only on: cross-family `--code` review with **zero HIGH** (re-run on the final diff), the
tracked `.aar-ci/checks.sh` + behavior smoke green, and (on enforced repos) the required opposite-family
native approval. A crashed/garbled review never reads as clean.

<!-- DISPOSITIONS:START -->
## Issue tracker — dispositions

Every open Issue carries a **disposition** — how it should be handled — orthogonal to its type
(`bug`/`enhancement`/…) and to open/closed. This is the definition (the product-owned, versioned part). The
assign-at-filing and maintain *procedures* live in the appropriate operating surface: reusable product feedback
machinery belongs in product skills, while deployment-only file bookkeeping belongs in consuming-instance
guidance. AGENTS.md holds the issue contract, not local workflow paths.

- **`ready`** — actionable now; any design is settled and lives in the implementing PR itself (design-in-PR).
  Implement + merge on the cross-family review + checks. `ready` is the only disposition **eligible**
  for auto-handling — but eligibility is not blind auto-merge: the auto-handler still runs the full
  cross-family review + checks, and the precise boundary of which `ready` Issues it acts on autonomously
  (especially by blast radius) is #49's to define.
- **`needs-shaping`** — a direction, too vague to start; needs scoping into `ready` first, through a
  conversation with the researcher (which may produce a few `ready` tickets).
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**`needs-shaping → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion. An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
