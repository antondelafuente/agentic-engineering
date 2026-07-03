#!/usr/bin/env bash
# dispatch-cloud-ship.sh — the BOX-SIDE dispatch that launches a cloud-ship run (#18 / automated-researcher
# #308). It fills the brief template for a specific issue/repo/branch, runs the dupe guard + the GitHub App
# preflight, and launches `claude --remote` with the correct TTY mechanics. The cloud session then authors +
# cross-family reviews the change and stops at a pushed branch + a CLOUD-SHIP RUN record; the box later runs
# close-cloud-ship.sh to gate + PR/approve/merge.
#
# Usage:
#   dispatch-cloud-ship.sh -R <owner/repo> -i <issue> -b <branch> -s <spec-file|-> \
#       [-C <clone-dir>] [-m <model-id>] [--force] [--dry-run]
#     -R  target owner/repo               -i  issue number            -b  the branch the cloud VM will push
#         (must look like cloud-ship/<issue>-<slug> — keeps the dupe guard's branch detection working for the
#         NEXT dispatch against this issue)
#     -s  the change spec (file, or - for stdin) — substituted verbatim into the brief
#     -C  a clean, repo-associated clone to launch from (default: cwd)
#     -m/--model <model-id>  pin the cloud VM session model (default: $CLOUD_SHIP_MODEL or claude-sonnet-5).
#         Deployment policy: gated execution legs run Sonnet-tier — quality is protected by the cross-family
#         review + the fail-closed close gate, not by which model authors. Verified 2026-07-02 by transcript
#         ground truth: `claude --remote --model <id> ...` does pin the VM session model.
#     --force  skip the dupe guard (see below) — logged, not silent
#     --dry-run  fill + print the brief and the launch command; do NOT launch
#
# Dupe guard (#22, fail-closed by default): before filling the brief, refuses to dispatch if the target issue
# already has an open PR referencing it, or an in-flight `change/<issue>-*` / `cloud-ship/<issue>-*` branch
# already exists on origin — the #22 incident was exactly this: an on-box PR and a full cloud-ship run both in
# flight for the same issue, and the completed-but-unclosed cloud run would have been merged as a duplicate.
# `--force` overrides (same escape-hatch shape as this plugin's other overrides — visible, not silent).
#
# TTY mechanics (load-bearing): `claude --remote` detects an interactive TTY to attach the session. A pipe
# (`... | tee`) makes stdout a non-TTY and the launch silently degrades — so this launcher execs
# `claude --remote --model <id> "$(cat <brief>)"` with NO redirection. Capture the brief FILE if you want a
# copy; never capture the launch.
set -uo pipefail

die()  { echo "dispatch-cloud-ship: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

HERE=$(cd "$(dirname "$0")" && pwd)
TMPL="$HERE/cloud-ship-brief.tmpl"

# ---- the pure dupe gate (offline-testable; see dispatch_cloud_ship_smoke.sh) -------------------------------
# dupe_gate <issue> <pr-hit-lines> <branch-hit-lines> -> prints DUPE-GATE: OK/REFUSE, returns 0/2.
# Inputs are already-fetched text (one hit per line, empty = no hits) so the decision has no network
# dependency — same shape as close-cloud-ship.sh's gate_record.
dupe_gate() {
  local issue=$1 prs=$2 branches=$3
  local pr_hits br_hits reason=""
  pr_hits=$(printf '%s\n' "$prs" | grep -vE '^[[:space:]]*$' || true)
  br_hits=$(printf '%s\n' "$branches" | grep -vE '^[[:space:]]*$' || true)
  if [ -n "$pr_hits" ]; then
    reason="open PR(s) referencing #${issue}: $(printf '%s' "$pr_hits" | tr '\n' ' ' | sed -E 's/ +$//')"
  fi
  if [ -n "$br_hits" ]; then
    local brmsg="in-flight branch(es) for #${issue} on origin: $(printf '%s' "$br_hits" | tr '\n' ' ' | sed -E 's/ +$//')"
    reason="${reason:+$reason; }$brmsg"
  fi
  if [ -n "$reason" ]; then
    echo "DUPE-GATE: REFUSE $reason"
    return 2
  fi
  echo "DUPE-GATE: OK — no open PR or in-flight branch found for #${issue}"
  return 0
}

# validate_branch <issue> <branch> -> prints BRANCH-CHECK: OK/REFUSE, returns 0/2. Pure string check (no I/O)
# enforcing the cloud-ship/<issue>-<slug> naming convention every existing invocation already uses — this is
# what keeps dupe_gate's branch detection able to find THIS dispatch's branch on a future re-check (#22
# code-review Finding 3).
validate_branch() {
  local issue=$1 branch=$2
  if [[ "$branch" =~ ^cloud-ship/${issue}- ]]; then
    echo "BRANCH-CHECK: OK"
    return 0
  fi
  echo "BRANCH-CHECK: REFUSE branch '$branch' must look like cloud-ship/${issue}-<slug>"
  return 2
}

# Bare `dupe-gate <issue> <prs> <branches>` / `validate-branch <issue> <branch>` subcommands run the pure
# gates offline (smoke entry points); the normal launch flow below calls the same functions with live inputs.
case "${1:-}" in
  dupe-gate) shift; dupe_gate "$@"; exit $? ;;
  validate-branch) shift; validate_branch "$@"; exit $? ;;
