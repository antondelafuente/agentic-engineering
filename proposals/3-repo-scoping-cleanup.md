# 3 — repo-scoping cleanup: fix automated-researcher leaks in copied content

## Problem

Phase 1 copied ship-change + verify-claims from automated-researcher into this repo; the copies carry automated-researcher-specific references that are wrong here: `wf.sh`'s post-merge refresh hint hardcodes `automated-researcher`; the `.aar-ci` labels say automated-researcher; the RUNBOOK says the engineer Apps are "installed on automated-researcher".

## Approach

- **wf.sh post-merge hint** — read the marketplace name dynamically from `$MAIN_CO/.claude-plugin/marketplace.json`, so the install hint is correct in any repo using ship-change (also filed upstream as automated-researcher#257).
- **.aar-ci/checks.sh + config** — label this repo (agentic-engineering).
- **RUNBOOK** — the engineer Apps are installed on all of Anton's repos incl. this one; the doc hint uses the dynamic `<marketplace>` placeholder.

This change also **verifies Phase 2**: it ships through the now-protected agentic-engineering `main`, merging only via the opposite-family bot's native approval clearing branch protection.

## Alternatives considered

- Leave the leaks (rejected: wrong references in a self-contained repo; the hint would misdirect users to automated-researcher).

## Blast radius

Cosmetic labels + one functional fix (the dynamic hint). No change to the lifecycle behavior. Reversible. SKILL.md cross-references fixed to local pointers. Narrowing the `.aar-ci` check profile (it still carries dead research-plugin checks gated on non-existent plugin paths) is a tracked follow-up.

## Rollout + rollback

Revert the PR.
