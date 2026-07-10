# Proposal: Re-tier the design leg — dispatcher authors + scaffold-reviews the design pre-dispatch; the implementor gets a locked design (#40)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Ship-change's dispatcher contract splits WHO does the work by tier — a premium dispatcher session shapes and supervises, a dispatched execution-tier implementor runs the lifecycle — but it draws the leg boundary in the wrong place. Today the implementor authors the design doc (lifecycle steps 1–3) and then defends it under the cross-family `--scaffold` review. That parks design-defense judgment on the least-judgment-capable tier, whose characteristic failure mode is agreeable capitulation: silently implementing a plausible-but-wrong reviewer redesign rather than refuting it. Nothing in the lifecycle catches that failure — the review gate reads a capitulation as convergence.

The two incidents that bracket the gap, both on automated-researcher (see automated-researcher#361 and its 2026-07-10 resolution comment):

- **#347**: a premium dispatcher session ran the whole lifecycle itself — the mechanical legs (implement, review churn, merge ceremony) on the expensive tier, which the contract already forbids; the gates protect quality regardless of author.
- **#364** (the dispatch that followed): an execution-tier implementor was handed a design-heavy ticket, and the dispatcher had to bolt on an ad-hoc mid-flight amendment ("findings contradicting the shaped design: refute with citation or escalate — never silently comply") because the lifecycle gave the implementor design-defense duties it isn't equipped for.

The sibling lifecycle got this right: experiment-lifecycle has the smart tier design WITH the researcher, cross-family-audits the design itself, and only then hands a locked brief to an executor with zero design freedom. Ship-change should have the same shape.

## Approach

**Move the design leg (steps 1–3) up to the dispatcher tier, uniformly for all tickets.** The researcher explicitly rejected a per-ticket "is this design-heavy?" triage bit — uniformity is the point. The split binds by TIER, not universally: it applies when a premium dispatcher-tier session is driving (this deployment's researcher-facing Fable sessions). A session already on an execution-appropriate tier — e.g. this box's Codex AARs, per the researcher's explicit call (2026-07-10) — may keep running the lifecycle end-to-end as both designer and implementor; solo end-to-end use of the skill remains valid, as today. Trivial tickets simply have trivial design docs, so the premium-tier cost of the design leg is negligible; the bulk of every ticket (implement + review churn) stays on the execution tier.

The re-tiered leg split:

- **Dispatcher legs (judgment):** shape the issue with the researcher → `wf.sh start` → author the design doc → `wf.sh open` (draft PR) → `wf.sh design-review` → triage/defend the `--scaffold` findings as a peer. Design is judgment work, so authoring it at the dispatcher tier does not violate the contract — implementing does. After design-review triage converges, the design is **locked**.
- **Handoff:** the dispatcher dispatches an execution-tier implementor whose brief is the locked design doc + the existing worktree/branch/PR. No `wf.sh` code change is needed: steps 4–6 (`implement`, `code-review <WORKTREE>`, `finish <WORKTREE>`) already take the worktree as an argument, so the implementor attaches to the dispatcher-created worktree rather than running `start`/`open`/`design-review` itself.
- **Implementor legs (execution):** implement in the worktree → `wf.sh code-review` + triage (findings concern its own code — the tier-appropriate fight) → `wf.sh finish` → print its DONE line and stop for reaping.

Three concrete deliverables:

1. **SKILL.md — "Who runs this skill" rewrite.** The dispatcher-contract section carries the leg split above (duties 1–3 — model tier, watch, lifecycle — are unchanged and stay). The lifecycle code block gets a marked handoff boundary between steps 3 and 4.
2. **SKILL.md — the step-0 PRE-FLIGHT becomes the forcing function** automated-researcher#361 asked for, with the sharper boundary this re-tier enables: "Dispatcher-tier session? Your legs END at design-review triage. STOP before step 4 — dispatch an execution-tier implementor with the locked design (see `references/DISPATCH-SPEC.md`). Implementor session? You start at step 4; if there is no reviewed design doc on the branch, STOP and return to your dispatcher — you never author or re-open the design."
3. **`references/DISPATCH-SPEC.md` — the dispatch-spec template**, so dispatching is one paste, cheaper than doing the work inline (the forcing function's economic half). Parameterized by repo, issue, worktree, branch, and locked design doc path. It bakes in, as standing policy rather than ad-hoc amendment: (a) scope = steps 4–6 only; (b) the escalation seam — a code-review or merge-gate finding that contradicts the locked design is refuted citing the design doc, or escalated to the dispatcher if genuinely substantive, never silently implemented; findings on the implementor's own choices (naming, layout, code quality) are handled normally; (c) the termination protocol — print `IMPLEMENTOR DONE: PR <n> merged at <sha>` and stop, so the dispatcher's watch (duty 2) has a deterministic reap signal.

**What enforces this, honestly tiered.** The WHO-does-which-leg boundary cannot be verified by `wf.sh` — a script can't see which model tier is driving it. Enforcement is therefore layered, strongest first:

- **The implementor side is structurally enforced by the brief.** A dispatched implementor's entire instruction set IS the template: it's briefed to start at step 4 against an existing worktree, and the template's first gate is "no reviewed design doc on the branch → STOP, return to dispatcher." It is never handed an instruction that mentions authoring a design, so drifting into the design leg requires disobeying its brief, not merely skipping prose.
- **The dispatcher side is the pre-flight line + the dispatcher's own standing rules** (skill prose, instance memory, the researcher's catch — the #347 layers, now with the boundary stated sharply enough to trip on). This is the weakest layer and the one #347 proved fallible; the template is what changes the economics, making dispatch a one-paste action that is cheaper than implementing inline — removing the incentive that made #347 happen.
- **Optional mechanical hardening (deployment-owned, out of scope here):** the instance launch seam that already pins the implementor's model can also export a role marker (e.g. `WF_ROLE=implementor`) into the dispatched session's environment, and `wf.sh start`/`open`/`design-review` could refuse under it — making "implementor re-opens the design leg" mechanically impossible one-directionally. Deliberately not built now: the brief already covers it, and the reverse direction (dispatcher implementing) is unenforceable by env var anyway since the dispatcher's environment is the default one. Noted so the option is on the record if the procedural layers leak.

Evidence seam: automated-researcher#364 is running as the last old-flow dispatch at the time of writing; its `--scaffold`/`--code` review rounds are live evidence for the exact SKILL.md wording (does an execution-tier author get clobbered on shaped decisions?) and will be cited in the section's rationale line the way #26 is cited in cloud-ship's.

## Alternatives considered

- **Dispatcher does everything (repeal the split).** Rejected: repeals the contract's economics for no quality gain — the cross-family review + fail-closed gates protect quality regardless of author tier (the documented cloud-ship #26 rationale), and #347 is the incident showing the cost. The dispatcher's session also stops being researcher-available while it grinds mechanics.
- **Per-ticket triage ("design-heavy → split; mechanical → old flow").** Rejected by the researcher explicitly: it reintroduces a per-ticket judgment call, and the marginal saving (skipping a trivial design doc) is negligible.
- **Escalation-seam-only (keep implementor-authored design; route design-touching findings to the dispatcher).** Rejected as the default: it relocates a classification judgment ("is this finding design or detail?") onto the execution tier, and misclassification fails silently as capitulation — the exact failure being fixed. It survives inside the dispatch-spec template as defense-in-depth for the residual case (a post-lock finding that touches the design), where the locked, already-reviewed design doc makes the citation mechanical rather than judgmental.

## Blast radius

- **This skill only:** SKILL.md prose (dispatcher-contract section + step-0 pre-flight + lifecycle block annotations) and a new `references/DISPATCH-SPEC.md`. Plugin version bump per repo convention.
- **No `wf.sh` code changes.** Steps 4–6 already operate on an explicit worktree; the handoff is purely procedural.
- **cloud-ship unaffected:** its author leg deliberately runs whole on a cloud VM with fresh context and stops at a pushed branch; re-tiering within a single box's dispatcher/implementor pair doesn't apply there. A pointer line noting the distinction is in scope; changing cloud-ship is not.
- **Instance side (not this repo):** how a dispatcher launches/pins/watches implementor sessions stays deployment-owned (the contract already says so). The template references the seams generically.

## Rollout + rollback

Docs + template only; one-commit revert restores the old flow exactly. Self-referentially staged: this very ticket runs the new flow — this design doc is dispatcher-authored and will be scaffold-reviewed pre-dispatch, and the implement leg (#40's steps 4–6) will be the first dispatch briefed by the new template's content. If the handoff mechanics fail in practice, the failure is visible in the first dispatch and the fallback (implementor runs the old full lifecycle) remains available until this merges.
