#!/usr/bin/env bash
# Smoke for dispatch-cloud-ship.sh's `dupe-gate` subcommand (#22): the OK path + every fail-closed REFUSE
# path. Self-contained + OFFLINE — feeds pre-computed PR/branch hit strings straight to the pure `dupe_gate`
# function via the `dupe-gate` subcommand (no gh/git network calls), exactly as close_cloud_ship_smoke.sh
# covers close-cloud-ship.sh's `gate`/`dispo-gate` offline.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DISPATCH="$HERE/dispatch-cloud-ship.sh"
[ -f "$DISPATCH" ] || { echo "FAIL: dispatch-cloud-ship.sh not found at $DISPATCH"; exit 1; }

fails=0

expect() { # expect <OK|REFUSE> <name> <issue> <prs> <branches>
  local want=$1 name=$2 issue=$3 prs=$4 branches=$5 out rc got
  out=$(bash "$DISPATCH" dupe-gate "$issue" "$prs" "$branches" 2>&1); rc=$?
  got=OK; [ "$rc" -ne 0 ] && got=REFUSE
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want $want got $got :: $out"; fails=1
  fi
}

# 1. No open PR, no in-flight branch -> OK.
expect OK clean "22" "" ""

# 2. An open PR referencing the issue -> REFUSE.
expect REFUSE pr-hit "22" "https://github.com/o/r/pull/40" ""

# 3. An in-flight branch matching the issue -> REFUSE.
expect REFUSE branch-hit "22" "" "cloud-ship/22-dupe-guard"

# 4. Both an open PR AND an in-flight branch -> REFUSE (the exact #22 incident shape).
expect REFUSE both-hits "22" "https://github.com/o/r/pull/40" "change/22-dupe-guard"

# 5. Multiple PR hits (one per line) -> REFUSE, all named in the reason.
out=$(bash "$DISPATCH" dupe-gate "22" "$(printf 'https://github.com/o/r/pull/40\nhttps://github.com/o/r/pull/41')" "" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'pull/40' && printf '%s' "$out" | grep -q 'pull/41'; then
  echo "ok   multi-pr-hits"
else
  echo "FAIL multi-pr-hits: $out"; fails=1
fi

# 6. Blank-only inputs (whitespace lines) count as no hits -> OK (mirrors gate_record's blank-line tolerance).
expect OK blank-inputs "22" "
" "
"

# 7. The gate prints the canonical OK token on success (contract with the launcher).
out=$(bash "$DISPATCH" dupe-gate "22" "" "" 2>&1)
printf '%s' "$out" | grep -q '^DUPE-GATE: OK' && echo "ok   ok-token" || { echo "FAIL ok-token: '$out'"; fails=1; }

# 8. A REFUSE prints the canonical REFUSE token + a reason.
out=$(bash "$DISPATCH" dupe-gate "22" "https://github.com/o/r/pull/40" "" 2>&1)
printf '%s' "$out" | grep -q '^DUPE-GATE: REFUSE ' && echo "ok   refuse-token" || { echo "FAIL refuse-token: '$out'"; fails=1; }

# ---- the -b <branch> naming validation (enforces cloud-ship/<issue>-<slug>, #22 code-review Finding 3) ----
# Pure string check via the `validate-branch` subcommand — no network, no launch clone needed.
expect_branch() { # expect_branch <OK|REFUSE> <name> <issue> <branch>
  local want=$1 name=$2 issue=$3 branch=$4 out rc got
  out=$(bash "$DISPATCH" validate-branch "$issue" "$branch" 2>&1); rc=$?
  got=OK; [ "$rc" -ne 0 ] && got=REFUSE
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want $want got $got :: $out"; fails=1
  fi
}

# 9. A correctly-prefixed branch (cloud-ship/<issue>-<slug>) passes validation -> OK.
expect_branch OK branch-ok "22" "cloud-ship/22-dupe-guard"

# 10. A branch with no issue-number prefix at all -> REFUSE.
expect_branch REFUSE branch-no-prefix "22" "some-random-branch"

# 11. A branch prefixed for a DIFFERENT issue -> REFUSE.
expect_branch REFUSE branch-wrong-issue "22" "cloud-ship/99-other-issue"

# 12. An on-box `change/<issue>-*` branch name is not accepted by THIS launcher (cloud-ship runs push
#     cloud-ship/<issue>-* branches only) -> REFUSE.
expect_branch REFUSE branch-change-prefix-rejected "22" "change/22-dupe-guard"

# 13. The branch check prints its own distinct token (not the dupe-gate token).
out=$(bash "$DISPATCH" validate-branch "22" "some-random-branch" 2>&1)
printf '%s' "$out" | grep -q '^BRANCH-CHECK: REFUSE ' && echo "ok   branch-check-token" || { echo "FAIL branch-check-token: '$out'"; fails=1; }

if [ "$fails" -eq 0 ]; then echo "dispatch_cloud_ship_smoke: ALL PASS"; else echo "dispatch_cloud_ship_smoke: FAILURES"; fi
exit "$fails"
