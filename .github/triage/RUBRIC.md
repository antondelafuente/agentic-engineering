# Triage rubric

Read from this repo's base ref by `triage-assess.yml`. Ported from automated-researcher's own triage rubric
(researcher-locked there on 2026-07-12, antondelafuente/automated-researcher#437's original "Triager, v1" design synthesized
on antondelafuente/automated-researcher#414, evolved by antondelafuente/automated-researcher#497) via agentic-engineering#63, adapted to this repo's own
scope (the engineering team's tooling, not a research product). Applied identically by both blind assessors
(Fable, Sol) and by the sighted adjudication pass. Treat this file the same way as an `unlabeled -> ready`
disposition flip (AGENTS.md): edit only on the back of an actual researcher conversation, not casually.

## The three questions

1. **What does the failure cost, at this team's operating scale?** This repo builds and ships software
   through the cross-family-reviewed `ship-change` pipeline (AGENTS.md) — a handful of agents authoring and
   reviewing concurrently, a single researcher/PM setting direction. A correctness bug that breaks the
   merge gate's fail-closed guarantee, or a trust-boundary violation in the pipeline itself, outranks a
   dollar cost, which outranks researcher-attention-minutes. Rarity alone never kills a fix; cost does.
2. **Does it serve this team's tooling generally, not just one in-flight change?** An instance-specific
   workaround, or a fix scoped to one PR with no generalizable pipeline/tooling change, does not clear this
   bar on its own.
3. **What does the fix cost — latency, dollars, complexity?** Weigh against (1) and (2): a cheap fix for a
   real, generally-applicable failure is DO even when rare; an expensive fix for a narrow, one-off cost is
   SKIP or ASK.

## Verdicts

- **DO** — clears all three questions; safe to shape into a `ready` ticket.
- **SKIP** — fails the cost/benefit weighing (rare + expensive, superseded by other work, or doesn't serve
  the general product).
- **ASK** — a genuine product-shape or policy decision that only the human can make; not a shaping gap the
  ticket itself can resolve by rewriting scope.

## Known split pattern (from automated-researcher's 2026-07-11 dry run, 69% raw blind-agreement across 52
tickets — carried over as instructive prior art, not this repo's own measured data)

One rubric clause resolved roughly a third of the observed disagreements: **a diagnosed fix with a proven
workaround is mechanical even when spend-adjacent; escalate only if the fix itself sets policy.** Apply this
before defaulting a cost-adjacent ticket to ASK — the split was systematic (one model over-escalating
spend-adjacent tickets as policy), not noise.

## Wave batching (file-disjoint rule, from antondelafuente/automated-researcher#431's root cause)

For DO verdicts, the sighted adjudication additionally proposes a wave grouping: diff the candidate tickets'
expected file footprints (the ticket usually names the skill/script/workflow it touches) and serialize any
tickets that would land on the same file; file-disjoint tickets may batch into the same wave. A conflicted PR
produces *no* workflow run at all (GitHub can't build the merge ref while a PR conflicts with base), so
flipping same-file siblings concurrently doesn't just cost a conflict-resolution round — it silences the
pipeline for every sibling still open when one merges (this is exactly what `reconcile-prs.yml` exists to
repair after the fact; this rule prevents triggering it needlessly). This is the primary prevention rule,
not a nice-to-have.
