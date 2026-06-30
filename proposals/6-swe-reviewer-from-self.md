# Source ship-change's SWE reviewer from agentic-engineering, not the repo under review

## Problem

When ship-change runs a `--scaffold` (design) or `--code` (implementation) review, it resolves *which*
verify-claims reviewer to run from the **repo being reviewed**: `run_review` and `fresh_sweep` both call
`locate_audit "$wt"`, and `locate_audit` searches the context repo's base ref **first**, falling back to
`SELF_REPO` (agentic-engineering) only when the context repo carries no verify-claims in-tree.

That binding blocks the rest of the agentic-engineering extraction (automated-researcher #255, Phase 3b).
The plan is to trim the SWE-review modes (`--scaffold`/`--code`) out of automated-researcher's verify-claims,
because the SWE review engine now belongs to agentic-engineering. But once trimmed, automated-researcher
still *carries a verify-claims directory* (with the experiment modes) — so `locate_audit` would resolve that
trimmed copy from automated-researcher's base ref and then fail when asked to run `--scaffold`/`--code`, which
it no longer supports. The reviewer source must move to agentic-engineering before that trim is safe.

## Approach

The SWE review engine lives in agentic-engineering, so ship-change should always source its `--scaffold`/
`--code` reviewer from agentic-engineering (`SELF_REPO`), independent of which repo is under review. The two
call sites are SWE-review-only — `run_review` is only ever invoked `--scaffold`/`--code` (design-review,
code-review, finish merge-gate) and `fresh_sweep` only `--code` (the finish backstop) — so the change is
localized: `locate_audit "$wt"` → `locate_audit "$SELF_REPO"` in both.

Two properties are preserved deliberately:

- **The constitution stays the target repo's.** `run_review`/`fresh_sweep` pass `AUDIT_CONSTITUTION`
  (default `$wt/AGENTS.md`) separately from the reviewer source. That is untouched, so the review still judges
  the repo-under-review against *its own* AGENTS.md — only the review *engine* comes from agentic-engineering.
- **Self-review safety is unchanged.** `locate_audit` resolves through `audit_from_base_ref`, which
  materializes verify-claims from the repo's **base ref** (origin/main), never the branch under review. Passing
  `SELF_REPO` keeps that: when ship-change reviews agentic-engineering itself, the reviewer is agentic-engineering's
  base-ref verify-claims, so a branch that edits the reviewer still can't run its own modified reviewer as the gate.

### Resulting behaviour

- Reviewing **automated-researcher** (cross-repo): reviewer resolves to **agentic-engineering's** verify-claims
  (base ref); the constitution is still automated-researcher's AGENTS.md.
- Reviewing **agentic-engineering** itself (self-host): reviewer = agentic-engineering's base-ref verify-claims
  (unchanged from today); the branch's edits to verify-claims are not used as the gate.

## Alternatives considered

- **Make `locate_audit` mode-aware** (skip the context-repo search only for SWE modes). More machinery than
  needed: the two callers are *already* SWE-only, so passing `SELF_REPO` at the call site is both simpler and
  more honest about intent. `locate_audit` stays a general resolver for the `locate-audit` introspection command.
- **Leave automated-researcher's verify-claims full** (don't trim, skip this change). Rejected: it leaves the
  SWE review engine duplicated inside the research product, which is exactly the boundary Phase 3 removes.

## Blast radius

- Only the two SWE-review call sites change; `locate_audit`, `audit_from_base_ref`, and the experiment-audit
  modes (`--design`/`--data`/close/`verify_claim`) are untouched.
- This PR is **reviewer-resolution only** and is self-consistent on its own (automated-researcher's verify-claims
  still has the modes, so nothing breaks if PR2 is delayed). It is the prerequisite that makes the PR2 trim safe.

## Rollout + rollback

Land this first. Then PR2 trims `--scaffold`/`--code` out of automated-researcher's verify-claims + SKILL.md.
Reversible: revert this PR to restore context-repo-first reviewer resolution.