esac

REPO="" ISSUE="" BRANCH="" SPEC_SRC="" CLONE_DIR="" MODEL="${CLOUD_SHIP_MODEL:-claude-sonnet-5}" FORCE=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -R) REPO=${2:?}; shift 2 ;;
    -i) ISSUE=${2:?}; shift 2 ;;
    -b) BRANCH=${2:?}; shift 2 ;;
    -s) SPEC_SRC=${2:?}; shift 2 ;;
    -C) CLONE_DIR=${2:?}; shift 2 ;;
    -m|--model) MODEL=${2:?}; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$REPO" ]     || die "need -R <owner/repo>"
[ -n "$ISSUE" ]    || die "need -i <issue>"
[ -n "$BRANCH" ]   || die "need -b <branch>"
[ -n "$SPEC_SRC" ] || die "need -s <spec-file|->"
[ -n "$MODEL" ]    || die "need -m/--model <model-id> (or unset CLOUD_SHIP_MODEL to fall back to the default)"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$ISSUE'"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repo must look like owner/name, got '$REPO'"
bc_out=$(validate_branch "$ISSUE" "$BRANCH"); bc_rc=$?
[ "$bc_rc" -eq 0 ] || die "${bc_out#BRANCH-CHECK: REFUSE } — this is what the dupe guard's branch detection matches on the NEXT dispatch against this issue"
[ -f "$TMPL" ] || die "brief template missing at $TMPL"

# Dupe guard (#22) — refuse before doing any work if the issue already has an open PR or an in-flight branch.
if [ "$FORCE" = 1 ]; then
  note "WARN: dupe guard OVERRIDDEN (--force) — not checking for an existing PR/branch on #${ISSUE}"
