# Proposal: name the /loop skill as the dispatcher's watch mechanism (#35)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The dispatcher contract in `ship-change` SKILL.md (step 2, "Watch") says the dispatcher watches the
implementor "on a short cadence (~5 min)" but never names a mechanism. In practice, dispatchers have
filled that gap two ways, and both miss the point:

- **Ad-hoc background sleep-loops** — a `sleep 300; check; sleep 300; …` shell loop backgrounded by the
  dispatcher session. The harness can kill these silently on session events (compaction, restart), and
  because they're bash rather than dispatcher-agent turns, their pane snapshots go unread even when the
  loop is alive — nothing re-invokes the dispatcher's own judgment on what it sees.
- **Exit-only monitors** — waiting on the implementor session to terminate (a `wait`, a completion
  webhook, a harness "task finished" notification). This tells the dispatcher when the session ends, which
  is necessary for the *lifecycle* duty (step 3), but says nothing about whether the session is currently
  wedged-idle mid-run — which is the entire point of the ~5-min cadence.

The watch's purpose is **stall inspection**: catching a silent mid-turn wedge (e.g. a provider API error
leaving the session idle-alive) fast, because code tickets finish in under an hour. That requires a
recurring, judged LOOK at the implementor's pane — not a timer and not an exit signal.

## Approach

Name the **`/loop` skill** (Claude Code's recurring-prompt skill) specifically as the watch mechanism for
Claude-family dispatchers: `/loop 5m` armed with a prompt that has the dispatcher inspect the implementor's
pane and act on what it sees (nudge if wedged-idle; reap once the PR has merged). The mechanism matters
because each `/loop` firing **re-invokes the dispatcher agent itself** — every cycle gets a real judgment
call on the pane contents, not just a liveness bit. It's also visible/cancellable harness machinery (shows
up in `/loop` state, stoppable like any other skill invocation) rather than an opaque background process
the harness can kill without anyone noticing.

Concretely, step 2 of the dispatcher contract will:
- Name `/loop 5m` as the watch mechanism, with a pane-inspection prompt as the loop body (look at the
  implementor's pane; nudge if wedged-idle; reap once merged).
- State plainly that ad-hoc background sleep-loops and exit-only monitors do not satisfy the contract —
  they fail the "judged look every cycle" requirement even if they happen to run continuously.
- Keep the existing caveat that the watch is session-local (the loop dies with the dispatcher's own
  session) and must be re-armed after any dispatcher restart/handoff — `/loop` doesn't change that
  property, it just names what should be re-armed.
- Note that non-Claude dispatchers use their harness's equivalent periodic-reinvocation mechanism — the
  contract is "a mechanism that re-invokes the dispatcher's judgment on a short cadence," and `/loop` is
  the Claude-substrate instance of that, not the only valid one.

## Alternatives considered

- **Leave the contract mechanism-agnostic.** Rejected: this is exactly the ambiguity that let both failure
  modes (silently-killed sleep-loops, exit-only monitors) pass as compliant. Naming the mechanism for the
  Claude substrate closes the gap while the non-Claude carve-out preserves portability.
- **Mandate a specific external cron/webhook watchdog.** Rejected: adds infrastructure and a new
  dependency for a duty that Claude Code already has native, visible machinery for (`/loop`); also loses
  the "re-invokes the dispatcher's own judgment" property since an external watchdog is a different agent,
  not the dispatcher itself.

## Blast radius

Docs-only: `plugins/aar-engineering/skills/ship-change/SKILL.md`, dispatcher-contract section (step 2).
No code, no `wf.sh` changes, no CI impact. Affects how future dispatcher sessions on this box (and any
other Claude-substrate deployment of this plugin) are instructed to implement the watch duty.

## Rollout + rollback

Doc change only; takes effect for the next dispatcher session that reads the contract. No staged rollout
needed. Rollback is a plain revert of the SKILL.md hunk if the wording proves unclear in practice.
