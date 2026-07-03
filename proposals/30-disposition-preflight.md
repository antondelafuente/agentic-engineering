# Proposal: disposition pre-flight at ship-change START + no-self-flip contract (#30)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The `ready`-only close-gate in `wf.sh finish` works, but it only fires at the END of the pipeline. Observed
failure mode: an agent told "do issue #N" implements a `needs-shaping` issue end-to-end (worktree, design doc,
reviews) and only then blocks at `finish` — or, following the guidance to "triage it to `ready` first",
**flips the label itself** and proceeds, skipping exactly the researcher conversation the disposition exists
to force. Mirrors `antondelafuente/automated-researcher#315` (researcher-shaped 2026-07-03), scoped to the two
touches that live in this repo.

## Approach

Two one-line touches, both defense-in-depth around the existing close-gate:

1. **`ship-change` SKILL.md, Issue step — a pre-flight check.** Before creating the worktree (step 1, `wf.sh
   start`), read the target issue's disposition. If it is not `ready` — including unlabeled/untriaged — STOP:
   do not implement. Route by disposition: `needs-shaping` → go shape it with the researcher (a real
   conversation, not a self-service relabel); `blocked` → surface the blocker; `parked` → leave it.
   Implementation starts only from `ready`. This catches the failure mode at the cheapest possible point —
   before any worktree/design-doc/review work is spent — rather than at `finish`, where the close-gate already
   catches it but only after the work is sunk.

2. **`AGENTS.md` dispositions section (canonical; synced to
   `plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md`, drift-checked by
   `.aar-ci/checks.sh`) — a contract line.** `needs-shaping → ready` is the **researcher's** transition, in
   every lane: an agent records the flip only on the back of an actual researcher conversation, and the flip
   must **cite it** — a comment on the issue summarizing/linking the shaping discussion. An agent asked to
   *implement* an issue never flips its disposition label as a step of implementing it. This states the norm
   for every lane and makes the flip auditable, mirroring the intended pattern already exercised on
   `antondelafuente/automated-researcher#311` / `antondelafuente/automated-researcher#313`. It does **not**, by
   itself, add a new mechanical gate to any lane other than the ship-change pre-flight above — `cloud-ship`'s
   close-time `ready` check (its existing mechanical backstop) is unchanged by this PR; a matching early
   pre-flight there is out of scope here (see Alternatives).

Both blocks are kept byte-identical between `AGENTS.md` and the packaged `DISPOSITIONS.md` reference, per the
existing sync contract enforced by `.aar-ci/checks.sh`'s disposition-reference-drift check.

## Alternatives considered

- **Only the pre-flight, no contract line.** Rejected: the pre-flight stops an agent from implementing a
  non-`ready` issue, but doesn't stop it from self-flipping the label as a workaround and then proceeding — the
  contract line is what makes that specific evasion explicitly disallowed and auditable.
- **Only the contract line, no pre-flight.** Rejected: without the pre-flight check, the failure is still only
  caught at `finish`, after the worktree/design-doc/review work is already sunk — the whole point of
  `antondelafuente/automated-researcher#315` is to move the check earlier.
- **Enforce the pre-flight mechanically in `wf.sh start`** (reject the `start` call itself if the issue isn't
  `ready`). Deferred: `wf.sh start` doesn't currently look up issue labels, and adding that lookup + a failure
  mode (missing label vs. wrong disposition vs. lookup/permission failure — the existing `finish`-gate override
  precedent, `WF_ALLOW_NONREADY_CLOSE=1`, suggests any mechanical gate needs its own escape hatch too) is a
  larger, separable change from the two one-line documentation touches
  `antondelafuente/automated-researcher#315` scoped, and from what this PR's mirror issue (#30, ready as filed)
  asked for. The close-gate at `finish` already provides the mechanical
  backstop today — a PR closing a non-`ready` issue fails closed regardless of what an agent did in between —
  so this proposal's pre-flight is a genuine cost-saving instructional check (catch it before work is spent),
  not the only thing standing between an agent and a bad merge. A follow-up could harden `start` itself
  mechanically (and extend the same treatment to `cloud-ship`'s dispatch entry point) if agents keep skipping
  the documented pre-flight in practice.

## Blast radius

SWE pipeline only (this repo, `aar-engineering` plugin): the `ship-change` SKILL.md instructions and the
`AGENTS.md`/`DISPOSITIONS.md` disposition contract. No code paths, no `wf.sh` behavior change, no schema
change. Read by every agent that runs `ship-change` from now on; no migration needed for in-flight PRs.

## Rollout + rollback

Pure documentation/instruction change — merges like any other `ship-change` PR (cross-family `--scaffold` +
`--code` review, checks green, `.aar-ci` drift-check passes). Rollback is a plain revert if the wording proves
wrong in practice; no runtime state to unwind.
