#!/usr/bin/env bash
# Smoke for skill_consistency_check.sh (agentic-engineering#54). Builds a fixture copy of the real
# plugins/ tree (so every cross-reference the checker resolves — wf.sh verbs, scripts/<name> files —
# stays valid except the one deliberately-injected regression per scenario), then asserts:
#   - the real repo tree, unmodified, passes clean (the issue's "current main passes clean" bar, made
#     into an executable regression test rather than a one-time manual check)
#   - a reintroduced agentic-engineering#51 round-3-style error (a prescribed `wf.sh issue edit`, which
#     doesn't exist) fails pass 1
#   - a reintroduced agentic-engineering#51 round-8-style error (a contradictory cloud-ship
#     frontmatter/body pipeline-first assertion) fails pass 3
#   - an unmarked retired phrase fails pass 4
#   - a duplicated routing anchor only WARNs (pass 2 never fails)
#   - a concrete-argument wf.sh example (no placeholders) passes pass 1
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

# 2. agentic-engineering#51 round-3-style regression: a prescribed `wf.sh issue edit` (no such wf.sh
#    verb) — pass 1.
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

# 3. agentic-engineering#51 round-8-style regression: an unqualified cloud-ship preference claim and a
#    pipeline-first subordination claim both injected (self-contained — post-agentic-engineering#51 main
#    no longer carries an ambient unqualified claim on its own) so the two disagree — pass 3.
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

# 5. Pass 2 is flag-only: two canonical anchors for the same routing concern must WARN, never fail the run.
P2=$(fixture pass2)
VC2="$P2/plugins/verify-claims/skills/verify-claims/SKILL.md"
CS2="$P2/plugins/aar-engineering/skills/cloud-ship/SKILL.md"
printf '\n<!-- ROUTING:fixture-concern -->\nThis paragraph states the fixture routing concern canonically.\n<!-- ROUTING-END:fixture-concern -->\n' >> "$VC2"
printf '\n<!-- ROUTING:fixture-concern -->\nA second canonical statement of the fixture routing concern, which should only WARN.\n<!-- ROUTING-END:fixture-concern -->\n' >> "$CS2"
expect PASS pass2-duplicate-anchor-flags-not-fails "$P2" "pass2: routing concern 'fixture-concern' has 2 canonical anchors"

# 6. A concrete-argument `wf.sh issue codex create` example (family + real sub-verb, no placeholders)
#    must pass pass 1 — the sub-verb is the token AFTER the family token, not "the first non-placeholder
#    token" (which would misread `codex` itself as the sub-verb).
P15=$(fixture pass15)
SC15="$P15/plugins/aar-engineering/skills/ship-change/SKILL.md"
printf '\nFor example: `wf.sh issue codex create -R owner/repo -t "..." -b "..."`.\n' >> "$SC15"
expect PASS pass1-concrete-wf-issue-codex-create "$P15"

[ "$fails" = 0 ] && { echo "[skill_consistency_check_smoke] PASS"; exit 0; } || { echo "[skill_consistency_check_smoke] FAIL"; exit 1; }
