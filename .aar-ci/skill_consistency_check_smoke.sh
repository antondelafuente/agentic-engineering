#!/usr/bin/env bash
# Smoke for skill_consistency_check.sh (agentic-engineering#54). Builds a fixture copy of the real
# plugins/ tree (so every cross-reference the checker resolves — wf.sh verbs, scripts/<name> files —
# stays valid except the one deliberately-injected regression per scenario), then asserts:
#   - the real repo tree, unmodified, passes clean (the issue's "current main passes clean" bar, made
#     into an executable regression test rather than a one-time manual check)
#   - a reintroduced PR #51 round-3-style error (a prescribed `wf.sh issue edit`, which doesn't exist)
#     fails pass 1
#   - a reintroduced PR #51 round-8-style error (a contradictory cloud-ship frontmatter/body pipeline-
#     first assertion) fails pass 3
#   - an unmarked retired phrase fails pass 4
#   - a fenced-block ambient `gh` WRITE prescription fails pass 5
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CHECK="$HERE/skill_consistency_check.sh"
[ -x "$CHECK" ] || { echo "FAIL: skill_consistency_check.sh not executable at $CHECK"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

# fixture <name> — a fresh copy of the real plugins/ tree under $TMP/<name>/plugins; prints its root.
fixture() {
  local name dir
  name=$1
  dir="$TMP/$name"
  mkdir -p "$dir"
  cp -r "$ROOT/plugins" "$dir/plugins"
  echo "$dir"
}

expect() {  # expect <PASS|FAIL> <name> <fixture-root> [grep-pattern-required-in-output]
  local want name root pattern out rc got
  want=$1; name=$2; root=$3; pattern=${4:-}
  out=$("$CHECK" "$root" 2>&1); rc=$?
  got=PASS; [ "$rc" -ne 0 ] && got=FAIL
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: want $want got $got :: $out"; fails=1; return
  fi
  if [ -n "$pattern" ] && ! grep -q "$pattern" <<<"$out"; then
    echo "FAIL $name: exit code matched ($want) but output missing expected pattern '$pattern' :: $out"
    fails=1; return
  fi
  echo "ok   $name"
}

# 1. The real repo tree, unmodified: must pass clean (current-main-passes-clean, as an executable check).
BASE=$(fixture baseline)
expect PASS baseline-real-tree "$BASE"

# 2. PR #51 round-3-style regression: a prescribed `wf.sh issue edit` (no such wf.sh verb) — pass 1.
R3=$(fixture round3)
SC="$R3/plugins/aar-engineering/skills/ship-change/SKILL.md"
python3 - "$SC" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
needle = "wf.sh issue <claude|codex> create -R <owner/repo>"
assert needle in text, "fixture setup: expected ship-change SKILL.md usage line not found"
text = text.replace(needle, "wf.sh issue <claude|codex> edit -R <owner/repo>", 1)
open(p, "w", encoding="utf-8").write(text)
PY
expect FAIL round3-wf-issue-edit "$R3" "pass1:.*wf.sh issue ... edit"

# 3. PR #51 round-8-style regression: an unqualified cloud-ship preference claim and a pipeline-first
#    subordination claim both injected (self-contained — post-#51 main no longer carries an ambient
#    unqualified claim on its own) so the two disagree — pass 3.
R8=$(fixture round8)
SC8="$R8/plugins/aar-engineering/skills/ship-change/SKILL.md"
python3 - "$SC8" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
heading = "# ship-change — the GitHub-backed scaffold-change lifecycle\n"
assert heading in text, "fixture setup: expected ship-change SKILL.md top heading not found"
unqualified = (
    "\nAuthors should prefer the sibling `cloud-ship` skill for every repo-self-contained change.\n"
)
text = text.replace(heading, heading + unqualified, 1)
marker = "## The non-negotiable properties"
assert marker in text, "fixture setup: expected ship-change SKILL.md section not found"
subordinate = (
    "## Routing (fixture)\n\n"
    "On a pipeline-enabled repo, the `cloud-ship` skill is for repo-self-contained changes on "
    "non-pipeline repos, ranked behind the pipeline.\n\n"
)
text = text.replace(marker, subordinate + marker, 1)
open(p, "w", encoding="utf-8").write(text)
PY
expect FAIL round8-contradictory-frontmatter "$R8" "pass3:.*unqualified cloud-ship preference"

# 4. Retired-phrase denylist: an unmarked hit outside any LEGACY span — pass 4.
P4=$(fixture pass4)
VC="$P4/plugins/verify-claims/skills/verify-claims/SKILL.md"
printf '\nThis paragraph reintroduces the retired dispatcher contract wording, unmarked.\n' >> "$VC"
expect FAIL pass4-unmarked-retired-phrase "$P4" "pass4:.*retired phrase 'dispatcher contract'"

# 5. Prohibited-op grep: a fenced block prescribing a bare ambient `gh issue create` — pass 5.
P5=$(fixture pass5)
VC5="$P5/plugins/verify-claims/skills/verify-claims/SKILL.md"
printf '\n```\ngh issue create -R owner/repo -t "..." -b "..."\n```\n' >> "$VC5"
expect FAIL pass5-fenced-ambient-gh-write "$P5" "pass5:.*ambient 'gh issue create'"

# 6. Pass 2 is flag-only: two canonical anchors for the same routing concern must WARN, never fail the run.
P2=$(fixture pass2)
VC2="$P2/plugins/verify-claims/skills/verify-claims/SKILL.md"
CS2="$P2/plugins/aar-engineering/skills/cloud-ship/SKILL.md"
printf '\n<!-- ROUTING:fixture-concern -->\nThis paragraph states the fixture routing concern canonically.\n<!-- ROUTING-END:fixture-concern -->\n' >> "$VC2"
printf '\n<!-- ROUTING:fixture-concern -->\nA second canonical statement of the fixture routing concern, which should only WARN.\n<!-- ROUTING-END:fixture-concern -->\n' >> "$CS2"
expect PASS pass2-duplicate-anchor-flags-not-fails "$P2" "pass2: routing concern 'fixture-concern' has 2 canonical anchors"

# 7. Prohibited-op grep: fenced `gh issue comment` (WRITE_VERBS is now one set shared by issue/pr,
#    mirrored from gh-guard.sh) outside any researcher/legacy escape — pass 5.
P7=$(fixture pass7)
VC7="$P7/plugins/verify-claims/skills/verify-claims/SKILL.md"
printf '\n```\ngh issue comment 123 -b "..."\n```\n' >> "$VC7"
expect FAIL pass5-fenced-gh-issue-comment "$P7" "pass5:.*ambient 'gh issue comment'"

# 8. Same prescription, but inside a tilde fence — the CommonMark-correct fence parser must still catch it.
P8=$(fixture pass8)
VC8="$P8/plugins/verify-claims/skills/verify-claims/SKILL.md"
printf '\n~~~\ngh issue comment 123 -b "..."\n~~~\n' >> "$VC8"
expect FAIL pass5-tilde-fenced-gh-issue-comment "$P8" "pass5:.*ambient 'gh issue comment'"

# 9. `gh api` write hole: a fenced `gh api` call carrying a body-implying field flag — pass 5.
P9=$(fixture pass9)
VC9="$P9/plugins/verify-claims/skills/verify-claims/SKILL.md"
printf '\n```\ngh api -f title="..." repos/owner/repo/issues\n```\n' >> "$VC9"
expect FAIL pass5-fenced-gh-api-write "$P9" "pass5:.*ambient 'gh api' WRITE"

# 10. Bare `gh api` with no method/body flag defaults to GET and must still pass — no false positive.
P10=$(fixture pass10)
VC10="$P10/plugins/verify-claims/skills/verify-claims/SKILL.md"
printf '\n```\ngh api repos/owner/repo/issues\n```\n' >> "$VC10"
expect PASS pass5-fenced-gh-api-read "$P10"

[ "$fails" = 0 ] && { echo "[skill_consistency_check_smoke] PASS"; exit 0; } || { echo "[skill_consistency_check_smoke] FAIL"; exit 1; }
