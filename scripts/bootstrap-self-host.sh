#!/usr/bin/env bash
# bootstrap-self-host.sh (agentic-engineering#61) — install the GitHub-native SWE pipeline (implement-on-ready
# -> review-on-pr -> address-review -> checks) onto a fresh target repo checkout.
#
# What this script does (pure local file operations, no network/gh calls unless you pass the --repo-*
# flags below):
#   1. Copies the pipeline's workflow assets from THIS repo into --target-dir, substituting this repo's
#      hard-coded identities (researcher login, the two engineer App slugs, the claude App's numeric bot
#      id) for the ones you supply.
#   2. Ensures --target-dir/AGENTS.md carries the <!-- CODEX-REVIEW-GUIDANCE:BEGIN/END --> block
#      review-on-pr.yml reads its P0/P1 severity convention from (creating a minimal AGENTS.md if none
#      exists, or appending the block if one exists without it).
#
# What this script does NOT do: create the two GitHub Apps (author + reviewer) — that is an unavoidable
# manual web-UI flow (App creation has no non-interactive API) — or mint/rotate their keys. The optional
# --repo flag below can automate the parts of setup that ARE just API calls once those Apps exist (labels,
# branch protection, the "Allow auto-merge" repo setting); secrets still need real values you obtain from
# the App UI and your model provider, see the printed checklist at the end.
#
# See plugins/aar-engineering/skills/ship-change/RUNBOOK.md's "Self-hosting" section for the full checklist
# this script automates part of, including what remains manual and why.
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bootstrap-self-host.sh --target-dir <path> --researcher-login <login> \
         --claude-slug <slug> --claude-bot-id <numeric-id> --codex-slug <slug> \
         [--repo <owner/name>] [--create-labels] [--branch-protection] [--enable-auto-merge]

