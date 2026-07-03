# Proposal: document the dispatcher contract in ship-change SKILL.md (#28)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`ship-change` SKILL.md never says WHO runs it. In practice this skill is usually executed end-to-end by a
dispatched one-shot implementor session, launched and supervised by a longer-lived dispatcher session — but
that seam is invisible to a zero-context reader of the skill. Issue #28 (scope broadened by Anton's
2026-07-03 comment) asks for the skill to state the full **dispatcher contract**: the three duties a
dispatcher owns when it runs ship-change via a dispatched implementor — model tier, watch cadence, and
lifecycle/reap — in deployment-neutral terms. `cloud-ship` SKILL.md already documents the model-tier half of
this rationale (the `-m`/`--model` bullet added after #26: gated execution legs run an execution-tier model
because cross-family review + fail-closed gates protect quality, not the author model); `ship-change` should
carry the analogous, but fuller, statement for the on-box dispatched-implementor path, and `cloud-ship` should
cross-reference it rather than duplicate it.

## Approach

Add a new `## Who runs this skill — the dispatcher contract` section to `ship-change/SKILL.md`, placed after
the intro paragraphs (deployment-conditional cloud-execution note, "the agents are the engineers", "ENFORCED
where configured") and before `## The non-negotiable properties` — the section is itself about *who* invokes
the lifecycle the rest of the doc describes, so it belongs at the top, adjacent to the other "how this skill
is invoked" framing.

Content: one paragraph stating the pattern (dispatched one-shot implementor runs the skill end-to-end; a
longer-lived dispatcher launches it and owns three duties), then three tight bullets — MODEL TIER, WATCH,
LIFECYCLE — matching the wording given in the Issue/comment, followed by a closing line that the *how*
(session runtime, model pinning, reaping) is deployment-owned and this skill states only the contract. This
mirrors the doc's existing pattern of stating contracts deployment-neutrally (see the "Cloud execution, when
configured" and "Ambient workflow fallback is explicit" passages) rather than naming box-local machinery
(tmux, `dispatch-engineer.sh`, session names).

In `cloud-ship/SKILL.md`, add a one-line cross-reference near the existing model-pin bullet (the `-m`/
`--model` bullet under "1. Dispatch (on the box)") pointing to ship-change's new section for the fuller
three-duty contract — cloud-ship's own dispatch is a fire-and-record pattern (the cloud session runs headless
to a stop record, not supervised turn-by-turn), so it already covers model tier and has its own lifecycle
(the box-side close gate), but the cross-reference makes the shared model-tier rationale traceable to one
place instead of two independent statements drifting apart.

Bump the plugin version (patch, `aar-engineering`'s `plugin.json`) per repo convention — required by
`.aar-ci/checks.sh` §5 whenever a non-manifest plugin file changes. The repo keeps no separate `CHANGELOG`
file; this proposal doc is the ADR/change record.

## Alternatives considered

- **Put the contract in `AGENTS.md` instead of SKILL.md.** Rejected: the Issue is explicit that the skill
  itself should be self-describing for a zero-context reader ("that makes the skill self-describing... without
  hard-coding any instance detail") — a reader picking up `ship-change` cold needs the contract without
  having to also load the constitution.
- **Name the box-local machinery (tmux, `dispatch-engineer.sh`, `--reap`) in SKILL.md.** Rejected per the
  Issue and the spec: deployment-neutral only. The product scaffold doesn't assume any particular dispatcher
  implementation; a different deployment could supervise implementors with a different mechanism entirely and
  the contract should still hold.
- **Duplicate the full three-duty bullet list in cloud-ship SKILL.md instead of cross-referencing.** Rejected:
  cloud-ship's dispatch is a materially different pattern (no live watch cadence — the cloud session runs
  unattended to a stop record) and only the model-tier duty applies directly; a one-line pointer avoids two
  copies of the same rationale drifting out of sync.

## Blast radius

Docs-only: two `SKILL.md` files (`ship-change`, `cloud-ship`) plus the plugin `plugin.json` version bump.
No script, workflow, or CI-check behavior changes. Read by any agent (Claude or Codex) that loads either
skill fresh; no runtime code path depends on this text.

## Rollout + rollback

Low risk, single PR through the normal `ship-change` lifecycle. Rollback is a plain revert of the PR if the
wording needs rework — no state, no migration.
