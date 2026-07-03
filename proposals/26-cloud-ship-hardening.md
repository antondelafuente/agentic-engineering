# Proposal: cloud-ship dispatch hardening — pin the model, dupe-guard the launch, document observability (#26, #22, #25)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Three independent findings from 2026-07-02 route-testing all land on `cloud-ship`'s dispatch/observability
surface, and are small enough to bundle as one change:

- **#26 — unpinned model.** `dispatch-cloud-ship.sh` execs `claude --remote "$(cat "$BRIEF")"` with no model
  flag, so the session lands on the account/server default (currently Opus 4.8) rather than the deployment's
  policy of running gated execution legs on Sonnet-tier (quality is protected by the cross-family review +
  fail-closed close gate, not by which model authors). Verified 2026-07-02 by transcript ground truth: passing
  `--model claude-sonnet-5` to `claude --remote` does pin the VM session model.
- **#22 — no dupe guard.** A route-test agent ran BOTH an on-box `wf.sh` draft PR and a full cloud-ship run for
  the same issue. The on-box PR merged first; the completed cloud run sat orphaned with a live `CLOUD-SHIP RUN`
  PASS record that `close-cloud-ship.sh` would have happily merged as a duplicate had anyone run `close` on it.
  Nothing at dispatch time checks whether the target issue already has an open PR or an in-flight branch.
- **#25 — silent-stall / attach hazard.** Two independent agents were burned attaching to a *running* cloud
  session to check progress: a `claude --teleport` into a healthy run wedged it, and a `codex` AAR attaching to
  a stalled run hit a misleading branch-checkout error (the branch was never pushed) and misread it as a crash.
  `SKILL.md` says nothing about expected latency, that attach/teleport/resume are TAKEOVER operations (not
  viewers), or what to do on a suspected stall.

All three touch only `plugins/aar-engineering/skills/cloud-ship/` (`scripts/dispatch-cloud-ship.sh` +
`SKILL.md`) — one small PR closing all three is less overhead than three PRs touching the same two files.

## Approach

