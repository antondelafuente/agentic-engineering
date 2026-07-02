#!/usr/bin/env bash
# dispatch-cloud-ship.sh — the BOX-SIDE dispatch that launches a cloud-ship run (#18 / automated-researcher
# #308). It fills the brief template for a specific issue/repo/branch, runs the GitHub App preflight, and
# launches `claude --remote` with the correct TTY mechanics. The cloud session then authors + cross-family
# reviews the change and stops at a pushed branch + a CLOUD-SHIP RUN record; the box later runs
# close-cloud-ship.sh to gate + PR/approve/merge.
#
# Usage:
#   dispatch-cloud-ship.sh -R <owner/repo> -i <issue> -b <branch> -s <spec-file|-> [-C <clone-dir>] [--dry-run]
#     -R  target owner/repo               -i  issue number            -b  the branch the cloud VM will push
#     -s  the change spec (file, or - for stdin) — substituted verbatim into the brief
#     -C  a clean, repo-associated clone to launch from (default: cwd)
#     --dry-run  fill + print the brief and the launch command; do NOT launch
#
# TTY mechanics (load-bearing): `claude --remote` detects an interactive TTY to attach the session. A pipe
# (`... | tee`) makes stdout a non-TTY and the launch silently degrades — so this launcher execs
# `claude --remote "$(cat <brief>)"` with NO redirection. Capture the brief FILE if you want a copy; never
# capture the launch.
set -uo pipefail

die()  { echo "dispatch-cloud-ship: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

HERE=$(cd "$(dirname "$0")" && pwd)
TMPL="$HERE/cloud-ship-brief.tmpl"

REPO="" ISSUE="" BRANCH="" SPEC_SRC="" CLONE_DIR="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -R) REPO=${2:?}; shift 2 ;;
    -i) ISSUE=${2:?}; shift 2 ;;
    -b) BRANCH=${2:?}; shift 2 ;;
    -s) SPEC_SRC=${2:?}; shift 2 ;;
    -C) CLONE_DIR=${2:?}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg '$1'" ;;
  esac
done
[ -n "$REPO" ]     || die "need -R <owner/repo>"
[ -n "$ISSUE" ]    || die "need -i <issue>"
[ -n "$BRANCH" ]   || die "need -b <branch>"
[ -n "$SPEC_SRC" ] || die "need -s <spec-file|->"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$ISSUE'"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repo must look like owner/name, got '$REPO'"
[ -f "$TMPL" ] || die "brief template missing at $TMPL"

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
  echo "DRY-RUN — would launch from $LAUNCH_DIR:"
  echo "  ( cd $LAUNCH_DIR && claude --remote \"\$(cat $BRIEF)\" )   # NO pipe — a | tee breaks TTY detection"
  echo "----- filled brief ($BRIEF) -----"
  cat "$BRIEF"
  exit 0
fi

note "launching cloud-ship for ${REPO}#${ISSUE} on branch ${BRANCH} (branch pushed by the cloud VM; the box closes with close-cloud-ship.sh)…"
# Launch directly — NO pipe/redirection (preserves TTY detection so `claude --remote` attaches the session).
cd "$LAUNCH_DIR" || die "could not cd into launch clone $LAUNCH_DIR"
exec claude --remote "$(cat "$BRIEF")"
