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
  cross-family review + checks. **Resolved (agentic-engineering#43):** on a repo with the GitHub-native SWE pipeline wired (an
  `implement-on-ready.yml`-equivalent workflow present), an ALLOWLISTED actor's `ready` label flip **is**
  itself the explicit dispatch — the workflow's own authorization predicate (allowlisted labeler AND a
  freshly-reverified, allowlisted issue author, before any token is minted) is what makes this safe, not a
  separate per-run naming step; per-issue concurrency dedup (no global worker pool) is the spend guard, not
  a human queueing each run — see this product's "GitHub-native SWE pipeline (BYOK)" AGENTS.md section. On a repo without that pipeline
  wired, the label alone is not enough: no Issue is auto-implemented without a separate explicit dispatch (a
  human or a dispatcher session naming it).
- **`needs-shaping`** — a direction, too vague to start; needs scoping into `ready` first, through a
  conversation with the researcher (which may produce a few `ready` tickets).
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**Triager (event-driven per-ticket assessment; ported from antondelafuente/automated-researcher#437/antondelafuente/automated-researcher#497 via
agentic-engineering#63):** `triage-assess.yml` assesses every newly opened/reopened Issue **from an
allowlisted sender** (the researcher or one of the two engineer bots) within minutes — two independent
blind model assessments (Fable, Sol — the same cross-family split `review-on-pr.yml` uses) against
`.github/triage/RUBRIC.md`, then a sighted adjudication pass that sees both and proposes a verdict
(`DO`/`SKIP`/`ASK`), an optional body-edit, and (for `DO`) a provisional wave guess based on this ticket's
own expected footprint — posted as a single idempotent on-ticket assessment comment, never a label or body
write. Assessment is strictly per-ticket (one issue per run, never a batch), so this wave guess cannot be
compared against any other open DO ticket; actual wave/serialization composition across tickets is a
researcher judgment made at flip time, not an automated output. This repo is public, so an Issue filed or
reopened by anyone else does NOT get this event-driven pass (it would otherwise let an outside filer trigger
paid model calls for free). A weekly backstop sweep (`schedule`) catches genuinely event-missed stragglers —
but its own straggler predicate ALSO requires an allowlisted ticket author (agentic-engineering#65 round 5,
P0): a non-allowlisted-author filing therefore gets machine-assessed by **neither** path, since the sweep is
the only remaining route such a ticket's body/comments could reach the assess/adjudicate jobs, which hold
`ANTHROPIC_API_KEY` and unrestricted `Read`. This is a deliberate, TEMPORARY parity deviation — the
capability-reduction pattern for safely assessing outsider tickets is designed and in flight upstream
(antondelafuente/automated-researcher#523); once it lands, it ports here and this exclusion lifts. Until
then, a non-allowlisted-author ticket simply waits for the researcher's manual eye, acceptable for a repo
with ~zero outsider filings. For an allowlisted-author straggler, the sweep dispatches the same per-ticket
assessment for every open, unlabeled-and-unescalated issue with no assessment comment yet, then rebuilds a
rollup digest comment on the tracking issue (#64) listing every ticket already assessed and still awaiting a
researcher decision. `needs-design`
is retired, same as automated-researcher's own convention — there is no separate "awaiting shaping" label
this triager introduces or resurrects; an Issue with no disposition is either fresh (about to get its
event-driven assessment) or already carries the triager's assessment comment, in which case the citation
below is exactly that comment.

**`unlabeled → ready` (or `needs-shaping → ready`) is the researcher's transition, in every lane.** An agent
records the flip only on the back of an actual researcher conversation, and the flip must **cite it** — a
comment on the issue summarizing/linking the shaping discussion (the triager's assessment comment, when one
already exists, is exactly this citation). An agent asked to *implement* an issue never flips its
disposition label as a step of implementing it — that would let it triage its own way in. This is a norm
every lane follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a
gate only at close) is that lane's own concern to build out.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