**1. (#26) Pin the model, overridable.** Add `-m/--model <model-id>` to `dispatch-cloud-ship.sh`, default
`claude-sonnet-5`, appended to the launch as `claude --remote --model "$MODEL" "$(cat "$BRIEF")"` (flag before
the positional brief string; `--dry-run` prints the flag in its rendered command so the model choice is visible
before launch). Document the flag + default + rationale in `SKILL.md`'s dispatch section: execution legs run
Sonnet-tier by deployment policy; the cross-family review + fail-closed close gate protect quality, not the
author model.

**2. (#22) Dupe guard before every launch, `--force` to override.** Add a pure, offline-testable
`dupe_gate <issue> <pr-hits> <branch-hits>` function (same shape as `close-cloud-ship.sh`'s `gate_record`: takes
already-fetched inputs, decides, prints a canonical `DUPE-GATE: OK`/`DUPE-GATE: REFUSE <reason>` line, returns
0/2) so the decision logic has no network dependency and can be smoke-tested with fixture strings. The live
call site fetches the two inputs and feeds the gate:
- open PRs referencing the issue: `gh pr list -R <repo> --state open --json number,url,title,body` filtered to
  entries whose title/body contains `#<issue>` as a whole token (catches both `Closes #<issue>` and a plain
  mention);
- in-flight branches on origin matching the issue: `git ls-remote --heads` filtered to
  `^(change|cloud-ship)/<issue>-`.

Both reads use the ambient **read-only** `gh`/git credential (inspection only, per the standing rule) — no
write capability is needed for a refuse-before-launch check. On any hit, `dispatch-cloud-ship.sh` refuses with
one clear line (mirroring `close-cloud-ship.sh`'s `die`/`refuse` style: a single reason, nonzero exit) naming
what it found and that `--force` overrides. `--force` skips the guard entirely (same escape-hatch shape as
`WF_ALLOW_NONREADY_CLOSE` elsewhere in this plugin — logged, not silent).

The existing `close_cloud_ship_smoke.sh` only exercises `close-cloud-ship.sh`'s `gate`/`dispo-gate` — it has no
dispatch coverage to extend. Add a new sibling `dispatch_cloud_ship_smoke.sh` (same fixture-driven, offline
style as `close_cloud_ship_smoke.sh`) covering `dupe_gate`'s OK path, the open-PR-hit refuse path, the
in-flight-branch-hit refuse path, and the both-hit path; wire it into `.aar-ci/checks.sh`'s existing cloud-ship
block (§9) which already runs on any `dispatch-cloud-ship.sh`/`close-cloud-ship.sh` change.

**3. (#25) Observability section in `SKILL.md`.** One tight paragraph each, added after the existing "Composes"
section:
- **Expected latency** — first GitHub signal (a pushed branch) can take 30-45+ minutes on a substantial change;
  don't start diagnosing before that window has elapsed.
- **Never attach to a running session** — attach/teleport/resume are TAKEOVER operations, not viewers; there is
  no non-invasive live read. A running session's branch-checkout error is misleading when the branch was simply
  never pushed yet. The pushed branch + the `CLOUD-SHIP RUN` record comment are the ONLY progress signals; poll
  those, not the session.
- **Suspected stall** — silence well past the latency window: **redispatch** (idempotent — a stalled session
  pushed nothing, so nothing is lost) or fall back to on-box `ship-change`. Teleport is safe only on a
  **finished/abandoned** session, for post-mortem readback (it materializes the transcript as a local jsonl).
- One sentence naming both 2026-07-02 incidents that motivated this section (a `claude --teleport` into a
  healthy running session wedging it; a `codex` AAR attaching to a stalled session and misreading the resulting
  branch-checkout error as a crash).

**Version + record.** Bump `aar-engineering`'s `plugin.json` version (patch bump: three small, backward
-compatible additions to one skill, no interface break). This proposal doc is the ADR/changelog record — the
repo keeps no separate `CHANGELOG` file.

## Alternatives considered

- **Three separate PRs, one per issue.** Rejected for this round: all three touch the same two files
  (`dispatch-cloud-ship.sh`, `SKILL.md`) with no interaction between the changes, so three PRs would mean three
  review rounds + three version bumps over the same small surface for no isolation benefit. Bundled as one
  change explicitly per the issue-author's framing (all three filed together as a hardening round).
- **Make the dupe guard also check the issue's own linked-PR timeline via `gh issue view --json
  timelineItems`.** More precise (it would catch a PR that never mentions `#<issue>` in title/body but is
  linked via a `Closes` keyword resolved by GitHub's own tracking) but heavier and less portable across `gh`
  versions than a text-match `pr list` filter + branch-prefix match. The dupe guard's job is a cheap, no-network-
  surprise pre-check before an expensive unrecoverable cloud run — a text-match false-negative is an acceptable
  trade against a slower, timeline-API-dependent check; both cases in #22's own incident (an on-box PR, and a
  branch-named-by-issue) are covered by the simpler check.
- **Silently warn instead of refusing on a dupe hit.** Rejected — the #22 incident's root cause was that
  nothing stopped the redundant launch; a warning an agent can scroll past reproduces the same failure mode.
  Refuse-by-default with an explicit `--force` matches this plugin's existing escape-hatch convention
  (`WF_ALLOW_NONREADY_CLOSE=1`, `--dry-run`) — visible, deliberate override, not a silent nudge.
- **Fold the #25 observability guidance into `dispatch-cloud-ship.sh`'s stdout instead of `SKILL.md`.** Do
  both would be nice but is scope creep for this round: the failure mode both incidents share is an agent
  reading *neither* the running stdout *nor* the skill before deciding to attach (attaching happens well after
  dispatch returns control). `SKILL.md` is the durable, always-read surface; a stdout note is easy to add later
  but not required to close #25 as filed (one paragraph in `SKILL.md`, per the issue body).

## Blast radius

Touches only `plugins/aar-engineering/skills/cloud-ship/scripts/dispatch-cloud-ship.sh` (new flags, new guard),
a new `plugins/aar-engineering/skills/cloud-ship/scripts/dispatch_cloud_ship_smoke.sh`, `SKILL.md` (docs), the
`.aar-ci/checks.sh` cloud-ship smoke block (one more smoke invocation, same trigger paths), and
`aar-engineering`'s `plugin.json` version. No change to `close-cloud-ship.sh`, the record contract, the
engineer-identity seams, or any other skill/plugin. Backward compatible: `-m/--model` and `--force` are new
optional flags with a safe default (pin to Sonnet; guard is on unless overridden); an existing invocation with
neither flag now also gets the model pin and the dupe guard, which is the intended hardening, not a breaking
change. The fake-HOME discovery smoke is unaffected (no new skill, no manifest surface change).

## Rollout + rollback

Low risk, additive. `.aar-ci/checks.sh` runs: JSON/version checks, the fake-HOME behavior smoke (cloud-ship's
plugin still discoverable), and the existing + new cloud-ship smokes (`close_cloud_ship_smoke.sh` unchanged +
new `dispatch_cloud_ship_smoke.sh`) since `dispatch-cloud-ship.sh` changed. Rollback = revert the flag/guard
additions and the `SKILL.md` paragraphs; nothing persists external state (the dupe guard reads only, the model
flag is a launch-time argument). A dispatcher relying on the old unpinned-model, no-guard behavior would need
`--force` going forward if it target an issue with an existing PR/branch — an intended behavior change, not a
regression.
