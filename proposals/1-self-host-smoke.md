# 1 — Self-host smoke: ship-change runs inside agentic-engineering

## Problem
agentic-engineering is a freshly-extracted minimal starter (Phase 1, #253). We must prove it is **self-sufficient**: that `ship-change` drives a change end-to-end INSIDE this repo, gated by this repo's OWN review engine (`verify-claims` `--scaffold`/`--code`), not depending back on automated-researcher.

## Approach
Drive a trivial change (a one-line RUNBOOK note + the plugin version bump) through the full lifecycle: start -> open -> `--scaffold` (this doc) -> `--code` (the diff) -> `.aar-ci` checks + behavior smoke -> finish (merge; main is unprotected this phase). A clean merge proves the starter self-hosts.

## Alternatives considered
None — an acceptance smoke, not a design choice.

## Blast radius
A one-line doc note + a version bump in `aar-engineering`. Reversible; nothing functional changes.

## Rollout + rollback
Merge on the gate. Rollback: revert. Phase 2 (#254) adds branch protection on this proven starter.
