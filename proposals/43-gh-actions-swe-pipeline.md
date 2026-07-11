# Proposal: GitHub-native SWE pipeline for agentic-engineering (#43)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Today, every change to this repo ships through a dispatched tmux session running `ship-change`'s `wf.sh`
lifecycle by hand: a dispatcher launches an implementor, watches its pane on a 5-minute cadence, nudges
stalls, and reaps the session after merge. `automated-researcher` proved (agentic-engineering#43's design
trail, automated-researcher#378 spec v2, bug-chain fixes automated-researcher#381-#408) that this same lifecycle can run
**without a session dispatching it**: a `ready` label on an Issue launches an execution-tier Claude
implementor via GitHub Actions; PR events run the cross-family Codex review natively; branch protection +
auto-merge close the loop. That capability exists only on `automated-researcher` (private) today. This repo
— `agentic-engineering`, the team's own tooling repo, and **public** — still runs the old tmux-dispatcher
path for every change, including this one (the bootstrap exception `ship-change` SKILL.md names: "the driver
can't ship its own first change through itself").

This PR is that follow-up, and it is also the **last** old-style dispatch for this repo: once it merges, a
`ready` label is enough to dispatch a change to agentic-engineering itself.

## Approach

Copy the four workflows, the two prompts, and the identity-canonicalization helper verbatim in mechanism
from `automated-researcher`'s `main` (not from the spec — main already embodies every bug-chain fix through
automated-researcher#408), and adapt only what the repo/trust-model difference requires:

1. **`.github/workflows/implement-on-ready.yml`** — `issues.labeled` (`ready`) or `workflow_dispatch` →
   re-verifies the issue's live author + label state (never trusts the coarse job-level `if:` alone) →
   renders `.github/prompts/implement.md` → mints a `claude-code-engineer[bot]` App token → runs the pinned
   Claude Code CLI (`2.1.207`, launched directly rather than through the wrapper action, per automated-researcher#387/#388) with
   `--model claude-sonnet-5` → opens a PR closing the issue → a second, fresh-runner job enables auto-merge.
2. **`.github/workflows/review-on-pr.yml`** — `pull_request` (opened/synchronize/ready_for_review), gated to
   same-repo PRs authored by the claude engineer bot (the fork-PR / human-PR exclusion is a job-level `if:`
   on the spoof-resistant App actor identity, not a title/label/branch match) → pulls prior review/comment
   history for disposition-aware re-review → runs `openai/codex-action` (`model: gpt-5.6-sol`, `effort:
   medium`, strict JSON output schema) against the PR's own base-ref-pinned P0/P1 guidance → a second job
   submits the verdict as a native APPROVE/REQUEST_CHANGES review from the `codex-engineer[bot]` App,
   re-checking the head SHA hasn't moved since the review started.
3. **`.github/workflows/address-review.yml`** — `issue_comment: created`, gated to a `@claude-code-engineer`
   mention from the allowlist (researcher + codex bot; the claude bot is explicitly excluded as a trigger
   author per automated-researcher#400/PR#401, since its own completion comments can contain the literal
   mention string) → re-verifies the PR is same-repo, authored by the claude bot, and open → re-dispatches
   the pinned CLI onto the SAME PR branch → pushes, which fires `synchronize` and lets `review-on-pr.yml`
   re-run itself (this workflow never invokes review directly). Job-level (not workflow-level) concurrency,
   per automated-researcher#400: a skipped job (non-matching comment) must not cancel an in-flight round.
4. **`.github/workflows/checks.yml`** — required-status gate on every PR (agent or human authored): pins the
   Claude CLI on the runner (automated-researcher#407/#408, so `fake_home_smoke.sh` can shell out to
   `claude`), passes `ANTHROPIC_API_KEY` through, materializes `checks.sh` + the trust-boundary smoke
   scripts from the PR's **base** ref before running them (so a PR can't weaken its own required gate in the
   same diff), and runs `.aar-ci/checks.sh` on the changed-path list.
5. **`.github/scripts/canonical-login.sh` + `canonical_login_smoke.sh`** — the App-identity canonicalization
   helper (`app/<slug>` ⇄ `<slug>[bot]`) the allowlist checks above depend on, and its offline smoke
   (automated-researcher#381/#382). Copied verbatim — it is repo-agnostic.
6. **`.github/prompts/implement.md` + `address-review.md`** — the implementor/address-review prompts. Copied
   with one substantive edit: the "accepted residual risk" paragraph is rewritten for a public repo (see
   below) rather than carrying the private-repo framing verbatim.
7. **`AGENTS.md`**` — a new "GitHub-native SWE pipeline (BYOK)" section (mirroring
   automated-researcher's, which explicitly named this repo as the follow-up), with the flow, the
   authorization predicate, concurrency semantics, the `CODEX-REVIEW-GUIDANCE` P0/P1 markers
   `review-on-pr.yml` reads from the base ref, re-entry/mention semantics, the `needs-dispatcher` escalation
   convention, and the six required secrets — **plus a public-repo trust-model restatement** (next section).

### Public-repo trust model — re-examined, not copied blind

`automated-researcher` is private and single-author; its accepted-residual-risk statement ("the implementor
executes repo-controlled code while holding its API key and a short-lived write-scoped GitHub token") leans
on that privacy. `agentic-engineering` is **public**: anyone can open an Issue or comment. The predicate that
makes the same residual-risk statement hold here is the **identity allowlist**, so it has to be exactly
right, not merely present:

- **Fork PRs get no secrets and no review**, by construction, not by an explicit skip: `review-on-pr.yml`'s
  job-level `if:` requires `github.event.pull_request.head.repo.full_name == github.repository`, which is
  false for every fork PR — `pull_request` events from forks never reach a step that touches a secret.
  Verified this predicate is unchanged from automated-researcher's copy (it was already written
  fork-aware, since GitHub Actions' `pull_request` trigger semantics — not the private/public
  distinction — is what makes fork PRs unprivileged: a fork PR's `pull_request` run always uses the base
  repo's workflow file with a read-only token and no access to repo secrets, regardless of visibility).
- **The dispatch and mention-flow allowlists are the load-bearing control**, now that "private repo" can't
  do any of the work: `implement-on-ready.yml`'s `ALLOWLIST` and job-level `if:`, and
  `address-review.yml`'s job-level `if:`, both hard-code exactly `antondelafuente`,
  `claude-code-engineer[bot]` / `app/claude-code-engineer`, and `codex-engineer[bot]` / `app/codex-engineer`
  — verified byte-for-byte against automated-researcher's copy (same three identities, same two
  representations each) and against this repo's actual bot commit identities
  (`git log --format='%an <%ae>'` confirms `claude-code-engineer[bot]` and `codex-engineer[bot]` are the
  live identities here too — same GitHub Apps, shared across both repos). An Issue or PR comment from
  anyone else never reaches the coarse `if:`, and even if it did, the re-verification step (fresh `gh`
  lookup, before any token mint) checks the SAME allowlist against live state, not the event payload.
- **Re-justifying "the implementor executes repo-controlled code while holding credentials" for public:** the
  predicate above ensures only allowlisted-authored *Issues* and *comments* ever reach the agent as
  instructions. What code the agent then executes is a separate question, answered by **who could have
  gotten code onto the branch it's working on**: `implement-on-ready.yml` creates a fresh branch off
  `main` for a fresh implementation (main's content is whatever already passed this same review pipeline,
  or the manual bootstrap history before it), and `address-review.yml` only ever re-enters an
  **already-open PR whose author is verified to be the claude engineer bot itself** — a PR authored by
  anyone else is refused before any checkout of PR-head content. So "repo-controlled code executed by the
  implementor" reduces to: code from `main`, or code the pipeline's own bot previously wrote on its own
  branch. It is never arbitrary fork or drive-by-comment content, on a public repo exactly as on a private
  one — the allowlist predicate is what carries that guarantee across the visibility boundary, not repo
  privacy itself (which did no real work in the original statement once you trace through it). This is
  stated explicitly in the new AGENTS.md section rather than left implicit.

## Alternatives considered

- **Leave agentic-engineering on the tmux-dispatcher path indefinitely.** Rejected: automated-researcher's
  numbers (bug-chain fixes automated-researcher#381-#408 all already fixed on main) show the GH-native path is now the proven,
  lower-supervision-cost mechanism; there's no reason for the team's own tooling repo to lag its own
  product's rollout, and the design ticket (#43) named this repo explicitly as in-scope.
- **Widen the allowlist to any repo collaborator, since it's public and PRs are review-gated anyway.**
  Rejected: the review gate protects the *code that lands*, not what the *implementor executes while
  working* (it holds `ANTHROPIC_API_KEY` + a write-scoped token for the whole run, before any review
  happens). The allowlist stays exactly the researcher + the two engineer bots, matching
  automated-researcher's copy.
- **Re-derive .aar-ci/checks.sh and fake_home_smoke.sh from automated-researcher's copies instead of
  patching this repo's own.** Rejected per the dispatch brief: this repo's `checks.sh` already has
  repo-specific sections (README-namespace check, DISPOSITIONS sync, a dozen per-plugin smoke hooks)
  automated-researcher's doesn't carry, and vice versa. Ported only the two behavior fixes
  (`fake_home_smoke.sh`'s automated-researcher#396 API-key fallback seeding and automated-researcher#407 stderr surfacing / `command -v claude`
  pre-check) into this repo's existing script, and added one new `checks.sh` section (canonical-login smoke)
  this repo didn't need before this PR.

## Blast radius

- **New surface only:** `.github/workflows/*.yml` (4 new files), `.github/scripts/canonical-login.sh` +
  its smoke (2 new files), `.github/prompts/*.md` (2 new files), `AGENTS.md` (one new section, additive —
  the existing `DISPOSITIONS` block is untouched), `.aar-ci/fake_home_smoke.sh` (two behavior-fix hunks
  ported in-place), `.aar-ci/checks.sh` (one new section, additive).
- **Nothing existing changes behavior:** no existing skill, plugin, or `wf.sh` code path is touched. The
  `ship-change` lifecycle itself is unmodified — it remains the fallback path (per its own SKILL.md: "the
  on-box path and the fallback... use it when the change needs box-local state, or when the cloud surface
  fails twice on the same Issue").
- **Instance-owned, not this PR's concern:** the six GitHub Actions secrets are already provisioned
  (confirmed via `gh secret list`), and repo-wide auto-merge is already enabled. Branch-protection's
  *required-check* addition for the new `checks` status (and, if desired, a required-review addition
  mirroring automated-researcher's) is a **post-merge** step — see Rollout below.

## Design review triage (`--scaffold`, PR #44 round 1: 4 HIGH, 2 MED)

- **F1 (HIGH, "skips the mandatory --scaffold design review") — DISPUTED.** The GH-native pipeline
  deliberately replaces the generic `ship-change` per-run stage sequence (design doc → `--scaffold` review →
  implement → `--code` review) with design-in-ticket + a single PR-side review, exactly as
  automated-researcher's already-live copy does and as issue #43's body states explicitly ("Design: lives IN
  the ticket... a formal design gate is redundant ceremony"). This PR's own one-time addition of the
  pipeline *is* going through the full `wf.sh` lifecycle including this very `--scaffold` round — the
  finding conflates the (retired-by-design) per-issue design-review stage with the (still-mandatory, still
  running) design review of the pipeline-adding change itself.
- **F2 (HIGH, "hard-codes one customer... instead of exposing trusted deployment configuration seams") —
  DISPUTED.** The hard-coded allowlist lives in this repo's own `.github/workflows/*.yml` (repo-level CI
  config), not in the generic `aar-engineering` plugin (which does use config seams —
  `WF_ENGINEER_TOKEN_CMD_*`, `WF_READONLY_TOKEN_CMD`, etc. — throughout). automated-researcher's identical
  copy hard-codes its own allowlist for a stated security reason: "hard-coded deliberately... so a
  compromised in-repo file can't widen who can trigger a privileged run" (implement-on-ready.yml). Sourcing
  the allowlist from repo config would reintroduce exactly the vulnerability that comment documents.
  Verified byte-for-byte match against automated-researcher's copy (same three identities, same two login
  representations each) and against this repo's live bot commit identities.
- **F3 (HIGH, "workflows active at merge while the checks required-status gate is deferred") — DEFERRED, per
  explicit dispatch-brief scoping.** Real: until branch protection requires the new `checks` status (and
  optionally the native review), `gh pr merge --auto` on a future dispatched PR could complete once the
  codex review approves, without `checks.sh` having been a *required* gate (it still runs and posts a
  status either way). This exact ordering — land the workflows, then a human/owner-token pass adds the
  required-check — mirrors how automated-researcher itself operates today (branch protection there
  currently requires `checks`, added outside this PR-equivalent's own diff) and is explicitly named in this
  dispatch's brief as a post-merge, owner-token step (branch-protection writes need the elevated-owner-token
  + `WF_GH_ALLOW_OWNER_WRITE=1` path per the ship-change RUNBOOK, not something an engineer-bot-authored PR
  can do to itself). Mitigated in this revision by stating the gap explicitly and prominently (AGENTS.md
  pipeline section + PR description "post-merge" checklist) rather than leaving it implicit, and by the fact
  that nothing in this PR *triggers* on merge — the risk window only opens when a future issue is labeled
  `ready`, which the same human/dispatcher controls.
- **F4 (HIGH, "ready-label-flip = dispatch contradicts the disposition contract's 'undecided' boundary") —
  ACCEPTED.** Real and correctly targeted: the canonical `DISPOSITIONS.md` block still said the auto-handler
  boundary was undecided, which this PR's own pipeline section would have directly contradicted. Issue #43
  names resolving exactly this as in-scope ("The DISPOSITIONS.md auto-handler boundary gets its answer...
  resolved as: ready on the coding repos = dispatched, with a concurrency cap as the spend guard"). Fixed:
  the `ready` bullet in both `AGENTS.md`'s canonical block and its synced
  `plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md` copy now states the resolution —
  on a repo with the pipeline wired, an allowlisted actor's label flip **is** the explicit dispatch (the
  workflow's own re-verified authorization predicate is what makes it safe); repos without the pipeline
  wired keep the old rule. (automated-researcher's own DISPOSITIONS block still says "undecided" — it
  predates this resolution and is out of scope for this PR; worth a follow-up there.)
- **F5 (MED, "two independently live implementations of the same mechanism, no canonical source") —
  DEFERRED.** Real tension, but no reusable-workflow infrastructure exists yet to de-duplicate GitHub Actions
  YAML across independent repos without adding a cross-repo trust dependency neither pipeline currently
  needs. Noted as a candidate follow-up issue, not blocking this rollout.
- **F6 (MED, "P0/P1 codex-action reviewer replaces verify-claims --code without demonstrating semantic
  equivalence") — DEFERRED.** Mirrors automated-researcher's live precedent exactly. The semantic mapping is
  explicit in the guidance markers this PR adds: P0 blocks `APPROVE` (⇔ HIGH blocks `wf.sh finish`'s merge),
  P1 is recorded but non-blocking (⇔ MED/LOW). A stronger formal equivalence proof is future work, not a
  blocker for adopting the same mechanism this repo's own sibling product already runs.

## Rollout + rollback

- **Rollout:** merges as an ordinary reviewed PR through the (final) manual `wf.sh` dispatch. No workflow in
  this PR fires anything automatically on merge — `implement-on-ready.yml` only triggers on a *future*
  `ready` label event or explicit `workflow_dispatch`, so landing this PR is inert until the next Issue is
  labeled `ready`. **Post-merge step (dispatcher-owned, not this PR):** add the new `checks` status (and, if
  desired, `review-on-pr`'s native review) to this repo's branch-protection required-checks list, mirroring
  automated-researcher's as-built config — the tooling works without it, but the required-check gate is what
  makes `checks.yml` load-bearing rather than advisory.
- **Rollback:** delete/disable the four workflow files (or flip the repo-level Actions toggle off) to fall
  back to `ship-change`'s tmux-dispatcher path with zero code changes elsewhere — the lifecycle those
  workflows automate is the *same* `wf.sh`-shaped process, just manually driven again. No data migration, no
  schema, nothing to unwind.
