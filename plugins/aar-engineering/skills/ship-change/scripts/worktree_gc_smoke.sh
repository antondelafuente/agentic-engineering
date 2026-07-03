#!/bin/bash
# worktree_gc_smoke.sh — smoke for `wf.sh gc` (#32): sweeping abandoned /tmp/wf-* worktrees + local
# change/* branches for runs that never reached `finish`. Self-contained: fake gh (no network, no real
# tokens), real local git repos/worktrees under a temp dir. Exercises every disposition gc can reach —
# especially the two fail-closed guards (design-review #33 F1): a MERGED/CLOSED PR whose local HEAD has
# diverged past the PR's last known head (headRefOid) is KEPT, not swept; and a PR-lookup failure that is
# NOT the specific "no pull requests found" message is KEPT, not treated as "no PR".
set -uo pipefail
WF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wf.sh
[ -f "$WF" ] || { echo "FAIL: wf.sh not found next to smoke" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }

fail=0
check(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1" >&2; fail=1; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wf-gc-smoke.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake gh: only implements `pr view <branch> --json ...`, driven by a fixture file per branch under
# $GH_FAKE_PR_DIR (name = branch with '/' -> '_'). Fixture format, first line: `<STATE> <num> [sha]`.
#   OPEN <num>                 -> PR open, never touch
#   MERGED|CLOSED <num> <sha>  -> PR resolved, headRefOid=<sha>
#   BOGUS <num>                -> an unrecognized state (defensive coverage of the fail-closed default)
#   ERROR                      -> the lookup fails for a reason OTHER than "no pull requests found"
#   (no fixture file at all)   -> gh's genuine "no pull requests found" — the real no-PR case
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
set -u
printf 'ARGS=%s\n' "$*" >> "${GH_FAKE_LOG:-/dev/null}"
# find "pr view <branch>" anywhere in argv (a leading -R <repo> may precede it)
branch=""; prev=""
for a in "$@"; do
  if [ "$prev" = view ]; then branch=$a; fi
  prev=$a
done
if printf ' %s ' "$*" | grep -q ' pr view ' && [ -n "$branch" ]; then
  fixture="${GH_FAKE_PR_DIR:-/nonexistent}/$(printf '%s' "$branch" | tr '/' '_')"
  if [ ! -f "$fixture" ]; then
    echo "no pull requests found for branch \"$branch\"" >&2
    exit 1
  fi
  read -r state num sha < "$fixture"
  case "$state" in
    ERROR) echo "gh: unexpected API error (rate limited)" >&2; exit 1 ;;
    *) printf '{"number":%s,"state":"%s","headRefOid":"%s"}\n' "${num:-0}" "$state" "${sha:-}" ;;
  esac
  exit 0
fi
echo "fake gh: unsupported invocation: $*" >&2
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FAKE_LOG="$TMP/gh.log"
export GH_FAKE_PR_DIR="$TMP/prstate"
mkdir -p "$GH_FAKE_PR_DIR"
export GH_TOKEN=dummy-ambient-token   # satisfies need_ambient_gh without a real `gh auth status` call

git config --global user.email test@example.com >/dev/null 2>&1 || true
git config --global user.name "Test" >/dev/null 2>&1 || true
git config --global init.defaultBranch main >/dev/null 2>&1 || true

# setup_repo <name> -> echoes the MAIN CHECKOUT path (origin = a local bare repo, one commit on main).
setup_repo(){
  local name=$1
  local bare="$TMP/${name}-bare.git" co="$TMP/${name}-co"
  git init -q --bare "$bare"
  git init -q "$co"
  git -C "$co" checkout -q -b main
  echo "hello" > "$co/README.md"
  git -C "$co" add README.md
  git -C "$co" commit -q -m init
  git -C "$co" remote add origin "$bare"
  git -C "$co" push -q origin main
  echo "$co"
}

# mk_worktree <main_co> <root> <issue> <slug> -> echoes the worktree path (branch change/<issue>-<slug>)
mk_worktree(){
  local main_co=$1 root=$2 issue=$3 slug=$4 wt
  wt="$root/wf-${issue}-${slug}"
  git -C "$main_co" worktree add -q "$wt" -b "change/${issue}-${slug}" main >/dev/null
  echo "$wt"
}

commit_in(){ local wt=$1 msg=$2; echo "$RANDOM" >> "$wt/f.txt"; git -C "$wt" add -A; git -C "$wt" commit -q -m "$msg"; }

