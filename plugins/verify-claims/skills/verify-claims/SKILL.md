---
name: verify-claims
description: The cross-family adversarial SWE-review engine that ship-change gates on — the engineering review half, owned by agentic-engineering. audit_experiment --scaffold reviews a PRODUCT/SCAFFOLD change PROPOSAL (a skill edit, a new convention, a migration) against ARCHITECTURE dimensions (right seam, DRY/canonical-home, blast radius, reversibility, instance↔product leak, contract clarity, convention-match); audit_experiment --code reviews a DIFF against IMPLEMENTATION dimensions (correctness, edge-cases, regression, security, simplify). Both are read by the OPPOSITE model family from the change's author (an author can't catch its own flaws). Use when design-reviewing or code-reviewing a scaffold/product change before it lands. (The experiment-audit modes — verify_claim / --design / --data / close — live in the research product's verify-claims, automated-researcher, NOT here.)
---

# verify-claims — the SWE-review engine (don't review your own change)

An agent cannot reliably catch its own flaws: whoever wrote a change believes it's right. This skill
routes a proposed **product/scaffold change** to a FRESH adversarial reviewer of the OPPOSITE model
family from the author — the DESIGN of the change (`--scaffold`) and its IMPLEMENTATION diff (`--code`).
It is the SWE-pipeline review engine that **`ship-change`** gates on; ship-change sources this reviewer
from agentic-engineering (via `locate_swe_audit`, base-ref materialized) regardless of which repo is
under review, so the reviewer is never the one supplied by the branch being reviewed.

> **Scope:** this is the ENGINEERING review engine (`--scaffold` / `--code`) ONLY. The EXPERIMENT-audit
> ladder (`verify_claim` facts / `--design` logic / `--data` data / close evidence) lives in the RESEARCH
> product's verify-claims (`automated-researcher`). The two copies are deliberately disjoint.

## The two modes

- **`audit_experiment.sh --scaffold <proposal.md> [context-dir] [out]`** → `<proposal>.SCAFFOLD_AUDIT.md`.
  Reviews the DESIGN of a change (a proposal doc, which doubles as the ADR + PR description) against
  ARCHITECTURE dimensions: right seam/abstraction · DRY (does a canonical home already exist) · blast
  radius/dependents · reversibility · instance↔product leak · interface/contract clarity for a
  zero-context consumer · simplest-thing/scope · convention-match. The foreign family reads the proposal
  AND the real tree (the context dir) to check claims like "no home exists" against reality. Context
  defaults to the proposal's git root.
- **`audit_experiment.sh --code <diff-file> [context-dir] [out]`** → `<diff>.CODE_REVIEW.md`. Reviews the
  IMPLEMENTATION diff against: correctness · edge-cases (unset/empty under `set -u`, quoting, silent
  degrade) · regression (does it break a path it touches) · security/safety (leaks, destructive ops
  without the guarded form, bypassable gates) · simplify. Does NOT re-litigate design (that was
  `--scaffold`). Context defaults to the CWD's git root (the diff is transient).

`--scaffold` reviews the proposal BEFORE the build (keeps the reviewer at the seam, not anchored on a
finished diff); `--code` reviews the diff at PR time. An implementation-only change skips straight to `--code`.

## Cross-family is mechanical (not just documented)

Both modes REQUIRE `AAR_SUBSTRATE` = the change AUTHOR's family (exactly `claude` or `codex`; it blocks
otherwise — no default that would let a Codex author be reviewed by Codex). The auditor is the OTHER
family, and the script refuses to run if the auditor family would match the author.
- Claude author (auditor defaults to Codex): `AAR_SUBSTRATE=claude audit_experiment.sh --scaffold <proposal.md>`
- Codex author (point the auditor at Claude): `AAR_SUBSTRATE=codex AUDIT_VERIFIER_CMD='claude -p …' audit_experiment.sh --scaffold <proposal.md>`

Both read the context repo's `AGENTS.md` as the conventions to judge against (fail loud if absent) — the
repo UNDER REVIEW's conventions, even though the reviewer engine itself comes from agentic-engineering.

## Output + operational notes

Output (both modes): severity-rated `FINDING`s with citations, a `SUMMARY: high=.. med=.. low=..` line,
and the dimensions where nothing material was found. "No material finding" is allowed and common — it
does NOT cry wolf. Verifier output is atomic: the response is written to a temp file and moved to the
final findings path only after the verifier exits successfully; while it is still running, an
absent/empty findings file is not evidence of a hang — inspect the process/log state instead of killing
or retrying solely because the file has not appeared.

- Default verifier: OpenAI Codex CLI (`codex` on PATH, authed; `--sandbox read-only`). Override with
  `AUDIT_VERIFIER_CMD` (must be a DIFFERENT family than `AAR_SUBSTRATE`).
- `AUDIT_DRY_RUN=1` dumps the assembled prompt without invoking a model (the CI testability seam).
- `ship-change` supplies a disposition file at the merge-gate for a STATEFUL re-review — it judges the
  author's dispositions and surfaces only genuinely-new or invalid-disposition HIGHs.
