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

**`needs-shaping → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion. An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
