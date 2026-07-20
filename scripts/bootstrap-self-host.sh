#!/usr/bin/env bash
# bootstrap-self-host.sh (agentic-engineering#61) — install the GitHub-native SWE pipeline (implement-on-ready
# -> review-on-pr -> address-review -> checks, plus the reconciler that keeps a conflicted/stranded PR from
# going silent) onto a fresh target repo checkout.
#
# What this script does (pure local file operations, no network/gh calls unless you pass the --repo-*
# flags below):
#   1. Copies the pipeline's workflow assets from THIS repo into --target-dir, substituting this repo's
#      hard-coded identities (researcher login, the engineer App slugs, the claude App's numeric bot id)
#      for the ones you supply, and qualifying every bare same-repo/repo-only issue reference the copied
#      files' provenance comments carry (`#N` / `agentic-engineering#N` / `automated-researcher#N`) into
#      `antondelafuente/<repo>#N`, so a comment citing this project's own history doesn't silently
#      misresolve against the target repo's own issue tracker once it's copied elsewhere (AGENTS.md's
#      "Cross-repo references" rule: a same-repo bare ref becomes exactly this hazard the moment it's
#      copied into a different repo unqualified).
#   2. Ensures --target-dir/AGENTS.md carries the <!-- CODEX-REVIEW-GUIDANCE:BEGIN/END --> block
#      review-on-pr.yml reads its P0/P1 severity convention from (creating a minimal AGENTS.md if none
#      exists, or appending the block if one exists without it).
#   3. With --senior-engineer-slug, additionally installs the senior-engineer leg (in-flight PR
#      adjudication): senior-engineer.yml + its prompt. Without it, review-on-pr.yml's round-limit and
#      reconcile-prs.yml's own escalations still apply `needs-senior-engineer`, but nothing consumes it —
#      identical to how this repo's OWN pipeline behaves before that leg's App/secrets are provisioned
#      (AGENTS.md: "fails gracefully ... since it's an optional-until-provisioned addition to an
#      already-working pipeline"), never a self-hosting-specific defect. reconcile-prs.yml is always
#      installed regardless: its conflict-nudge and mergeable-re-review legs need only the two Apps this
#      script already requires, and degrade to a logged warning (never a crash) on the one leg that does
#      call out to senior-engineer.yml when it isn't installed.
#
# What this script does NOT do: create the GitHub Apps (author + reviewer, plus the optional senior-engineer
# adjudicator) — that is an unavoidable manual web-UI flow (App creation has no non-interactive API) — or
# mint/rotate their keys. The optional --repo flag below can automate the parts of setup that ARE just API
# calls once those Apps exist (labels, branch protection, the "Allow auto-merge" repo setting); secrets
# still need real values you obtain from the App UI and your model provider, see the printed checklist at
# the end.
#
# See plugins/aar-engineering/skills/ship-change/RUNBOOK.md's "Self-hosting" section for the full checklist
# this script automates part of, including what remains manual and why.
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bootstrap-self-host.sh --target-dir <path> --researcher-login <login> \
         --claude-slug <slug> --claude-bot-id <numeric-id> --codex-slug <slug> \
         [--senior-engineer-slug <slug>] \
         [--repo <owner/name> --create-labels --branch-protection --enable-auto-merge]

