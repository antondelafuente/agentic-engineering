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

State the contract itself as a capability requirement, not a model-family label: the dispatcher needs **a
mechanism that re-invokes its own judgment on a short cadence** — a background timer or exit-only monitor
doesn't satisfy this even running continuously, because neither puts a judged look at the pane on every
cycle. Then name the concrete instantiation on the harness this box actually runs: on Claude Code, that
mechanism is the **`/loop` skill** — `/loop 5m` armed with a pane-inspection prompt that has the dispatcher
inspect the implementor's pane and act on what it sees (nudge if wedged-idle; reap once the PR has merged).
The mechanism matters because each `/loop` firing **re-invokes the dispatcher agent itself** — every cycle
gets a real judgment call on the pane contents, not just a liveness bit. It's also visible/cancellable
harness machinery (shows up in `/loop` state, stoppable like any other skill invocation) rather than an
opaque background process the harness can kill without anyone noticing.

Concretely, step 2 of the dispatcher contract will:
- Frame the requirement as periodic re-invocation of the dispatcher's own judgment (the varying unit is
  harness capability, not model family), then name `/loop 5m` with a pane-inspection prompt as the concrete
  instantiation for Claude Code dispatchers (look at the implementor's pane; nudge if wedged-idle; reap once
  merged).
- State plainly that ad-hoc background sleep-loops and exit-only monitors do not satisfy the contract —
  they fail the "judged look every cycle" requirement even if they happen to run continuously.
- Keep the existing caveat that the watch is session-local (the loop dies with the dispatcher's own
  session) and must be re-armed after any dispatcher restart/handoff — `/loop` doesn't change that
  property, it just names what should be re-armed.
- Note that dispatchers on a different harness use that harness's equivalent periodic-reinvocation
  mechanism — `/loop` is the Claude Code instantiation of the contract, not the only valid one.

## Alternatives considered

- **Leave the contract mechanism-agnostic.** Rejected: this is exactly the ambiguity that let both failure
  modes (silently-killed sleep-loops, exit-only monitors) pass as compliant. Naming the mechanism for the
  Claude substrate closes the gap while the non-Claude carve-out preserves portability.
- **Mandate a specific external cron/webhook watchdog.** Rejected: adds infrastructure and a new
  dependency for a duty that Claude Code already has native, visible machinery for (`/loop`); also loses
  the "re-invokes the dispatcher's own judgment" property since an external watchdog is a different agent,
  not the dispatcher itself.

## Blast radius

`plugins/aar-engineering/skills/ship-change/SKILL.md` (dispatcher-contract section, step 2) plus the
matching `plugins/aar-engineering/.claude-plugin/plugin.json` patch version bump the repo's `.aar-ci/
checks.sh` requires for any non-manifest change under a plugin dir. No `wf.sh` logic change; the fake-HOME
behavior smoke still applies as the standard plugin/skill-change gate. Affects how future dispatcher
sessions on this box (and any other Claude Code deployment of this plugin) are instructed to implement the
watch duty. The instance guidance at `/home/anton/AGENTS.md` already carries a forward reference to this
issue (`antondelafuente/agentic-engineering#35`) naming `/loop` as the Claude-substrate watch mechanism — that's a separate
repo, out of scope for this PR, and needs no further edit once this lands.

## Rollout + rollback

Doc + manifest-version change only; takes effect for the next dispatcher session that reads the contract.
No staged rollout needed. Rollback is a plain revert of the SKILL.md + plugin.json hunks if the wording
proves unclear in practice.