REPO_A=$(setup_repo repoA)
REPO_B=$(setup_repo repoB)
ROOT="$TMP/root"; mkdir -p "$ROOT"

echo "=== fixtures ==="

# 1. OPEN PR -> keep
WT_OPEN=$(mk_worktree "$REPO_A" "$ROOT" 1 open)
commit_in "$WT_OPEN" work
printf 'OPEN 101\n' > "$GH_FAKE_PR_DIR/change_1-open"

# 2. MERGED PR, local HEAD == headRefOid -> sweep
WT_MERGED=$(mk_worktree "$REPO_A" "$ROOT" 2 merged-exact)
commit_in "$WT_MERGED" work
SHA2=$(git -C "$WT_MERGED" rev-parse HEAD)
printf 'MERGED 102 %s\n' "$SHA2" > "$GH_FAKE_PR_DIR/change_2-merged-exact"

# 3. CLOSED PR, local HEAD == headRefOid -> sweep
WT_CLOSED=$(mk_worktree "$REPO_A" "$ROOT" 3 closed-exact)
commit_in "$WT_CLOSED" work
SHA3=$(git -C "$WT_CLOSED" rev-parse HEAD)
printf 'CLOSED 103 %s\n' "$SHA3" > "$GH_FAKE_PR_DIR/change_3-closed-exact"

# 4. no PR, branch fully merged into main (no local commits beyond main's tip) -> sweep
WT_NOPR_ANCESTOR=$(mk_worktree "$REPO_A" "$ROOT" 4 nopr-ancestor)
# (no fixture file -> genuine "no pull requests found"; no extra commit -> trivially an ancestor of main)

# 5. no PR, branch has unmerged/unpushed commits -> keep
WT_NOPR_UNMERGED=$(mk_worktree "$REPO_A" "$ROOT" 5 nopr-unmerged)
commit_in "$WT_NOPR_UNMERGED" work
# (no fixture file -> genuine "no pull requests found"; but has a commit main doesn't have)

# 6. MERGED PR but the worktree is DIRTY -> keep regardless of PR state
WT_DIRTY=$(mk_worktree "$REPO_A" "$ROOT" 6 dirty)
commit_in "$WT_DIRTY" work
SHA6=$(git -C "$WT_DIRTY" rev-parse HEAD)
printf 'MERGED 106 %s\n' "$SHA6" > "$GH_FAKE_PR_DIR/change_6-dirty"
echo "uncommitted" >> "$WT_DIRTY/f.txt"   # now dirty

# 7. MERGED PR but local HEAD has diverged PAST headRefOid (F1 fix: unrepresented local commit) -> keep
WT_AHEAD=$(mk_worktree "$REPO_A" "$ROOT" 7 ahead-of-head)
commit_in "$WT_AHEAD" "reviewed commit"
SHA7_REVIEWED=$(git -C "$WT_AHEAD" rev-parse HEAD)
printf 'MERGED 107 %s\n' "$SHA7_REVIEWED" > "$GH_FAKE_PR_DIR/change_7-ahead-of-head"
commit_in "$WT_AHEAD" "unreviewed follow-up commit"   # local HEAD now past what the PR ever saw

# 8. PR lookup fails for a reason OTHER than "no pull requests found" -> keep (fail closed)
WT_ERROR=$(mk_worktree "$REPO_A" "$ROOT" 8 lookup-error)
commit_in "$WT_ERROR" work
printf 'ERROR\n' > "$GH_FAKE_PR_DIR/change_8-lookup-error"

# 9. unrecognized PR state -> keep (fail closed, defensive)
WT_BOGUS=$(mk_worktree "$REPO_A" "$ROOT" 9 bogus-state)
commit_in "$WT_BOGUS" work
printf 'BOGUS 109\n' > "$GH_FAKE_PR_DIR/change_9-bogus-state"

# 10. a worktree belonging to a DIFFERENT repo, in the SAME shared root, with an otherwise-eligible fixture
#     (would be swept if scoping were broken) -> must be left completely untouched
WT_OTHERREPO=$(mk_worktree "$REPO_B" "$ROOT" 10 otherrepo)
commit_in "$WT_OTHERREPO" work
SHA10=$(git -C "$WT_OTHERREPO" rev-parse HEAD)
printf 'MERGED 110 %s\n' "$SHA10" > "$GH_FAKE_PR_DIR/change_10-otherrepo"