else
  note "dupe guard: checking ${REPO} for an existing open PR or in-flight branch on #${ISSUE}…"
  prs=""
  if command -v gh >/dev/null 2>&1; then
    prs=$(gh pr list -R "$REPO" --state open --json number,url,title,body 2>/dev/null \
            | ISSUE="$ISSUE" python3 -c '
import json, os, re, sys
issue = os.environ["ISSUE"]
pat = re.compile(r"(?<!\d)#" + re.escape(issue) + r"(?!\d)")
for pr in json.load(sys.stdin):
    text = (pr.get("title") or "") + "\n" + (pr.get("body") or "")
    if pat.search(text):
        print(pr["url"])
' 2>/dev/null) || prs=""
  else
    note "WARN: gh not on PATH — skipping the open-PR check (branch check still runs)"
  fi
  branches=$(git ls-remote --heads "https://github.com/${REPO}.git" 2>/dev/null \
               | awk '{print $2}' | sed -E 's#^refs/heads/##' \
               | grep -E "^(change|cloud-ship)/${ISSUE}-" || true)
  dg_out=$(dupe_gate "$ISSUE" "$prs" "$branches"); dg_rc=$?
  note "$dg_out"
  [ "$dg_rc" -eq 0 ] || die "${dg_out#DUPE-GATE: REFUSE } — pass --force to override"
fi

# Read the spec (file or stdin).
if [ "$SPEC_SRC" = "-" ]; then SPEC=$(cat); else [ -f "$SPEC_SRC" ] || die "spec file not found: $SPEC_SRC"; SPEC=$(cat "$SPEC_SRC"); fi
[ -n "$SPEC" ] || die "the change spec is empty"

# Fill the brief with LITERAL substitution (the spec may contain any shell/regex metacharacters — never eval
# or envsubst it). python3's str.replace is literal; markers are @@REPO@@ / @@ISSUE@@ / @@BRANCH@@ / @@SPEC@@.
BRIEF=$(mktemp "${TMPDIR:-/tmp}/cloud-ship-brief.XXXXXX.txt") || die "mktemp failed"
REPO="$REPO" ISSUE="$ISSUE" BRANCH="$BRANCH" SPEC="$SPEC" TMPL="$TMPL" python3 - "$BRIEF" <<'PY' || die "brief templating failed"
import os, sys
MARKERS = ("@@REPO@@", "@@ISSUE@@", "@@BRANCH@@", "@@SPEC@@")
tmpl = open(os.environ["TMPL"]).read()
# Substitute SPEC LAST so a marker string appearing inside the spec text is never itself substituted.
for marker, key in (("@@REPO@@", "REPO"), ("@@ISSUE@@", "ISSUE"), ("@@BRANCH@@", "BRANCH")):
    tmpl = tmpl.replace(marker, os.environ[key])
tmpl = tmpl.replace("@@SPEC@@", os.environ["SPEC"])
# Only flag a genuinely UNFILLED template marker (not an @@ that arrived via the spec text).
missing = [m for m in MARKERS if m in tmpl]
if missing:
    sys.stderr.write("WARN: unfilled template marker(s) remain: %s\n" % " ".join(missing))
open(sys.argv[1], "w").write(tmpl)
PY
note "brief written: $BRIEF"

# GitHub App preflight — FAIL CLOSED. If the target repo isn't reachable / the launch clone isn't associated
# with it, the cloud session bundles its work and can NEVER push, wasting an unrecoverable run.
LAUNCH_DIR=${CLONE_DIR:-$PWD}
[ -d "$LAUNCH_DIR/.git" ] || die "launch dir '$LAUNCH_DIR' is not a git clone (need a clean, repo-associated clone; pass -C <clone-dir>)"
origin_url=$(git -C "$LAUNCH_DIR" remote get-url origin 2>/dev/null) || die "launch clone '$LAUNCH_DIR' has no origin remote"
case "$origin_url" in
  *"$REPO"*|*"${REPO%.git}.git"*) : ;;
  *) die "launch clone origin ('$origin_url') is not associated with $REPO — launch from a clone of the target repo so the cloud session's GitHub App association can push" ;;
esac
if [ -n "$(git -C "$LAUNCH_DIR" status --porcelain 2>/dev/null)" ]; then
  die "launch clone '$LAUNCH_DIR' is not clean — the cloud session must start from a clean repo-associated clone"
fi
if command -v gh >/dev/null 2>&1; then
  gh api "repos/${REPO}" --jq .full_name >/dev/null 2>&1 \
    || die "GitHub App preflight: cannot reach repos/${REPO} via gh — confirm the Claude Code GitHub App is installed on $REPO and the token can read it (else the cloud session cannot push)"
  note "preflight ok: $REPO reachable; launch clone associated + clean"
else
  note "WARN: gh not on PATH — skipping the repos/$REPO reachability probe (association still enforced via the launch clone origin)"
fi

if ! command -v claude >/dev/null 2>&1; then
  [ "$DRY" = 1 ] || die "claude CLI not on PATH — cannot launch the cloud session (use --dry-run to just render the brief)"
  note "WARN: claude CLI not on PATH (--dry-run, so continuing)"
fi

if [ "$DRY" = 1 ]; then
  echo "DRY-RUN — would launch from $LAUNCH_DIR (model: $MODEL):"
  echo "  ( cd $LAUNCH_DIR && claude --remote --model $MODEL \"\$(cat $BRIEF)\" )   # NO pipe — a | tee breaks TTY detection"
  echo "----- filled brief ($BRIEF) -----"
  cat "$BRIEF"
  exit 0
fi

note "launching cloud-ship for ${REPO}#${ISSUE} on branch ${BRANCH} (model: ${MODEL}; branch pushed by the cloud VM; the box closes with close-cloud-ship.sh)…"
# Launch directly — NO pipe/redirection (preserves TTY detection so `claude --remote` attaches the session).
cd "$LAUNCH_DIR" || die "could not cd into launch clone $LAUNCH_DIR"
exec claude --remote --model "$MODEL" "$(cat "$BRIEF")"
