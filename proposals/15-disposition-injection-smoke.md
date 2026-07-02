# Proposal: Add disposition-injection dry-run smoke (#15)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh` still owns the SWE-review
disposition-aware merge-gate framing from #137/#139: when `wf.sh finish` supplies a readable
`DISPOSITION_FILE`, the reviewer prompt is prepended with the `STATEFUL DISPOSITION-AWARE MERGE-GATE REVIEW`
block plus the prior findings and author dispositions. That path is load-bearing for broad PRs that use
finding dispositions, but it is currently covered only by real ship-change reviews with prior findings.

The earlier `disposition_inject_smoke.sh` covered an older altitude-injection mechanism and was removed when
that mechanism was deleted. The retained prompt injection needs its own slim deterministic smoke so future
edits to `audit_experiment.sh` or CI cannot silently drop the disposition-aware framing or accidentally inject
it into first-pass reviews.

## Approach

Add one shell smoke under the `verify-claims` plugin:

`plugins/verify-claims/skills/verify-claims/scripts/disposition_injection_smoke.sh`

The smoke uses the existing `AUDIT_DRY_RUN=1` testability seam in `audit_experiment.sh`, so it assembles the
exact prompt and exits before invoking a model. It creates temporary proposal, diff, and disposition files,
sets `AAR_SUBSTRATE=claude` so the default Codex auditor remains cross-family, and exercises both SWE-review
modes:

- `audit_experiment.sh --scaffold <proposal> <repo-root>`
- `audit_experiment.sh --code <nonempty-diff> <repo-root>`

For each mode, it runs once with `DISPOSITION_FILE=<json>` and asserts that the prompt contains the stateful
review header, a prior finding description, and a disposition status marker. It then runs with
`DISPOSITION_FILE` unset and asserts that the same disposition markers are absent. Those assertions cover the
mode-neutral injection branch without depending on the mode-specific prompt body.

Wire the smoke into `.aar-ci/checks.sh` when either the reviewer script or the smoke changes:

- `plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh`
- `plugins/verify-claims/skills/verify-claims/scripts/disposition_injection_smoke.sh`

If the reviewer changes and the smoke script is missing, CI fails closed. Because this adds a non-manifest file
inside the `verify-claims` plugin, bump `plugins/verify-claims/.claude-plugin/plugin.json` from `0.7.8` to
`0.7.9`.

## Alternatives considered

- **Rely on real disposition-aware `ship-change` reviews.** Rejected: they are valuable integration coverage
  but not deterministic, not cheap to run as a focused regression check, and only happen after a PR has prior
  findings.
- **Only test `--code`, since `finish` is the merge gate.** Rejected: the injection branch is intentionally
  mode-neutral after base prompt assembly. Exercising both `--scaffold` and `--code` catches accidental
  coupling to one prompt shape for little extra complexity.
- **Snapshot the full prompt.** Rejected: too brittle. The load-bearing behavior is the presence or absence of
  the disposition framing and payload markers, not the exact text of the entire SWE-review prompt.

## Blast radius

SWE pipeline test coverage only. The reviewer runtime behavior is unchanged except for adding a smoke script
and CI trigger. The touched product files are:

- `.aar-ci/checks.sh`
- `plugins/verify-claims/.claude-plugin/plugin.json`
- `plugins/verify-claims/skills/verify-claims/scripts/disposition_injection_smoke.sh`

No experiment-audit modes are reintroduced into agentic-engineering's `verify-claims`; it remains
SWE-review-only.

## Rollout + rollback

Rollout is the normal `ship-change` path: design review, implementation, code review, `.aar-ci/checks.sh`,
behavior smoke, final review, merge. The local validation command for this change is:

```sh
bash plugins/verify-claims/skills/verify-claims/scripts/disposition_injection_smoke.sh
bash .aar-ci/checks.sh proposals/15-disposition-injection-smoke.md .aar-ci/checks.sh plugins/verify-claims/.claude-plugin/plugin.json plugins/verify-claims/skills/verify-claims/scripts/disposition_injection_smoke.sh
```

Rollback is a clean revert of the smoke, CI trigger, and version bump. Since this is coverage-only, reverting
restores the previous behavior exactly.
