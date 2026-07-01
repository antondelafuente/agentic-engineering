# 8 — Trim agentic-engineering's verify-claims to SWE-review-only

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

agentic-engineering's `verify-claims` still carries the FULL experiment-audit ladder (`verify_claim.sh`,
`audit_experiment.sh --design/--data/close`, `audit_data.py`) — it was a whole-cloth copy made during the
extraction. But agentic-engineering is the ENGINEERING repo: nothing here runs experiments, and
`ship-change` (the only consumer of this verify-claims) uses ONLY `audit_experiment.sh --scaffold` /
`--code`. The experiment-audit modes are dead weight here, and they duplicate the copy that legitimately
lives in the research product (`automated-researcher`).

Phase 3b PR2 (automated-researcher #280) already trimmed the OTHER direction — it removed `--scaffold`/`--code`
from automated-researcher's verify-claims, since ship-change now sources its SWE reviewer from
agentic-engineering (PR1 / #7, `locate_swe_audit`). This is the mirror: make agentic-engineering's
verify-claims SWE-review-ONLY, so the two copies are cleanly disjoint (one canonical home per mode set).

## Approach

Trim `plugins/verify-claims/skills/verify-claims/` to the SWE-review engine:
- `audit_experiment.sh`: keep `--scaffold` + `--code` (mode parse, input handling, cross-family
  enforcement, context-AGENTS.md constitution, both PROMPT blocks, the disposition-aware merge-gate
  framing, the atomic-write run). Remove the `--design`/`--data`/close modes and their PROMPTs. A stray
  `--design`/`--data`/no-flag now fails closed with a "this is the SWE-review engine" message (422 → 216 lines).
- Remove the experiment-only sibling scripts `verify_claim.sh` (brief-FACTS checker) and `audit_data.py`
  (experiment data-audit) — confirmed nothing in agentic-engineering references them except a
  self-created fixture in `locate_audit_smoke.sh` (which builds its own, not the real file).
- `SKILL.md`, `plugin.json` description: rewrite to the SWE-review engine only. (`marketplace.json` was
  already SWE-scoped; `AGENTS.md` has no experiment-mode refs.) Version bump 0.7.7 → 0.7.8.

## Alternatives considered

- **Keep the experiment modes here (do nothing):** rejected — leaves two live copies of the experiment
  ladder (a DRY / one-canonical-home violation), the asymmetry PR2 half-fixed, and dead weight in the
  engineering repo.
- **Delete verify-claims from agentic-engineering entirely, point ship-change at automated-researcher's:**
  rejected — that re-introduces the exact cross-repo coupling Phase 3b PR1 removed (ship-change must own
  its reviewer so trimming the product can't break engineering reviews).

## Blast radius

- **ship-change SWE reviews: unaffected.** `--scaffold`/`--code` are kept; `locate_audit_smoke.sh` still
  passes (confirms `locate-audit --swe` resolves a `--scaffold`-capable reviewer from agentic-engineering).
- **automated-researcher: unaffected.** It has its own verify-claims (experiment modes) after #280.
- Validated pre-open via `AUDIT_DRY_RUN`: `--scaffold`/`--code` assemble (with constitution + proposal
  ref); empty-diff + cross-family guards intact; `--design`/close fail closed.

## Rollout + rollback

Mirror of #280; PR1 (#7) already landed, so ship-change already sources its reviewer from
agentic-engineering — this trim is safe now. The fleet loads verify-claims via `--plugin-dir` live source;
sessions pick up the trimmed engine on their next restart. Reversible: a clean revert restores the removed
modes and scripts.
