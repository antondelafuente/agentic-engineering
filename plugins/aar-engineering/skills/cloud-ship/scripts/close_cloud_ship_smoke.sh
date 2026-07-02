#!/usr/bin/env bash
# Smoke for close-cloud-ship.sh's `gate` subcommand (#18): the PASS path + every fail-closed REFUSE path.
# Self-contained + OFFLINE — builds record fixtures in a tempdir; never touches the network (the `close`
# subcommand's PR/approve/merge are live GitHub actions and are NOT exercised here, exactly as the other
# *_smoke.sh files cover only the offline gate logic).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/close-cloud-ship.sh"
[ -f "$GATE" ] || { echo "FAIL: close-cloud-ship.sh not found at $GATE"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

SHA40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # a valid 40-hex reviewed head
OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # a different 40-hex head
BR=cloud-ship/308-productize

rec() { printf '%s' "$1" > "$TMP/rec.txt"; echo "$TMP/rec.txt"; }

# A well-formed PASS record fixture builder (branch/head/verdict parameterized).
mkrecord() { # mkrecord <branch> <head> <verdict>
  cat <<EOF
CLOUD-SHIP RUN (do not merge by hand — box closes the loop)
Branch: $1
Reviewed-Head: $2
Verdict: $3
Rounds: design=1 code=1

Some review verdict text here.
VERDICT: PASS
EOF
}

expect() { # expect <PASS|REFUSE> <name> <record-file> <remote-head> <branch>
  local want=$1 name=$2 r=$3 h=$4 b=$5 out rc got
  out=$(bash "$GATE" gate "$r" "$h" "$b" 2>&1); rc=$?
  got=PASS; [ "$rc" -ne 0 ] && got=REFUSE
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want $want got $got :: $out"; fails=1
  fi
}

# 1. Happy path: well-formed PASS record, branch matches, live head == Reviewed-Head -> PASS.
expect PASS happy "$(rec "$(mkrecord "$BR" "$SHA40" PASS)")" "$SHA40" "$BR"

# 1b. Case-insensitive head compare: uppercase live head still matches a lowercase Reviewed-Head -> PASS.
expect PASS head-case-insensitive "$(rec "$(mkrecord "$BR" "$SHA40" PASS)")" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "$BR"

# 2. Verdict FAIL -> REFUSE.
expect REFUSE verdict-fail "$(rec "$(mkrecord "$BR" "$SHA40" FAIL)")" "$SHA40" "$BR"

# 3. Post-review push: live head != Reviewed-Head -> REFUSE (the anti-post-review-push guard).
expect REFUSE head-moved "$(rec "$(mkrecord "$BR" "$SHA40" PASS)")" "$OTHER" "$BR"

# 4. Record replay: record names a DIFFERENT branch than requested -> REFUSE (the anti-replay guard).
expect REFUSE branch-mismatch "$(rec "$(mkrecord "other/branch" "$SHA40" PASS)")" "$SHA40" "$BR"

# 5. Reviewed-Head not 40-hex (short sha) -> REFUSE.
expect REFUSE head-short "$(rec "$(mkrecord "$BR" "aaaaaaa" PASS)")" "aaaaaaa" "$BR"

# 6. Reviewed-Head has non-hex chars -> REFUSE (no parseable Reviewed-Head line; sed's [0-9a-fA-F]+ won't match).
expect REFUSE head-nonhex "$(rec "$(mkrecord "$BR" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" PASS)")" "$SHA40" "$BR"

# 7. Missing Verdict line -> REFUSE.
expect REFUSE no-verdict "$(rec "$(printf 'CLOUD-SHIP RUN\nBranch: %s\nReviewed-Head: %s\n' "$BR" "$SHA40")")" "$SHA40" "$BR"

# 8. Missing Branch line -> REFUSE.
expect REFUSE no-branch "$(rec "$(printf 'CLOUD-SHIP RUN\nReviewed-Head: %s\nVerdict: PASS\n' "$SHA40")")" "$SHA40" "$BR"

# 9. Missing Reviewed-Head line -> REFUSE.
expect REFUSE no-head "$(rec "$(printf 'CLOUD-SHIP RUN\nBranch: %s\nVerdict: PASS\n' "$BR")")" "$SHA40" "$BR"

# 10. Not a CLOUD-SHIP RUN block (missing the marker header) -> REFUSE (a random comment can't be a record).
expect REFUSE not-a-record "$(rec "$(printf 'Random comment\nBranch: %s\nReviewed-Head: %s\nVerdict: PASS\n' "$BR" "$SHA40")")" "$SHA40" "$BR"

# 11. Empty live remote head (branch has no head on origin) -> REFUSE.
expect REFUSE empty-remote-head "$(rec "$(mkrecord "$BR" "$SHA40" PASS)")" "" "$BR"

# 12. Missing record file -> REFUSE.
expect REFUSE missing-record-file "$TMP/does-not-exist.txt" "$SHA40" "$BR"

# 13. Verdict PASS with trailing garbage on the line ("PASS now") must not parse as PASS -> REFUSE
#     (the anchored regex requires a single token, so this yields no parseable Verdict).
expect REFUSE verdict-trailing-token "$(rec "$(printf 'CLOUD-SHIP RUN\nBranch: %s\nReviewed-Head: %s\nVerdict: PASS now\n' "$BR" "$SHA40")")" "$SHA40" "$BR"

# 14. A blank first line before the marker is fine (marker is the first NON-blank line) -> PASS.
expect PASS leading-blank-line "$(rec "$(printf '\n%s' "$(mkrecord "$BR" "$SHA40" PASS)")")" "$SHA40" "$BR"

# 15. No branch argument supplied to the gate -> REFUSE (can't bind the record).
r=$(rec "$(mkrecord "$BR" "$SHA40" PASS)")
out=$(bash "$GATE" gate "$r" "$SHA40" "" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then echo "ok   no-branch-arg"; else echo "FAIL no-branch-arg: want REFUSE got PASS :: $out"; fails=1; fi

# 16. The gate prints the canonical PASS token on success (contract with the box operator).
r=$(rec "$(mkrecord "$BR" "$SHA40" PASS)")
out=$(bash "$GATE" gate "$r" "$SHA40" "$BR" 2>&1)
printf '%s' "$out" | grep -q '^CLOUD-SHIP-GATE: PASS$' && echo "ok   pass-token" || { echo "FAIL pass-token: '$out'"; fails=1; }

# 17. A REFUSE prints the canonical REFUSE token + a reason.
out=$(bash "$GATE" gate "$(rec "$(mkrecord "$BR" "$SHA40" FAIL)")" "$SHA40" "$BR" 2>&1)
printf '%s' "$out" | grep -q '^CLOUD-SHIP-GATE: REFUSE ' && echo "ok   refuse-token" || { echo "FAIL refuse-token: '$out'"; fails=1; }

if [ "$fails" -eq 0 ]; then echo "close_cloud_ship_smoke: ALL PASS"; else echo "close_cloud_ship_smoke: FAILURES"; fi
exit "$fails"
