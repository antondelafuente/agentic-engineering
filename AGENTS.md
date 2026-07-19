# agentic-engineering — the engineering team

This repo is the **engineering team**: agents that build and ship software through a GitHub-backed,
cross-family-reviewed lifecycle. It is **general** — it could build a video game as well as research tooling;
*how* it builds is the point, *what* it builds is incidental. It is independent of the products it builds
(per the box-level vision in `~/AGENTS.md`): a product never depends back on this team's tooling at runtime.

## The pipeline (ship-change)

The agents ARE the engineers. Every change is **authored by one model family and reviewed by the OTHER**
(Claude-authored -> Codex reviews; vice-versa) — a foreign family is the safeguard. The human is the
staff-engineer / PM: sets **direction** (the Issue + the `needs-shaping -> ready` shaping) and gates *which*
work happens, **not each PR's merge**. Architectural and mechanical changes alike merge on the cross-family
review + checks; there is no per-change classification or human design approval.

`ship-change` (plugin `aar-engineering`) drives it: Issue -> worktree branch -> design doc -> draft PR ->
cross-family `--scaffold` design review -> implement -> cross-family `--code` review -> tracked `.aar-ci`
checks + behavior smoke -> fail-closed merge-when-clean. The cross-family review engine is **verify-claims**
(`--scaffold`/`--code`), self-contained in this repo (it does not depend back on any product).

## Two layers

- **Build the product** — this team (ship-change) builds/reviews/ships changes to *products*.
- **Use the product** — that is the product's own concern, not this team's. This team ships software; it
  doesn't run research.

## The merge gate (fail-closed)

A change merges only on: cross-family `--code` review with **zero HIGH** (re-run on the final diff), the
tracked `.aar-ci/checks.sh` + behavior smoke green, and (on enforced repos) the required opposite-family
native approval. A crashed/garbled review never reads as clean.

## GitHub-native SWE pipeline (BYOK) — event-driven `ready` → merged PR

