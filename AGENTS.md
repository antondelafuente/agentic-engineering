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
- **Secrets this flow needs** (instance-provisioned, never checked in): `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `CLAUDE_APP_ID`, `CLAUDE_APP_PRIVATE_KEY`, `CODEX_APP_ID`, `CODEX_APP_PRIVATE_KEY`.
  Until all six are set, `ready` events fail loudly in the Actions tab (a missing-secret error at
  token-mint) rather than silently doing something else. (On this repo, all six are already provisioned as
  of this PR.)
- **Post-merge step, not this PR's concern:** branch protection's *required-check* addition for the new
  `checks` status (and, if desired, `review-on-pr`'s native review as a required approval) happens after
  this PR merges, via the owner-token maintenance path (`WF_GH_ALLOW_OWNER_WRITE=1`) — an engineer-bot App
  token cannot modify branch protection on itself. Until that lands, `checks.yml` still runs and posts its
  status on every PR, but is not yet a *required* gate for auto-merge; this gap is deliberately scoped and
  time-bounded (see agentic-engineering#44's description), not silently accepted indefinitely.

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

**`needs-shaping → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion. An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
