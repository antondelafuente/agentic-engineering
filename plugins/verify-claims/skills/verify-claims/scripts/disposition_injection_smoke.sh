#!/usr/bin/env bash
# Deterministic smoke for the disposition-aware prompt injection in audit_experiment.sh.
# It exercises both SWE review modes via AUDIT_DRY_RUN so no model is invoked.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
AUDIT="$HERE/audit_experiment.sh"

[ -f "$AUDIT" ] || { echo "FAIL: audit_experiment.sh not found at $AUDIT" >&2; exit 1; }

unset AUDIT_VERIFIER_CMD AUDIT_CONSTITUTION DISPOSITION_FILE FRESH_SWEEP_FILE

TMP=$(mktemp -d "${TMPDIR:-/tmp}/disposition-injection-smoke.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PROPOSAL="$TMP/proposal.md"
DIFF="$TMP/change.diff"
DISP="$TMP/dispositions.json"
FRESH="$TMP/fresh_sweep.md"

cat > "$PROPOSAL" <<'EOF'
# Smoke proposal

## Problem

Exercise scaffold prompt assembly.
EOF

cat > "$DIFF" <<'EOF'
diff --git a/smoke.txt b/smoke.txt
new file mode 100644
index 0000000..b6fc4c6
--- /dev/null
+++ b/smoke.txt
@@ -0,0 +1 @@
+smoke
EOF

cat > "$DISP" <<'EOF'
{
  "findings": [
    {
      "id": "F1",
      "severity": "HIGH",
      "status": "fixed",
      "description": "prior smoke finding",
      "commit": "deadbeef"
    }
  ]
}
EOF

cat > "$FRESH" <<'EOF'
FINDING 1: HIGH [correctness]
  issue: candidate fresh sweep smoke
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok $*" >&2; }

expect_present() {
  local label=$1 needle=$2 haystack=$3
  grep -Fq -- "$needle" <<<"$haystack" || fail "$label: missing [$needle]"
  pass "$label: present [$needle]"
}

expect_absent() {
  local label=$1 needle=$2 haystack=$3
  if grep -Fq -- "$needle" <<<"$haystack"; then
    fail "$label: unexpected [$needle]"
  fi
  pass "$label: absent [$needle]"
}

run_prompt() {
  local mode=$1 variant=$2
  local input flag
  case "$mode" in
    scaffold) flag=--scaffold; input=$PROPOSAL ;;
    code) flag=--code; input=$DIFF ;;
    *) fail "unknown mode: $mode" ;;
  esac

  case "$variant" in
    none)
      env -u AUDIT_VERIFIER_CMD -u AUDIT_CONSTITUTION -u DISPOSITION_FILE -u FRESH_SWEEP_FILE \
        AAR_SUBSTRATE=claude AUDIT_DRY_RUN=1 \
        bash "$AUDIT" "$flag" "$input" "$ROOT"
      ;;
    disposition)
      env -u AUDIT_VERIFIER_CMD -u AUDIT_CONSTITUTION -u FRESH_SWEEP_FILE \
        AAR_SUBSTRATE=claude AUDIT_DRY_RUN=1 DISPOSITION_FILE="$DISP" \
        bash "$AUDIT" "$flag" "$input" "$ROOT"
      ;;
    fresh)
      env -u AUDIT_VERIFIER_CMD -u AUDIT_CONSTITUTION \
        AAR_SUBSTRATE=claude AUDIT_DRY_RUN=1 DISPOSITION_FILE="$DISP" FRESH_SWEEP_FILE="$FRESH" \
        bash "$AUDIT" "$flag" "$input" "$ROOT"
      ;;
    *) fail "unknown variant: $variant" ;;
  esac
}

for mode in scaffold code; do
  with_disp=$(run_prompt "$mode" disposition)
  expect_present "$mode with disposition" "STATEFUL DISPOSITION-AWARE MERGE-GATE REVIEW" "$with_disp"
  expect_present "$mode with disposition" "prior smoke finding" "$with_disp"
  expect_present "$mode with disposition" "status=fixed" "$with_disp"

  without_disp=$(run_prompt "$mode" none)
  expect_absent "$mode without disposition" "STATEFUL DISPOSITION-AWARE MERGE-GATE REVIEW" "$without_disp"
  expect_absent "$mode without disposition" "prior smoke finding" "$without_disp"
  expect_absent "$mode without disposition" "status=fixed" "$without_disp"
  expect_absent "$mode without disposition" "CANDIDATE FRESH-SWEEP FINDINGS" "$without_disp"

  with_fresh=$(run_prompt "$mode" fresh)
  expect_present "$mode with fresh sweep" "CANDIDATE FRESH-SWEEP FINDINGS" "$with_fresh"
  expect_present "$mode with fresh sweep" "candidate fresh sweep smoke" "$with_fresh"
done

echo "PASS disposition_injection_smoke" >&2