Required:
  --target-dir <path>        Local checkout of the fresh repo to install into (must be a git work tree).
  --researcher-login <login> GitHub login of the human who may flip `ready` / trigger re-dispatch.
  --claude-slug <slug>       GitHub App slug for the implementor/author engineer bot (no "[bot]" suffix).
  --claude-bot-id <id>       Numeric GitHub user id of that App's bot user (`gh api users/<slug>[bot]
                             --jq .id` once the App is created and installed).
  --codex-slug <slug>        GitHub App slug for the reviewer engineer bot (no "[bot]" suffix).

Optional (require --repo and an authenticated `gh` with admin on the target repo):
  --repo <owner/name>        Target repo, for the flags below. Read from the target-dir git remote if
                              omitted and one of the flags below is passed.
  --create-labels            Create the `ready` and `needs-human` labels (idempotent).
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
[ -d "$TARGET_DIR/.git" ] || { echo "--target-dir '$TARGET_DIR' is not a git work tree (no .git)" >&2; exit 1; }

echo "[bootstrap] source: $SOURCE_ROOT" >&2
echo "[bootstrap] target: $TARGET_DIR" >&2

# copy_templated <relative-path> — copy SOURCE_ROOT/<path> to TARGET_DIR/<path>, substituting this repo's
# hard-coded identities for the caller-supplied ones. Every substitution below replaces a literal SUBSTRING
# ("claude-code-engineer" inside "claude-code-engineer[bot]" / "app/claude-code-engineer" alike), which is
# deliberate: it collapses what would otherwise be three separate rules (bare/"[bot]"/"app/" forms) into
# one, since the bare slug is always a substring of the other two forms.
copy_templated() {
  local rel=$1 src dst
  src="$SOURCE_ROOT/$rel"
  dst="$TARGET_DIR/$rel"
  [ -f "$src" ] || { echo "source asset missing: $rel" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  sed -E \
    -e "s/claude-code-engineer/${CLAUDE_SLUG}/g" \
    -e "s/codex-engineer/${CODEX_SLUG}/g" \
    -e "s/294932622\+/${CLAUDE_BOT_ID}+/g" \
    -e "s#antondelafuente([^/])#${RESEARCHER_LOGIN}\\1#g" \
    -e "s#antondelafuente\$#${RESEARCHER_LOGIN}#g" \
    "$src" > "$dst"
  [ -x "$src" ] && chmod +x "$dst"
  echo "[bootstrap] wrote $rel" >&2
}

# copy_verbatim <relative-path> — no identity strings in these files (verified: agentic-engineering#61),
# copied byte-for-byte so a future identity-string addition to one of them doesn't silently go untemplated.
copy_verbatim() {
  local rel=$1 src dst
  src="$SOURCE_ROOT/$rel"
  dst="$TARGET_DIR/$rel"
  [ -f "$src" ] || { echo "source asset missing: $rel" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  [ -x "$src" ] && chmod +x "$dst"
  echo "[bootstrap] wrote $rel (verbatim)" >&2
}

for rel in \
  .github/workflows/implement-on-ready.yml \
  .github/workflows/review-on-pr.yml \
  .github/workflows/address-review.yml \
  .github/prompts/implement.md \
  .github/prompts/address-review.md \
; do
  copy_templated "$rel"
done

for rel in \
  .github/workflows/checks.yml \
  .github/scripts/canonical-login.sh \
  .aar-ci/checks.sh \
  .aar-ci/config \
  .aar-ci/fake_home_smoke.sh \
  .aar-ci/skill_consistency_check.sh \
  .aar-ci/skill_consistency_check_smoke.sh \
; do
  copy_verbatim "$rel"
done

# Guard: every hard-coded identity string this repo's workflows carry must have been substituted (or, for
# `senior-engineer-agent[bot]`, be one this script deliberately leaves inert — see below) — a leftover
# literal here would silently authorize THIS repo's researcher/bots on the target repo instead of the
# caller-supplied ones. `antondelafuente/` (followed by a slash) is excluded: those are historical
# provenance comments citing real antondelafuente/automated-researcher#NNN issues upstream, not an
# allowlist entry, and substituting them would misattribute that history to the caller's own login instead
# (the same exclusion the substitution step above applies).
leftover=$(grep -rEl "claude-code-engineer|codex-engineer|antondelafuente([^/]|\$)" \
  "$TARGET_DIR/.github/workflows/implement-on-ready.yml" \
  "$TARGET_DIR/.github/workflows/review-on-pr.yml" \
  "$TARGET_DIR/.github/workflows/address-review.yml" \
  "$TARGET_DIR/.github/prompts/implement.md" \
  "$TARGET_DIR/.github/prompts/address-review.md" 2>/dev/null || true)
if [ -n "$leftover" ]; then
  echo "::error::identity substitution left this repo's own identity strings in: $leftover" >&2
  exit 1
fi

# senior-engineer-agent[bot] is deliberately NOT substituted or removed: it names an optional third leg
# (senior-engineer.yml / reconcile-prs.yml) this script does not install (out of scope per
# agentic-engineering#61 — the four workflows above are the full ready-to-merged-PR loop on their own).
# review-on-pr.yml's and address-review.yml's allowlists reference it only as an extra, never-populated
# entry: harmless until you separately add that leg, at which point re-run substitution or edit it in by
# hand.
echo "[bootstrap] note: 'senior-engineer-agent[bot]' allowlist entries left as-is (optional third leg, not installed by this script)" >&2

# AGENTS.md: review-on-pr.yml reads its P0/P1 severity convention from the PR base ref's AGENTS.md, between
# these exact markers. Extracted live from THIS repo's AGENTS.md (not a copy frozen into this script) so it
# can never drift from the guidance review-on-pr.yml's own comments document.
GUIDANCE=$(sed -n '/<!-- CODEX-REVIEW-GUIDANCE:BEGIN -->/,/<!-- CODEX-REVIEW-GUIDANCE:END -->/p' "$SOURCE_ROOT/AGENTS.md")
[ -n "$GUIDANCE" ] || { echo "::error::could not extract CODEX-REVIEW-GUIDANCE markers from $SOURCE_ROOT/AGENTS.md" >&2; exit 1; }

TARGET_AGENTS="$TARGET_DIR/AGENTS.md"
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
elif ! grep -q '<!-- CODEX-REVIEW-GUIDANCE:BEGIN -->' "$TARGET_AGENTS"; then
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
  echo "[bootstrap] AGENTS.md already carries a CODEX-REVIEW-GUIDANCE block — left untouched" >&2
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
  echo "[bootstrap] labels ready + needs-human created/updated on $REPO" >&2
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

cat >&2 <<CHECKLIST

[bootstrap] Files written. Remaining manual steps (no API can do these non-interactively):

  1. Create two GitHub Apps under your account/org — Settings -> Developer settings -> GitHub Apps -> New:
       - "${CLAUDE_SLUG}" (implementor/author).  Permissions: Contents: Read & write,
         Pull requests: Read & write, Issues: Read & write.
       - "${CODEX_SLUG}" (reviewer).             Same permissions as above.
     Install both on this repo. Generate a private key for each (downloads a .pem).
  2. Add these six Actions secrets (repo Settings -> Secrets and variables -> Actions), or via
     \`gh secret set NAME --repo owner/name\`:
       CLAUDE_APP_ID, CLAUDE_APP_PRIVATE_KEY   (App id + the .pem contents for "${CLAUDE_SLUG}")
       CODEX_APP_ID,  CODEX_APP_PRIVATE_KEY    (App id + the .pem contents for "${CODEX_SLUG}")
       ANTHROPIC_API_KEY                        (implementor model calls)
       OPENAI_API_KEY                            (codex-action reviewer calls)
  3. If you didn't pass --create-labels: create the \`ready\` and \`needs-human\` labels.
  4. If you didn't pass --branch-protection: protect \`main\` (require 1 approving review + the \`checks\`
     status check, dismiss stale approvals, enforce_admins on, block force-push/deletion).
  5. If you didn't pass --enable-auto-merge: turn on this repo's "Allow auto-merge" setting (Settings ->
     General) — implement-on-ready.yml's auto-merge step degrades to a comment without it.

Once all of the above are in place: open an issue and label it \`ready\` — that's the acceptance test.
See plugins/aar-engineering/skills/ship-change/RUNBOOK.md's "Self-hosting" section for the full reference.
CHECKLIST