Required:
  --target-dir <path>        Local checkout of the fresh repo to install into (any git work tree, including
                              a linked worktree — checked via `git rev-parse --is-inside-work-tree`).
  --researcher-login <login> GitHub login of the human who may flip `ready` / trigger re-dispatch.
  --claude-slug <slug>       GitHub App slug for the implementor/author engineer bot (no "[bot]" suffix).
                              This App additionally needs `Actions: write` (alongside Contents/Pull
                              requests/Issues read-write) so reconcile-prs.yml can re-fire review-on-pr.yml
                              and summon senior-engineer.yml via workflow_dispatch.
  --claude-bot-id <id>       Numeric GitHub user id of that App's bot user (`gh api users/<slug>[bot]
                             --jq .id` once the App is created and installed).
  --codex-slug <slug>        GitHub App slug for the reviewer engineer bot (no "[bot]" suffix).

Optional:
  --senior-engineer-slug <slug>
                              GitHub App slug for the in-flight PR adjudicator (no "[bot]" suffix). When
                              given, also installs senior-engineer.yml + its prompt, so a review round-limit
                              or conflict-stagnation trip gets automated adjudication instead of sitting on
                              `needs-senior-engineer` until a human notices. Omit to skip this leg entirely
                              (reconcile-prs.yml and review-on-pr.yml still work without it — see the header
                              comment above for what degrades).

Require --repo and an authenticated `gh` with admin on the target repo:
  --repo <owner/name>        Target repo, for the flags below. Read from the target-dir git remote if
                              omitted and one of the flags below is passed.
  --create-labels            Create the `ready`, `needs-human`, `needs-dispatcher`, and
                              `needs-senior-engineer` labels (idempotent) — the pipeline applies all four
                              but never creates them.
  --branch-protection        Apply the documented branch-protection ruleset to `main` (required PR review +
                              status check `checks`, dismiss-stale-approvals, enforce_admins, no force-push).
  --enable-auto-merge        Turn on the repo's "Allow auto-merge" setting (implement-on-ready.yml's
                              auto-merge step degrades to a comment without it).

  -h, --help                 Print this help and exit.
USAGE
}

TARGET_DIR=""
RESEARCHER_LOGIN=""
CLAUDE_SLUG=""
CLAUDE_BOT_ID=""
CODEX_SLUG=""
SENIOR_ENGINEER_SLUG=""
REPO=""
DO_LABELS=0
DO_BRANCH_PROTECTION=0
DO_AUTO_MERGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target-dir) TARGET_DIR=$2; shift 2 ;;
    --researcher-login) RESEARCHER_LOGIN=$2; shift 2 ;;
    --claude-slug) CLAUDE_SLUG=$2; shift 2 ;;
    --claude-bot-id) CLAUDE_BOT_ID=$2; shift 2 ;;
    --codex-slug) CODEX_SLUG=$2; shift 2 ;;
    --senior-engineer-slug) SENIOR_ENGINEER_SLUG=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --create-labels) DO_LABELS=1; shift ;;
    --branch-protection) DO_BRANCH_PROTECTION=1; shift ;;
    --enable-auto-merge) DO_AUTO_MERGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for pair in "TARGET_DIR:--target-dir" "RESEARCHER_LOGIN:--researcher-login" "CLAUDE_SLUG:--claude-slug" \
            "CLAUDE_BOT_ID:--claude-bot-id" "CODEX_SLUG:--codex-slug"; do
  var=${pair%%:*}; flag=${pair#*:}
  if [ -z "${!var}" ]; then
    echo "missing required $flag (see --help)" >&2
    exit 1
  fi
done
case "$CLAUDE_BOT_ID" in
  ''|*[!0-9]*) echo "--claude-bot-id must be a plain integer (got '$CLAUDE_BOT_ID')" >&2; exit 1 ;;
esac
# `-d "$TARGET_DIR/.git"` rejected a linked worktree (git worktree checkouts have a .git FILE pointing at
# the real gitdir, not a .git directory) even though it's a perfectly valid work tree to install into.
# `git rev-parse --is-inside-work-tree` validates both forms the same way git itself does.
if ! git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "--target-dir '$TARGET_DIR' is not a git work tree (git rev-parse --is-inside-work-tree failed)" >&2
  exit 1
fi
# --is-inside-work-tree is true from any subdirectory of a checkout, not just its root -- every relative
# `$rel` path this script writes (`.github/workflows/...`, `AGENTS.md`, etc.) is meant to land at the
# checkout's root, so a --target-dir that's actually a nested subdirectory would install assets one or more
# levels below where the workflows/AGENTS.md are expected to live (agentic-engineering#73 review, round 2).
# `pwd -P` on both sides resolves symlinks/relative segments so the comparison isn't fooled by a
# differently-spelled but identical path.
TARGET_TOPLEVEL=$(git -C "$TARGET_DIR" rev-parse --show-toplevel)
if [ "$(cd "$TARGET_DIR" && pwd -P)" != "$(cd "$TARGET_TOPLEVEL" && pwd -P)" ]; then
  echo "--target-dir '$TARGET_DIR' is a subdirectory of a git work tree, not its root ('$TARGET_TOPLEVEL') -- pass the checkout's top-level directory" >&2
  exit 1
fi

echo "[bootstrap] source: $SOURCE_ROOT" >&2
echo "[bootstrap] target: $TARGET_DIR" >&2

# Ref-qualification pass (shared by copy_templated and copy_verbatim below, agentic-engineering#73 review):
# this repo's own comments cite its history via bare/repo-only refs (`#15`, `agentic-engineering#63`,
# `automated-researcher#438`) that are correct only in THIS repo's own rendering context. Copied verbatim
# into a different repo, a bare/repo-only ref either silently resolves against the TARGET repo's own issue
# tracker or just reads as inert, confusing text — precisely the hazard AGENTS.md's "Cross-repo references"
# section already names for any port between repos (that section names the bare `#N` form itself as the
# hazard, not just the `repo#N` form — round 1 of this PR's own review only qualified the latter). Every
# remaining bare `#N` in a file that lives in THIS repo cites one of THIS repo's own issues, so it qualifies
# to `antondelafuente/agentic-engineering#N`. Already-`repo#N`-qualified and already fully-qualified
# `antondelafuente/...#N` forms are protected through a placeholder round-trip first, so the bare-ref rule
# never re-matches (and re-prefixes) a ref another rule already qualified. `|` is the sed delimiter
# throughout since the patterns themselves contain `#`.
REF_QUALIFY_SED=(
  -e 's|antondelafuente/agentic-engineering#|@@AEQ_PLACEHOLDER@@|g'
  -e 's|antondelafuente/automated-researcher#|@@ARQ_PLACEHOLDER@@|g'
  -e 's|agentic-engineering#|@@AE_PLACEHOLDER@@|g'
  -e 's|automated-researcher#|@@AR_PLACEHOLDER@@|g'
  -e 's|#([0-9]+)|antondelafuente/agentic-engineering#\1|g'
  -e 's|@@AEQ_PLACEHOLDER@@|antondelafuente/agentic-engineering#|g'
  -e 's|@@ARQ_PLACEHOLDER@@|antondelafuente/automated-researcher#|g'
  -e 's|@@AE_PLACEHOLDER@@|antondelafuente/agentic-engineering#|g'
  -e 's|@@AR_PLACEHOLDER@@|antondelafuente/automated-researcher#|g'
)