For this repo (and `automated-researcher`, where this capability shipped first — see
automated-researcher#378 / this repo's own agentic-engineering#43), the `ship-change` lifecycle above can run **without a
session dispatching it**: a `ready` label launches an execution-tier Claude implementor via GitHub Actions,
and PR events run the cross-family Codex review natively. This section is this repo's own copy of that
capability — it is what this PR (agentic-engineering#44) adds, and it is deliberately the **last** change to this repo shipped
through the old tmux-dispatcher path; every change after this one, including corrections to this pipeline
itself, ships by labeling an Issue `ready`.

- **Flow:** the researcher (or an engineer bot) labels an Issue `ready` → `implement-on-ready.yml` runs the
  pinned Claude Code CLI (execution-tier `claude-sonnet-5`) against the issue, working on `agent/issue-<n>`,
  and opens a PR with `Closes #<n>` → `review-on-pr.yml` runs `openai/codex-action` against the diff and
  submits a native APPROVE/REQUEST_CHANGES review as the codex engineer bot → on `changes_requested`, an
  allowlisted mention comment on the PR fires `address-review.yml`, which re-dispatches the pinned CLI onto
  the SAME PR branch to address the findings and pushes, which fires `synchronize` and re-runs
  `review-on-pr.yml` automatically → branch protection (required opposite-family approval, once configured
  per Rollout below) + the implement workflow's auto-merge step close the loop once a round comes back
  clean. `checks.yml` runs `.aar-ci/checks.sh` as a required status check on every PR, agent or human
  authored — the same deterministic gate `ship-change`'s `wf.sh finish` runs by hand, now wired as a trusted
  GitHub check instead of relying on the implementor's own honor.
- **Authorization predicate:** a privileged implement run requires `issues: labeled` with
  `label.name == 'ready'` AND the labeling actor allowlisted AND (re-verified fresh, before any token is
  minted) the issue's current author AND label state — allowlist = the researcher (`antondelafuente`) +
  the two engineer bots (`claude-code-engineer[bot]`, `codex-engineer[bot]`), hard-coded in the workflow so
  a compromised in-repo config file can't widen who can trigger a privileged run. `workflow_dispatch`
  (issue-number input, actor allowlisted, same fresh re-verification) is the only other entry path — needed
  because label events don't fire retroactively. A privileged **address-review** run requires
  `issue_comment: created` on a PR (not a plain Issue) mentioning the claude engineer bot, the comment
  author allowlisted (same allowlist minus the claude bot itself, which is excluded as a trigger author —
  its own completion comments can contain the literal mention string and must not self-retrigger), AND
  (re-verified fresh, before any token is minted, via `gh pr view`) the PR is same-repo (no forks) and its
  author is exactly the claude engineer bot — the same spoof-resistant author predicate `review-on-pr.yml`
  uses.
- **This repo is PUBLIC** (unlike `automated-researcher`, which is private): anyone can open an Issue or
  comment. That changes what does real work in the trust model, so it is re-stated here rather than
  inherited silently:
  - **Fork PRs get no secrets and no review, by construction.** `review-on-pr.yml`'s job-level `if:`
    requires `github.event.pull_request.head.repo.full_name == github.repository`, which is false for every
    fork PR — a fork's `pull_request` run always carries a read-only token and zero repo secrets regardless
    of visibility (a GitHub Actions platform guarantee, not a private-repo one), so this predicate is
    necessary but was never doing extra work specific to privacy.
  - **The identity allowlists are the load-bearing control on a public repo**, verified exactly:
    `implement-on-ready.yml`'s `ALLOWLIST` and job-level `if:`, and `address-review.yml`'s job-level `if:`,
    both hard-code exactly `antondelafuente`, `claude-code-engineer[bot]` / `app/claude-code-engineer`, and
    `codex-engineer[bot]` / `app/codex-engineer` — the researcher plus the two engineer bots, both GitHub
    login representations each (`canonical-login.sh` normalizes between them). An Issue or comment from
    anyone else never reaches a privileged step, and the coarse job-level `if:` pre-filter is backed by a
    fresh re-verification against live state before any token is minted. The same allowlist also gates
    *content*, not just triggering: `implement-on-ready.yml` and `address-review.yml` each snapshot and
    filter the issue/PR comment thread (and, for `address-review.yml`, the PR's reviews) to allowlisted
    authors only before rendering the implementor's prompt, dropping and logging anything else
    (agentic-engineering#52) — a non-allowlisted account's comment or review never becomes part of what the
    model treats as spec, even if it's technically readable via the model's own `gh`/API access during the
    run.
  - **Accepted residual risk, re-justified for public:** the implementor agent executes repo-controlled code
    (tests, hooks) while holding its API key and a short-lived write-scoped GitHub token. The allowlist
    predicate above is what makes this acceptable on a *public* repo: it ensures only allowlisted-authored
    Issues and comments ever reach the agent as instructions, which means the code it then executes reduces
    to code from `main` (already passed this same review pipeline, or the manual bootstrap history before
    it), or code the pipeline's own claude-engineer-bot identity previously wrote on a branch it re-enters
    only after verifying that same identity authored it. It is never arbitrary fork or drive-by-comment
    content — privacy did no work in the original private-repo statement once traced through; the allowlist
    does. `checks.yml`'s required-status job carries the same residual risk on the same basis: it passes the
    `ANTHROPIC_API_KEY` repo secret to `.aar-ci/checks.sh` (read-only `GITHUB_TOKEN`, no write permissions)
    so `fake_home_smoke.sh` can run `claude plugin` headlessly on a GitHub runner (automated-researcher#396).
- **Concurrency is per-issue dedup, not a worker pool.** `implement-on-ready.yml`'s
  `concurrency: group: implement-issue-<n>` only prevents a duplicate run on the *same* issue. There is
  **no global cap** — GitHub Actions `concurrency` groups don't provide one. The spend guard is the
  researcher's deliberate one-at-a-time `ready` flip; don't build a queue to work around this without a
  deliberate follow-up decision to do so. This is also how the `ready` disposition's "explicit dispatch"
  requirement (above) is satisfied here: the label flip by an allowlisted actor IS the dispatch.
- **Codex review guidance (P0/P1 convention)** — the criteria `review-on-pr.yml` gives the Codex reviewer,
  pulled from this section at the PR's **base** ref (never the PR's own head, so a PR cannot weaken its own
  review criteria by editing this section in the same diff it's being reviewed for):
  <!-- CODEX-REVIEW-GUIDANCE:BEGIN -->
  - **P0 (blocking):** a correctness bug that breaks the change's stated purpose; a security issue (secret
    exposure, injection, privilege escalation, a trust-boundary violation); or a violation of one of this
    file's `Rules`. Blocks `APPROVE` — the PR gets `REQUEST_CHANGES` instead.
  - **P1 (non-blocking):** style, minor edge cases, suggestions, simplification opportunities. Recorded in
    the review body for a later human pass; never blocks merge on its own.
  - **Exhaustive enumeration:** each review must enumerate EVERY reachable blocking (P0) finding in the
    artifact as revised — re-verify the ENTIRE consistency surface (all files the change's rules must
    agree with), not only the diff or previously-cited lines. A finding that existed in a prior round and
    was not reported is a review-process defect.
  <!-- CODEX-REVIEW-GUIDANCE:END -->
- **Re-entry / retry:** re-dispatch an issue by removing and re-adding `ready`, or via
  `workflow_dispatch`. Post-review fixes ride `address-review.yml`'s mention flow instead: an allowlisted
  `@claude-code-engineer` comment on the PR re-dispatches the pinned CLI onto the same PR branch
  (`.github/prompts/address-review.md`), gated to the researcher + the codex engineer bot, same allowlist
  minus the claude bot itself. It never invokes the review itself — pushing a fix fires `synchronize`, which
  `review-on-pr.yml`'s own `cancel-in-progress` already handles.
- **Escalation (`needs-dispatcher`):** if the implementor is blocked, or a review finding conflicts with
  what the issue specifies, it labels the PR (or the issue, if no PR yet) `needs-dispatcher` and comments
  what's needed, then stops that thread of work. This defines only the label convention — the notifier that
  surfaces `needs-dispatcher` to a session or the researcher is instance wiring, not part of this product
  capability. A `ready` label's flip by an allowlisted human/bot is itself the "explicit dispatch" the
  `ready` disposition (above) requires — there is no separate per-run naming step once the label lands.
  `address-review.yml` runs use the same escalation convention on the PR it's already working.
  `needs-dispatcher` is distinct from `needs-senior-engineer` below: it is the implementor's own
  self-escalation when it is stuck or sees a contradiction, never applied by the round-limit/conflict-
  stagnation machinery, which summons the senior engineer instead.
- **Senior-engineer leg (in-flight PR adjudication; ported from automated-researcher#438 via
  agentic-engineering#63):** `senior-engineer.yml` is summoned by the `needs-senior-engineer` label landing
  on a PR — by the reconciler's round-budget trip, by `review-on-pr.yml`'s own round-limit trip
  (agentic-engineering#53's counting, reused — see submit-verdict below), by an implementor asking for
  help, or by a human — plus `workflow_dispatch` (PR number) as the manual lever, same actor allowlist as
  the other actuators. It runs a Fable-family agent (`claude-fable-5` — judgment-dense per model policy;
  these events are rare so per-event premium cost is acceptable) under a dedicated
  `senior-engineer-agent[bot]` App identity with `Contents: read`, `Pull requests: read-write`, `Issues:
  read-write` — it can comment and label but cannot push code, by construction. Its mandate: (1) verify
  every finding/dispute/conflict-cause EMPIRICALLY (read the code, run a one-command test) before
  adjudicating, never by weighing prose alone; (2) at a round-limit summons, descope FIRST — identify the
  diff slice blocking convergence, draft a follow-up-issue paragraph for it, and recommend landing the
  remainder, rather than defaulting to "one more round"; (3) hand the implementor **exact target
  semantics**, not finding-pointers — precise guidance converges in one push, vague pointing produces
  regressions; (4) a dispute must cite only escape hatches/safeguards that actually exist; (5) escalate
  anything needing instance state (pods, fleet, box) or researcher taste it can't verify — that is correct
  behavior, not a limitation. On success it posts a guidance comment through the existing allowlisted
  `@claude-code-engineer` mention path (re-dispatching the implementor via `address-review.yml`, whose
  allowlist includes `senior-engineer-agent[bot]` for exactly this) and clears `needs-senior-engineer`; when
  it escalates instead, it applies `needs-human` with a structured comment (the decision needed, the
  options, its own lean, and what happens by default if unanswered) and stops. **Loop guard:** it never
  dispatches more than once per label application, and if `needs-senior-engineer` REAPPEARS on the same PR
  N=2 times (a 3rd+ total application — counted from the issue's own `labeled` event timeline), it escalates
  straight to `needs-human` instead of running another round, since a converging guidance loop wouldn't need
  to be re-labeled. Fails gracefully (a clear skip log line, no error) while the dedicated App and its two
  secrets don't exist yet.
- **Review re-fire actuator:** `review-on-pr.yml` also accepts `workflow_dispatch` (input: `pr_number`),
  running the same authorize→review→verdict path against the PR's CURRENT head — same actor allowlist as
  implement-on-ready's dispatch path (re-verified fresh via `gh pr view`: same-repo, bot-authored, open).
  Useless against a still-conflicted PR (no merge ref to review); used by the reconciler below for the
  mergeable-but-unreviewed case, and as a hand tool.
- **Reconciler (scheduled, level-triggered; ported from automated-researcher#431/#513 via
  agentic-engineering#63):** GitHub fires no `pull_request` run at all while a PR is unmergeable at event
  time — the run targets `refs/pull/N/merge`, which can't be built while the PR conflicts with base. This is
  deterministic platform behavior, not dropped events: a sibling merge lands on main, a still-open same-area
  PR goes conflicted, and every subsequent `opened`/`synchronize` event on it produces nothing until a
  human/dispatcher notices. `reconcile-prs.yml` triggers on every push to `main` (low-latency primary
  detector — a sibling merge fires this within about a minute) with a ~10-minute schedule as the backstop
  for lost events and crashed runs, and walks open bot-authored PRs to repair this itself:
  `mergeable == CONFLICTING` → post the allowlisted `@claude-code-engineer` resolution-dispatch mention
  (round-budgeted; escalates to `needs-senior-engineer` instead of nudging forever once the head stops
  moving — see the senior-engineer leg above); `mergeable == MERGEABLE` with no completed codex review at
  the current head → re-fire `review-on-pr.yml` via the actuator above (the residual true-event-loss case,
  if one exists). It also skips any PR already carrying `needs-senior-engineer` or `needs-human` — those
  mean another leg of the pipeline (or a person) is already handling it.
- **Round-limit escalation now summons the senior engineer, not a human directly
  (agentic-engineering#63):** `review-on-pr.yml`'s submit-verdict job auto-dispatches an addressing round
  on every `REQUEST_CHANGES` verdict (the allowlisted `@claude-code-engineer` mention, gated on the same
  hard checks as the reconciler's own dispatch — an existing `needs-senior-engineer`/`needs-human` label
  skips it, and the PR head must not have moved since the review was submitted). Reusing
  agentic-engineering#53's round counting: once a PR reaches its consecutive-`CHANGES_REQUESTED` round
  limit, the pipeline applies `needs-senior-engineer` (summoning the leg above) with the codex reviewer's
  consolidated report attached, instead of escalating straight to `needs-human` — the adjudicator gets first
  crack at descoping or guiding before a human is paged.
- **Dispatcher playbook** — the operations a human/dispatcher uses to drive this pipeline day to day (each
  mechanic is defined above; this is the consolidated at-a-glance list):
  - Dispatch/re-dispatch an Issue: add `ready` (or remove it and re-add after ~5s so the label event
    re-fires), or `workflow_dispatch` with the issue number.
  - Trigger an addressing round on a PR carrying review findings: comment `@claude-code-engineer` plus
    guidance on the PR (allowlisted authors only — see "Re-entry / retry" above).
  - **PR gone silent (no checks/review run at all):** check `mergeable` first (`gh pr view <n> --json
    mergeable`) — don't reach for `gh pr update-branch` on reflex, since that only helps a base-branch fix
    that already landed. `CONFLICTING` → trigger a resolution round the same way the reconciler does
    (comment `@claude-code-engineer` asking it to merge origin/main, resolve, and push); `MERGEABLE` with no
    review at the current head → `gh workflow run review-on-pr.yml -f pr_number=<n>` (the actuator). The
    scheduled reconciler normally beats a human to both within ~10 minutes; this is the manual equivalent
    for when you don't want to wait.
  - Unblock a `needs-senior-engineer` Issue or PR: answer the blocking question in a comment, remove
    `needs-senior-engineer`, then re-flip `ready` (issue) or re-trigger addressing (PR) per the two bullets
    above.
  - Trigger a manual in-flight adjudication on a PR: `gh workflow run senior-engineer.yml -f pr_number=<n>`
    (works with or without `needs-senior-engineer` present — the manual lever doesn't require the label).
  - Unblock a `needs-human` PR: answer the structured question the senior engineer posted, remove
    `needs-human`, and re-apply `needs-senior-engineer` if you want another automated adjudication pass, or
    comment `@claude-code-engineer` directly if you already know the exact fix.
- **Secrets this flow needs** (instance-provisioned, never checked in): `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `CLAUDE_APP_ID`, `CLAUDE_APP_PRIVATE_KEY`, `CODEX_APP_ID`, `CODEX_APP_PRIVATE_KEY`.
  Until all six are set, `ready` events fail loudly in the Actions tab (a missing-secret error at
  token-mint) rather than silently doing something else. (On this repo, all six are already provisioned as
  of this PR.) The senior-engineer leg additionally needs `SENIOR_ENGINEER_APP_ID` +
  `SENIOR_ENGINEER_APP_PRIVATE_KEY`, but by design fails gracefully (a clear skip log line) rather than
  loudly while those two are unset, since it's an optional-until-provisioned addition to an already-working
  pipeline, not a bring-up dependency the way the original six are. The triager's sweep leg additionally
  needs the `CLAUDE_APP` GitHub App granted `Actions: write` (alongside its existing Issues/Contents scopes)
  so it can dispatch a per-issue assessment run for each straggler it finds.
- **Required-check status (as-built):** branch protection on `main` requires the `checks` status (the
  `checks.yml` Action) as a required GitHub-reported status, with `review-on-pr`'s native cross-family
  review as the required approving review — added via the owner-token maintenance path
  (`WF_GH_ALLOW_OWNER_WRITE=1`), since an engineer-bot App token cannot modify branch protection on itself.

## Cross-repo references

Cross-repo issue/PR references are fully qualified (`owner/repo#N` or a full URL) **everywhere** they're
written — commits, PRs, docs, and chat — never a bare `#N`. A bare `#N` auto-links against whatever repo
happens to be rendering it, not the repo the writer meant, and silently resolves to the wrong Issue or 404s.
(This repo's own DISPOSITIONS block once carried exactly this failure — a `#49` meant for a different repo,
fixed below.)

<!-- DISPOSITIONS:START -->
## Issue tracker — dispositions

Every open Issue carries a **disposition** — how it should be handled — orthogonal to its type
(`bug`/`enhancement`/…) and to open/closed. This is the definition (the product-owned, versioned part). The
assign-at-filing and maintain *procedures* live in the appropriate operating surface: reusable product feedback
machinery belongs in product skills, while deployment-only file bookkeeping belongs in consuming-instance
guidance. AGENTS.md holds the issue contract, not local workflow paths.

- **`ready`** — actionable now; any design is settled and lives in the implementing PR itself (design-in-PR).
  Implement + merge on the cross-family review + checks. `ready` is the only disposition **eligible**
  for auto-handling — but eligibility is not blind auto-merge: the auto-handler still runs the full
  cross-family review + checks. **Resolved (agentic-engineering#43):** on a repo with the GitHub-native SWE pipeline wired (an
  `implement-on-ready.yml`-equivalent workflow present), an ALLOWLISTED actor's `ready` label flip **is**
  itself the explicit dispatch — the workflow's own authorization predicate (allowlisted labeler AND a
  freshly-reverified, allowlisted issue author, before any token is minted) is what makes this safe, not a
  separate per-run naming step; per-issue concurrency dedup (no global worker pool) is the spend guard, not
  a human queueing each run — see this product's "GitHub-native SWE pipeline (BYOK)" AGENTS.md section. On a repo without that pipeline
  wired, the label alone is not enough: no Issue is auto-implemented without a separate explicit dispatch (a
  human or a dispatcher session naming it).
- **`needs-shaping`** — a direction, too vague to start; needs scoping into `ready` first, through a
  conversation with the researcher (which may produce a few `ready` tickets).
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**Triager (event-driven per-ticket assessment; ported from automated-researcher#437/#497 via
agentic-engineering#63):** `triage-assess.yml` assesses every newly opened/reopened Issue within minutes —
two independent blind model assessments (Fable, Sol — the same cross-family split `review-on-pr.yml` uses)
against `.github/triage/RUBRIC.md`, then a sighted adjudication pass that sees both and proposes a verdict
(`DO`/`SKIP`/`ASK`), an optional body-edit, and (for `DO`) a wave number — posted as a single idempotent
on-ticket assessment comment, never a label or body write. A weekly backstop sweep (`schedule`) catches
issues an event missed: it dispatches the same per-ticket assessment for every open, unlabeled-and-
unescalated issue with no assessment comment yet, then rebuilds a rollup digest comment on the tracking
issue (#64) listing every ticket already assessed and still awaiting a researcher decision. `needs-design`
is retired, same as automated-researcher's own convention — there is no separate "awaiting shaping" label
this triager introduces or resurrects; an Issue with no disposition is either fresh (about to get its
event-driven assessment) or already carries the triager's assessment comment, in which case the citation
below is exactly that comment.

**`unlabeled → ready` (or `needs-shaping → ready`) is the researcher's transition, in every lane.** An agent
records the flip only on the back of an actual researcher conversation, and the flip must **cite it** — a
comment on the issue summarizing/linking the shaping discussion (the triager's assessment comment, when one
already exists, is exactly this citation). An agent asked to *implement* an issue never flips its
disposition label as a step of implementing it — that would let it triage its own way in. This is a norm
every lane follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a
gate only at close) is that lane's own concern to build out.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