# 11. a stray non-worktree directory matching wf-* (junk, no .git at all) -> skipped, not an error
mkdir -p "$ROOT/wf-999-junk"

echo "=== run: wf.sh gc \$REPO_A ==="
: > "$GH_FAKE_LOG"
out=$(WF_WORKTREE_ROOT="$ROOT" bash "$WF" gc "$REPO_A" 2>&1); rc=$?
echo "$out"
check "gc exits zero" "[ $rc -eq 0 ]"

check "OPEN PR: worktree kept"            "[ -d \"$WT_OPEN\" ]"
check "OPEN PR: branch kept"              "git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/1-open"

check "MERGED exact-head: worktree swept" "[ ! -d \"$WT_MERGED\" ]"
check "MERGED exact-head: branch deleted" "! git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/2-merged-exact"

check "CLOSED exact-head: worktree swept" "[ ! -d \"$WT_CLOSED\" ]"
check "CLOSED exact-head: branch deleted" "! git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/3-closed-exact"

check "no-PR + ancestor: worktree swept"  "[ ! -d \"$WT_NOPR_ANCESTOR\" ]"
check "no-PR + ancestor: branch deleted"  "! git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/4-nopr-ancestor"

check "no-PR + unmerged: worktree kept"   "[ -d \"$WT_NOPR_UNMERGED\" ]"
check "no-PR + unmerged: branch kept"     "git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/5-nopr-unmerged"

check "dirty + MERGED: worktree kept"     "[ -d \"$WT_DIRTY\" ]"
check "dirty + MERGED: branch kept"       "git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/6-dirty"

check "ahead-of-headRefOid: worktree kept (F1)" "[ -d \"$WT_AHEAD\" ]"
check "ahead-of-headRefOid: branch kept (F1)"   "git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/7-ahead-of-head"
check "ahead-of-headRefOid: the unreviewed commit is still there" \
  "[ \"\$(git -C \"$WT_AHEAD\" rev-parse HEAD)\" != \"$SHA7_REVIEWED\" ]"

check "PR lookup error (not no-PR): worktree kept" "[ -d \"$WT_ERROR\" ]"
check "PR lookup error (not no-PR): branch kept"   "git -C \"$REPO_A\" show-ref --verify -q refs/heads/change/8-lookup-error"

check "unrecognized PR state: worktree kept" "[ -d \"$WT_BOGUS\" ]"

check "other repo's worktree: untouched (worktree)" "[ -d \"$WT_OTHERREPO\" ]"
check "other repo's worktree: untouched (branch)"   "git -C \"$REPO_B\" show-ref --verify -q refs/heads/change/10-otherrepo"

check "stray non-worktree dir: left alone" "[ -d \"$ROOT/wf-999-junk\" ]"
check "stray non-worktree dir: noted, not fatal" "grep -q 'not a git worktree' <<<\"\$out\""

check "summary line reports 3 swept" "grep -Eq 'gc: swept 3, kept [0-9]+, skipped 1' <<<\"\$out\""

echo "=== run: wf.sh gc \$REPO_A again — idempotent no-op on what's left ==="
: > "$GH_FAKE_LOG"
out2=$(WF_WORKTREE_ROOT="$ROOT" bash "$WF" gc "$REPO_A" 2>&1); rc2=$?
echo "$out2"
check "second gc exits zero"        "[ $rc2 -eq 0 ]"
check "second gc sweeps nothing"    "grep -Eq 'gc: swept 0, ' <<<\"\$out2\""
check "second gc left OPEN alone"   "[ -d \"$WT_OPEN\" ]"

echo "=== run: wf.sh gc (no repo arg, default ORIGIN_REPO = cwd) ==="
WT_DEFAULT=$(mk_worktree "$REPO_A" "$ROOT" 20 default-arg)
commit_in "$WT_DEFAULT" work   # unmerged, no PR fixture -> must be KEPT; proves the default-arg run is real
: > "$GH_FAKE_LOG"
out3=$(cd "$REPO_A" && WF_WORKTREE_ROOT="$ROOT" bash "$WF" gc 2>&1); rc3=$?
echo "$out3"
check "default-arg gc exits zero"          "[ $rc3 -eq 0 ]"
check "default-arg gc: no-PR unmerged kept" "[ -d \"$WT_DEFAULT\" ]"

[ "$fail" = 0 ] && echo "worktree_gc_smoke: PASS" || { echo "worktree_gc_smoke: FAIL" >&2; exit 1; }