# Identity substitution for copy_templated files: every substitution below replaces a literal SUBSTRING
# ("claude-code-engineer" inside "claude-code-engineer[bot]" / "app/claude-code-engineer" alike), which is
# deliberate: it collapses what would otherwise be three separate rules (bare/"[bot]"/"app/" forms) into
# one, since the bare slug is always a substring of the other two forms. `senior-engineer-agent` is only
# substituted when --senior-engineer-slug was given; otherwise it's left as an inert, never-matching
# placeholder (see the leftover guard below).
IDENTITY_SED=(
  -e "s/claude-code-engineer/${CLAUDE_SLUG}/g"
  -e "s/codex-engineer/${CODEX_SLUG}/g"
  -e "s/294932622\+/${CLAUDE_BOT_ID}+/g"
  -e "s#antondelafuente([^/])#${RESEARCHER_LOGIN}\\1#g"
  -e "s#antondelafuente\$#${RESEARCHER_LOGIN}#g"
)
if [ -n "$SENIOR_ENGINEER_SLUG" ]; then
  IDENTITY_SED+=(-e "s/senior-engineer-agent/${SENIOR_ENGINEER_SLUG}/g")
fi

# copy_templated <relative-path> — copy SOURCE_ROOT/<path> to TARGET_DIR/<path>, ref-qualifying provenance
# citations and substituting this repo's hard-coded identities for the caller-supplied ones.
copy_templated() {
  local rel=$1 src dst
  src="$SOURCE_ROOT/$rel"
  dst="$TARGET_DIR/$rel"
  [ -f "$src" ] || { echo "source asset missing: $rel" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  sed -E "${REF_QUALIFY_SED[@]}" "${IDENTITY_SED[@]}" "$src" > "$dst"
  [ -x "$src" ] && chmod +x "$dst"
  echo "[bootstrap] wrote $rel" >&2
}

# copy_verbatim <relative-path> — no IDENTITY strings in these files (verified: agentic-engineering#61), so
# no identity substitution runs; still ref-qualified (agentic-engineering#73 review) since several of them
# carry the same bare/repo-only provenance citations copy_templated files do.
copy_verbatim() {
  local rel=$1 src dst
  src="$SOURCE_ROOT/$rel"
  dst="$TARGET_DIR/$rel"
  [ -f "$src" ] || { echo "source asset missing: $rel" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  sed -E "${REF_QUALIFY_SED[@]}" "$src" > "$dst"
  [ -x "$src" ] && chmod +x "$dst"
  echo "[bootstrap] wrote $rel (ref-qualified, no identity strings)" >&2
}

# Core pipeline, always installed: the four workflows the acceptance test (ready -> merged PR) exercises,
# plus reconcile-prs.yml (agentic-engineering#73 review P0: without it, a PR that goes CONFLICTING or whose
# review-round auto-dispatch silently fails to post never gets another pipeline event — see
# review-on-pr.yml's own header comment for why `pull_request` never re-fires on an unmergeable PR).
# reconcile-prs.yml's conflict-nudge and mergeable-re-review legs work with only the two Apps this script
# already requires; only its round-limit/stranded-label paths call out to senior-engineer.yml, and those
# degrade to a harmless logged warning (never a crash) when that optional leg isn't installed — see the
# header comment at the top of this file.
for rel in \
  .github/workflows/implement-on-ready.yml \
  .github/workflows/review-on-pr.yml \
  .github/workflows/address-review.yml \
  .github/workflows/reconcile-prs.yml \
  .github/prompts/implement.md \
  .github/prompts/address-review.md \
; do
  copy_templated "$rel"
done

# Optional senior-engineer leg (agentic-engineering#73 review P0: review-on-pr.yml's round-limit escalation
# and reconcile-prs.yml's own escalations always target `needs-senior-engineer` — installing this leg is
# what makes that label mean something instead of a dead end). Skipped by default so a self-hoster who
# hasn't provisioned the third App yet gets exactly the same graceful "label lands, nothing consumes it
# yet" behavior this repo's own pipeline has before SENIOR_ENGINEER_APP_ID/KEY are set (AGENTS.md), not a
# broken install.
if [ -n "$SENIOR_ENGINEER_SLUG" ]; then
  for rel in \
    .github/workflows/senior-engineer.yml \
    .github/prompts/senior-engineer.md \
  ; do
    copy_templated "$rel"
  done
else
  echo "[bootstrap] note: --senior-engineer-slug not given; senior-engineer.yml not installed. 'needs-senior-engineer' will still be applied by review-on-pr.yml/reconcile-prs.yml at their round/conflict limits, with nothing to consume it until you re-run with this flag (or a human clears it per AGENTS.md's Dispatcher playbook) -- same as this repo's own pipeline before that leg's App/secrets are provisioned, not a self-hosting-specific gap." >&2
fi

for rel in \
  .github/workflows/checks.yml \
  .github/scripts/canonical-login.sh \
  .github/scripts/canonical_login_smoke.sh \
  .aar-ci/checks.sh \
  .aar-ci/config \
  .aar-ci/fake_home_smoke.sh \
  .aar-ci/skill_consistency_check.sh \
  .aar-ci/skill_consistency_check_smoke.sh \
; do
  copy_verbatim "$rel"
done

# Guard: every hard-coded identity string this repo's workflows carry must have been substituted (or, for
# `senior-engineer-agent[bot]` when --senior-engineer-slug wasn't given, be one this script deliberately
# leaves inert — see above) — a leftover literal here would silently authorize THIS repo's
# researcher/bots on the target repo instead of the caller-supplied ones. `antondelafuente/` (followed by a
# slash) is excluded: those are provenance comments citing real antondelafuente/automated-researcher#NNN or
# antondelafuente/agentic-engineering#NNN issues upstream (including ones this same run just qualified
# above), not an allowlist entry, and substituting them would misattribute that history to the caller's own
# login instead.
LEFTOVER_TARGETS=(
  "$TARGET_DIR/.github/workflows/implement-on-ready.yml"
  "$TARGET_DIR/.github/workflows/review-on-pr.yml"
  "$TARGET_DIR/.github/workflows/address-review.yml"
  "$TARGET_DIR/.github/workflows/reconcile-prs.yml"
  "$TARGET_DIR/.github/prompts/implement.md"
  "$TARGET_DIR/.github/prompts/address-review.md"
)
LEFTOVER_PATTERN="claude-code-engineer|codex-engineer|antondelafuente([^/]|\$)"
if [ -n "$SENIOR_ENGINEER_SLUG" ]; then
  LEFTOVER_TARGETS+=(
    "$TARGET_DIR/.github/workflows/senior-engineer.yml"
    "$TARGET_DIR/.github/prompts/senior-engineer.md"
  )
  LEFTOVER_PATTERN="${LEFTOVER_PATTERN}|senior-engineer-agent"
fi
leftover=$(grep -rEl "$LEFTOVER_PATTERN" "${LEFTOVER_TARGETS[@]}" 2>/dev/null || true)
if [ -n "$leftover" ]; then
  echo "::error::identity substitution left this repo's own identity strings in: $leftover" >&2
  exit 1
fi

if [ -z "$SENIOR_ENGINEER_SLUG" ]; then
  echo "[bootstrap] note: 'senior-engineer-agent[bot]' allowlist entries in the copied workflows/prompts left as-is (optional third leg, not installed this run)" >&2
fi

# AGENTS.md: review-on-pr.yml reads its P0/P1 severity convention from the PR base ref's AGENTS.md, between
# these exact markers. Extracted live from THIS repo's AGENTS.md (not a copy frozen into this script) so it
# can never drift from the guidance review-on-pr.yml's own comments document.
GUIDANCE=$(sed -n '/<!-- CODEX-REVIEW-GUIDANCE:BEGIN -->/,/<!-- CODEX-REVIEW-GUIDANCE:END -->/p' "$SOURCE_ROOT/AGENTS.md")
[ -n "$GUIDANCE" ] || { echo "::error::could not extract CODEX-REVIEW-GUIDANCE markers from $SOURCE_ROOT/AGENTS.md" >&2; exit 1; }

TARGET_AGENTS="$TARGET_DIR/AGENTS.md"
BEGIN_COUNT=0; END_COUNT=0
if [ -f "$TARGET_AGENTS" ]; then
  BEGIN_COUNT=$(grep -c '<!-- CODEX-REVIEW-GUIDANCE:BEGIN -->' "$TARGET_AGENTS" || true)
  END_COUNT=$(grep -c '<!-- CODEX-REVIEW-GUIDANCE:END -->' "$TARGET_AGENTS" || true)
fi

# A block only counts as well-formed with exactly one of each marker, BEGIN strictly before END --
# duplicate markers or a reversed BEGIN/END pair would make review-on-pr.yml's
# `sed -n '/BEGIN/,/END/p'` extraction silently grab the wrong span instead of the intended guidance
# (agentic-engineering#73 review, round 2: the round-1 fix only checked marker presence, not count/order).
BLOCK_OK=0
if [ "$BEGIN_COUNT" = 1 ] && [ "$END_COUNT" = 1 ]; then
  BEGIN_LINE=$(grep -n '<!-- CODEX-REVIEW-GUIDANCE:BEGIN -->' "$TARGET_AGENTS" | cut -d: -f1)
  END_LINE=$(grep -n '<!-- CODEX-REVIEW-GUIDANCE:END -->' "$TARGET_AGENTS" | cut -d: -f1)
  [ "$BEGIN_LINE" -lt "$END_LINE" ] && BLOCK_OK=1
fi

if [ ! -f "$TARGET_AGENTS" ]; then
  {
    echo "# AGENTS.md"
    echo
    echo "## Codex review guidance (P0/P1 convention)"
    echo
    echo "Criteria \`review-on-pr.yml\` gives the Codex reviewer, read from this section at the PR's base ref:"
    echo
    printf '%s\n' "$GUIDANCE"
  } > "$TARGET_AGENTS"
  echo "[bootstrap] wrote AGENTS.md (new, with CODEX-REVIEW-GUIDANCE block)" >&2
elif [ "$BLOCK_OK" = 1 ]; then
  echo "[bootstrap] AGENTS.md already carries a well-formed CODEX-REVIEW-GUIDANCE block — left untouched" >&2
elif [ "$BEGIN_COUNT" = 0 ] && [ "$END_COUNT" = 0 ]; then
  {
    echo
    echo "## Codex review guidance (P0/P1 convention)"
    echo
    echo "Criteria \`review-on-pr.yml\` gives the Codex reviewer, read from this section at the PR's base ref:"
    echo
    printf '%s\n' "$GUIDANCE"
  } >> "$TARGET_AGENTS"
  echo "[bootstrap] appended CODEX-REVIEW-GUIDANCE block to existing AGENTS.md" >&2
else
  # Anything short of "exactly one BEGIN, one END, BEGIN before END" is worse than no block at all:
  # review-on-pr.yml's `sed -n '/BEGIN/,/END/p'` extraction would silently grab an empty/partial/wrong
  # span (missing marker, duplicate markers, or END-before-BEGIN all confuse that same range extraction)
  # instead of the clear "could not extract" failure a fully-missing block gets. Fail loudly instead of
  # silently accepting or guessing which part to fix.
  echo "::error::$TARGET_AGENTS carries a MALFORMED CODEX-REVIEW-GUIDANCE block (found $BEGIN_COUNT BEGIN marker(s), $END_COUNT END marker(s); need exactly one of each with BEGIN before END) -- fix or remove it by hand before re-running this script" >&2
  exit 1
fi

if [ "$DO_LABELS" = 1 ] || [ "$DO_BRANCH_PROTECTION" = 1 ] || [ "$DO_AUTO_MERGE" = 1 ]; then
  if [ -z "$REPO" ]; then
    REPO=$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##') || true
  fi
  [ -n "$REPO" ] || { echo "::error::--repo not given and could not infer owner/name from $TARGET_DIR's origin remote" >&2; exit 1; }
  command -v gh >/dev/null 2>&1 || { echo "::error::--create-labels/--branch-protection/--enable-auto-merge require the gh CLI, not found on PATH" >&2; exit 1; }
  echo "[bootstrap] repo-settings target: $REPO" >&2
fi

if [ "$DO_LABELS" = 1 ]; then
  gh label create ready --repo "$REPO" --color 0e8a16 --description "Dispatch implement-on-ready.yml for this issue" --force
  gh label create needs-human --repo "$REPO" --color d93f0b --description "Escalation: needs a human/dispatcher" --force
  gh label create needs-dispatcher --repo "$REPO" --color d93f0b --description "Implementor self-escalation: blocked or contradicted spec" --force
  gh label create needs-senior-engineer --repo "$REPO" --color fbca04 --description "Summons in-flight PR adjudication (round-limit / conflict-stagnation / help request)" --force
  echo "[bootstrap] labels ready + needs-human + needs-dispatcher + needs-senior-engineer created/updated on $REPO" >&2
fi

if [ "$DO_BRANCH_PROTECTION" = 1 ]; then
  protection_json=$(mktemp)
  trap 'rm -f "$protection_json"' EXIT
  cat > "$protection_json" <<JSON
{
  "required_status_checks": {"strict": true, "contexts": ["checks"]},
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 1, "dismiss_stale_reviews": true},
  "restrictions": null,
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
  gh api -X PUT "repos/$REPO/branches/main/protection" --input "$protection_json" > /dev/null
  echo "[bootstrap] branch protection applied to $REPO:main (see RUNBOOK.md 'What's enforced' for the as-built rationale)" >&2
fi

if [ "$DO_AUTO_MERGE" = 1 ]; then
  gh api -X PATCH "repos/$REPO" -f allow_auto_merge=true > /dev/null
  echo "[bootstrap] 'Allow auto-merge' enabled on $REPO" >&2
fi

SENIOR_ENGINEER_CHECKLIST=""
if [ -n "$SENIOR_ENGINEER_SLUG" ]; then
  SENIOR_ENGINEER_CHECKLIST="
  6. Create a third GitHub App, \"${SENIOR_ENGINEER_SLUG}\" (in-flight PR adjudicator). Permissions:
     Contents: Read, Pull requests: Read & write, Issues: Read & write. Install it on this repo and
     generate its private key.
  7. Add SENIOR_ENGINEER_APP_ID and SENIOR_ENGINEER_APP_PRIVATE_KEY (App id + .pem contents for
     \"${SENIOR_ENGINEER_SLUG}\") as Actions secrets. Until both are set, senior-engineer.yml skips itself
     with a clear log line rather than erroring — safe to leave unconfigured for a while, but a PR that
     hits the round-limit or a conflict-stagnation trip stays on \`needs-senior-engineer\` until you either
     set these or clear the label by hand (see AGENTS.md's Dispatcher playbook)."
fi

cat >&2 <<CHECKLIST

[bootstrap] Files written. Remaining manual steps (no API can do these non-interactively):

  1. Create two GitHub Apps under your account/org — Settings -> Developer settings -> GitHub Apps -> New:
       - "${CLAUDE_SLUG}" (implementor/author). Permissions: Contents: Read & write, Pull requests: Read &
         write, Issues: Read & write, Actions: Read & write (the last is for reconcile-prs.yml's
         workflow_dispatch re-fires of review-on-pr.yml/senior-engineer.yml).
       - "${CODEX_SLUG}" (reviewer).             Same permissions as above, minus Actions.
     Install both on this repo. Generate a private key for each (downloads a .pem).
  2. Add these six Actions secrets (repo Settings -> Secrets and variables -> Actions), or via
     \`gh secret set NAME --repo owner/name\`:
       CLAUDE_APP_ID, CLAUDE_APP_PRIVATE_KEY   (App id + the .pem contents for "${CLAUDE_SLUG}")
       CODEX_APP_ID,  CODEX_APP_PRIVATE_KEY    (App id + the .pem contents for "${CODEX_SLUG}")
       ANTHROPIC_API_KEY                        (implementor model calls)
       OPENAI_API_KEY                            (codex-action reviewer calls)
  3. If you didn't pass --create-labels: create the \`ready\`, \`needs-human\`, \`needs-dispatcher\`, and
     \`needs-senior-engineer\` labels.
  4. If you didn't pass --branch-protection: protect \`main\` (require 1 approving review + the \`checks\`
     status check, dismiss stale approvals, enforce_admins on, block force-push/deletion).
  5. If you didn't pass --enable-auto-merge: turn on this repo's "Allow auto-merge" setting (Settings ->
     General) — implement-on-ready.yml's auto-merge step degrades to a comment without it.${SENIOR_ENGINEER_CHECKLIST}

Once all of the above are in place: open an issue and label it \`ready\` — that's the acceptance test.
See plugins/aar-engineering/skills/ship-change/RUNBOOK.md's "Self-hosting" section for the full reference.
CHECKLIST
