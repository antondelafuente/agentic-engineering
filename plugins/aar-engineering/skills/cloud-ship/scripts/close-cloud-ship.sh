#!/usr/bin/env bash
# close-cloud-ship.sh — the BOX-SIDE close for a cloud-ship run (#18 / automated-researcher #308).
#
# A cloud-ship run authors + cross-family-reviews a change on a Claude Code cloud VM, then STOPS at a pushed
# branch + a machine-readable `CLOUD-SHIP RUN` record comment on the issue (the cloud VM has no engineer keys,
# so it can neither open the bot PR nor cast the opposite-family native approval). This script runs on the BOX
# (which holds the engineer-App keys) and closes the loop: it GATES on the record + the live branch head, then
# — only on a clean gate — opens the PR as the authoring-family bot, approves as the OPPOSITE-family bot, and
# squash-merges pinned to the exact reviewed sha.
#
# Two subcommands so the gate is testable offline (see close_cloud_ship_smoke.sh):
#
#   close-cloud-ship.sh gate <record-file> <remote-head> <branch>
#       Pure, offline, FAIL-CLOSED gate. Refuses unless the record is a well-formed CLOUD-SHIP RUN block whose
#       Verdict is exactly PASS, whose Reviewed-Head is a 40-hex sha, whose Branch equals <branch>, AND whose
#       Reviewed-Head equals <remote-head> (the live branch head). Prints:
#         "CLOUD-SHIP-GATE: PASS"           (exit 0)
#         "CLOUD-SHIP-GATE: REFUSE <reason>"(exit 2)
#       - head-equality = the anti-post-review-push guard (the box merges only the reviewed sha).
#       - branch-equality = the anti-record-replay guard (a PASS record can't authorize a different branch).
#
#   close-cloud-ship.sh close -R <owner/repo> -i <issue> -b <branch> [-a <claude|codex>]
#       Full close. First refuses if the issue is already CLOSED (a duplicate-merge guard — #22's incident was
#       an on-box PR closing the issue while a completed cloud-ship run for it still had a live PASS record).
#       Then reads the latest "CLOUD-SHIP RUN" issue comment (ambient READ-ONLY gh), reads the live branch head
#       via `git ls-remote`, runs the gate, replicates ship-change's ready-only close-gate, then
#       opens/approves/merges with the engineer bots. -a = authoring family (default claude, the cloud author).
#
# Engineer identity: consumes the SAME seams wf.sh uses — WF_ENGINEER_TOKEN_CMD_CLAUDE / _CODEX (with legacy
# WF_REVIEWER_TOKEN_CMD as the codex alias). It does NOT source wf.sh (wf.sh is a top-level case dispatch, not
# a sourceable library), so the minimal mint mechanic is re-expressed here; the CONFIG is reused, not coined.
set -uo pipefail

# ---- cleanup ----------------------------------------------------------------------------------------------
CLOSE_TMPFILES=()
cleanup() { local f; for f in "${CLOSE_TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap cleanup EXIT

# ---- output helpers ---------------------------------------------------------------------------------------
refuse() { echo "CLOUD-SHIP-GATE: REFUSE $*"; exit 2; }   # gate verdict (fail-closed)
die()    { echo "close-cloud-ship: $*" >&2; exit 1; }     # close-path error (fail-closed)
note()   { echo "  $*" >&2; }

# ---- the pure gate (offline, smoke-tested) --------------------------------------------------------------
# gate_record <record-file> <remote-head> <branch>  -> prints PASS/REFUSE, exits 0/2.
gate_record() {
  local rec=$1 remote_head=$2 want_branch=$3
  [ -n "$rec" ] && [ -f "$rec" ] && [ -r "$rec" ] || refuse "record file missing or unreadable: ${rec:-<none>}"
  [ -n "$remote_head" ] || refuse "no remote head supplied (branch has no head on origin?)"
  [ -n "$want_branch" ] || refuse "no branch supplied to bind the record against"

  # The record MUST be a genuine CLOUD-SHIP RUN block: its first non-blank line starts with the marker.
  local first
  first=$(grep -vE '^[[:space:]]*$' "$rec" | head -1 || true)
  case "$first" in
    "CLOUD-SHIP RUN"*) : ;;
    *) refuse "record does not begin with a 'CLOUD-SHIP RUN' line (got: '${first:0:40}')" ;;
  esac

  # Extract the three header fields from the FIRST matching line each. Strict, anchored, no fallthrough.
  local rec_branch rec_head rec_verdict
  rec_branch=$(sed -nE 's/^Branch:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$rec" | head -1)
  rec_head=$(sed -nE 's/^Reviewed-Head:[[:space:]]*([0-9a-fA-F]+)[[:space:]]*$/\1/p' "$rec" | head -1)
  rec_verdict=$(sed -nE 's/^Verdict:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$rec" | head -1)

  [ -n "$rec_branch" ]  || refuse "record has no parseable 'Branch:' line"
  [ -n "$rec_head" ]    || refuse "record has no parseable 'Reviewed-Head:' line"
  [ -n "$rec_verdict" ] || refuse "record has no parseable 'Verdict:' line"

  # Verdict must be EXACTLY PASS (any other value, incl. FAIL/empty/garbled, refuses).
  [ "$rec_verdict" = PASS ] || refuse "record Verdict is '$rec_verdict', not PASS"

  # Reviewed-Head must be a full 40-hex object id — a short/symbolic ref would not pin the merge.
  [[ "$rec_head" =~ ^[0-9a-fA-F]{40}$ ]] || refuse "record Reviewed-Head '$rec_head' is not a 40-hex sha"

  # Branch binding: the record must name the branch we were asked to close (anti-replay).
  [ "$rec_branch" = "$want_branch" ] || refuse "record Branch '$rec_branch' != requested branch '$want_branch'"

  # Head equality: the live branch head must be the exact reviewed sha (anti-post-review-push). Case-insensitive
  # hex compare so a differently-cased sha still matches.
  local lc_head lc_remote
  lc_head=$(printf '%s' "$rec_head" | tr 'A-F' 'a-f')
  lc_remote=$(printf '%s' "$remote_head" | tr 'A-F' 'a-f')
  [ "$lc_head" = "$lc_remote" ] || refuse "branch head ($remote_head) != record Reviewed-Head ($rec_head) — a post-review push; re-review or re-post the record"

  echo "CLOUD-SHIP-GATE: PASS"
  exit 0
}

# ---- ready-only close-gate (mirror wf.sh's disposition set-equality; offline-testable) --------------------
# The disposition vocabulary + the set-equality rule are wf.sh's (DISPO_RE at wf.sh; AGENTS.md "exactly one
# disposition"). The DISPOSITION labels on the closing issue must be EXACTLY {ready} — a malformed issue that
# also carries `blocked`/`parked`/etc. FAILS CLOSED (a substring 'contains ready' check would fail open on it).
DISPO_RE='^(ready|needs-shaping|blocked|parked|other)$'
# dispo_gate_check — reads newline-separated label names on STDIN. Prints the close-gate verdict + returns 0/2.
dispo_gate_check() {
  local dset
  dset=$(grep -vE '^[[:space:]]*$' | grep -E "$DISPO_RE" | sort -u | paste -sd, -)
  if [ "$dset" = ready ]; then
    echo "CLOUD-SHIP-CLOSE-GATE: PASS"; return 0
  fi
  echo "CLOUD-SHIP-CLOSE-GATE: REFUSE disposition set is {${dset:-none}}, not exactly {ready} — triage the issue to a single 'ready' disposition first (WF_ALLOW_NONREADY_CLOSE=1 to override)"
  return 2
}

# ---- engineer-token seams (mirror wf.sh; no new config) --------------------------------------------------
family_suffix()   { case "$1" in claude) echo CLAUDE ;; codex) echo CODEX ;; *) die "unknown family '$1'" ;; esac; }
opposite_family() { case "$1" in claude) echo codex ;; codex) echo claude ;; *) die "unknown family '$1'" ;; esac; }

# engineer_token_cmd <family> — the seam command string (empty if unset). Same lookup + legacy alias as wf.sh.
engineer_token_cmd() {
  local fam=$1 suffix var cmd
  suffix=$(family_suffix "$fam"); var="WF_ENGINEER_TOKEN_CMD_$suffix"; cmd="${!var:-}"
  [ -z "$cmd" ] && [ "$fam" = codex ] && cmd="${WF_REVIEWER_TOKEN_CMD:-}"   # legacy codex alias
  printf '%s' "$cmd"
}

# engineer_token <family> — mint a fresh token; FAIL-CLOSED on a missing seam / failed mint / empty token.
engineer_token() {
  local fam=$1 suffix cmd t
  suffix=$(family_suffix "$fam"); cmd=$(engineer_token_cmd "$fam")
  [ -n "$cmd" ] || die "missing WF_ENGINEER_TOKEN_CMD_$suffix for the $fam engineer identity (failing closed)"
  t=$(eval "$cmd") || die "WF_ENGINEER_TOKEN_CMD_$suffix failed — can't mint the $fam engineer token (failing closed)"
  [ -n "$t" ] || die "WF_ENGINEER_TOKEN_CMD_$suffix produced an empty token (failing closed)"
  printf '%s' "$t"
}

# ---- the full close path ---------------------------------------------------------------------------------
do_close() {
  local REPO="" ISSUE="" BRANCH="" AUTHOR="claude"
  while [ $# -gt 0 ]; do
    case "$1" in
      -R) REPO=${2:?}; shift 2 ;;
      -i) ISSUE=${2:?}; shift 2 ;;
      -b) BRANCH=${2:?}; shift 2 ;;
      -a) AUTHOR=${2:?}; shift 2 ;;
      *) die "unknown close arg '$1' (usage: close -R <owner/repo> -i <issue> -b <branch> [-a claude|codex])" ;;
    esac
  done
  [ -n "$REPO" ]   || die "close needs -R <owner/repo>"
  [ -n "$ISSUE" ]  || die "close needs -i <issue>"
  [ -n "$BRANCH" ] || die "close needs -b <branch>"
  [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$ISSUE'"
  case "$AUTHOR" in claude|codex) : ;; *) die "author must be claude|codex, got '$AUTHOR'" ;; esac
  command -v gh  >/dev/null 2>&1 || die "gh not on PATH"
  command -v git >/dev/null 2>&1 || die "git not on PATH"
  local REVIEWER; REVIEWER=$(opposite_family "$AUTHOR")

  # 0. Duplicate-merge guard (#22 hardening round, code-review Finding 1): refuse if the issue this record
  #    would close is already CLOSED. The #22 incident was exactly this — an on-box PR merged (and closed the
  #    issue) while a completed cloud-ship run for the SAME issue still had a live PASS record; nothing at
  #    close time checked the issue's own state before opening/approving/merging a now-redundant PR.
  local issue_state
  issue_state=$(gh issue view "$ISSUE" -R "$REPO" --json state --jq .state 2>/dev/null) \
    || die "could not read state of ${REPO}#${ISSUE} (ambient gh read failed; failing closed)"
  [ "$issue_state" = OPEN ] || die "issue ${REPO}#${ISSUE} is already ${issue_state:-<unknown>} — refusing to close a duplicate cloud-ship run (the issue was likely already resolved by another PR)"

  # 1. Read the LATEST "CLOUD-SHIP RUN" issue comment (ambient READ-ONLY gh — inspection only).
  note "reading the latest CLOUD-SHIP RUN record on ${REPO}#${ISSUE}…"
  local record
  record=$(gh issue view "$ISSUE" -R "$REPO" --json comments \
             --jq '[.comments[] | select(.body | startswith("CLOUD-SHIP RUN"))] | last | .body' 2>/dev/null) \
    || die "could not read comments on ${REPO}#${ISSUE} (ambient gh read failed)"
  [ -n "$record" ] && [ "$record" != null ] || die "no 'CLOUD-SHIP RUN' record comment found on ${REPO}#${ISSUE} — the cloud leg has not posted its completion signal yet"
  local recfile; recfile=$(mktemp) || die "mktemp failed"
  CLOSE_TMPFILES+=("$recfile")   # cleaned by the EXIT trap
  printf '%s\n' "$record" > "$recfile"

  # 2. Read the LIVE branch head (exact head ref only, so a tag with the same tail can't match).
  local remote_head
  remote_head=$(git ls-remote --heads "https://github.com/${REPO}.git" "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$remote_head" ] || die "branch '$BRANCH' has no head on ${REPO} — nothing to close"

  # 3. THE GATE (fail-closed). Run it in a subshell so its exit(2) doesn't kill this function; branch on rc.
  local gate_out gate_rc
  gate_out=$( gate_record "$recfile" "$remote_head" "$BRANCH" ); gate_rc=$?
  echo "$gate_out"
  [ "$gate_rc" -eq 0 ] || die "record gate refused — NOT closing (see the REFUSE reason above)"
  local reviewed_head
  reviewed_head=$(sed -nE 's/^Reviewed-Head:[[:space:]]*([0-9a-fA-F]+)[[:space:]]*$/\1/p' "$recfile" | head -1)

  # 4. Replicate ship-change's ready-only close-gate (disposition SET == exactly {ready}), BEFORE any
  #    PR/approve. `Closes #<issue>` is same-repo by construction, so no cross-repo closing ref is possible.
  if [ "${WF_ALLOW_NONREADY_CLOSE:-}" = 1 ]; then
    note "WARN: close-gate OVERRIDDEN (WF_ALLOW_NONREADY_CLOSE=1) — not checking issue disposition"
  else
    local labels_raw dg_out dg_rc
    labels_raw=$(gh issue view "$ISSUE" -R "$REPO" --json labels --jq '.labels[].name' 2>/dev/null) \
      || die "could not read labels on ${REPO}#${ISSUE} to enforce the close-gate (failing closed; WF_ALLOW_NONREADY_CLOSE=1 to override)"
    dg_out=$(printf '%s\n' "$labels_raw" | dispo_gate_check); dg_rc=$?
    [ "$dg_rc" -eq 0 ] || die "${dg_out#CLOUD-SHIP-CLOSE-GATE: REFUSE } (on ${REPO}#${ISSUE})"
    note "close-gate ok: ${REPO}#${ISSUE} disposition set == {ready}"
  fi

  # 5. Mint the AUTHORING bot token → open the PR (title = branch head commit subject; body links record + Closes).
  local atok; atok=$(engineer_token "$AUTHOR")
  local subject
  subject=$(GH_TOKEN="$atok" gh api "repos/${REPO}/commits/${reviewed_head}" --jq '.commit.message' 2>/dev/null | head -1)
  [ -n "$subject" ] || subject="cloud-ship: ${BRANCH}"
  local body
  body=$(printf 'Cloud-ship run for #%s — authored + cross-family reviewed on a Claude Code cloud VM; closed by the box.\n\nReviewed-Head: `%s`\n\nCloses #%s\n\nThe full CLOUD-SHIP RUN review record (below) is copied from the issue.' \
          "$ISSUE" "$reviewed_head" "$ISSUE")
  note "opening PR as the $AUTHOR engineer bot…"
  local prurl
  prurl=$(GH_TOKEN="$atok" gh pr create -R "$REPO" --base main --head "$BRANCH" --title "$subject" --body "$body") \
    || die "gh pr create failed (as the $AUTHOR bot)"
  local pr; pr=$(basename "$prurl")
  note "opened PR #$pr: $prurl"

  # 6. Copy the record verbatim onto the PR (durable review trail on the PR, as ship-change does).
  printf '%s\n' "$record" | GH_TOKEN="$atok" gh pr comment "$pr" -R "$REPO" --body-file - >/dev/null \
    || note "WARN: could not copy the record comment onto PR #$pr (cosmetic — proceeding)"

  # 7. Mint the OPPOSITE-family bot token → native APPROVE (the author bot cannot self-approve).
  local rtok; rtok=$(engineer_token "$REVIEWER")
  note "posting cross-family native APPROVE as the $REVIEWER engineer bot…"
  GH_TOKEN="$rtok" gh pr review "$pr" -R "$REPO" --approve \
      --body "Cross-family approval by the $REVIEWER engineer bot on the box, on the strength of the CLOUD-SHIP RUN record (Verdict: PASS @ ${reviewed_head:0:8})." >/dev/null \
    || die "could not post the native APPROVE as the $REVIEWER bot (failing closed — GitHub forbids self-approval, so author must != reviewer)"

  # 8. Merge PINNED to the reviewed sha (--match-head-commit aborts if the head moved since the gate — TOCTOU).
  note "squash-merging PR #$pr pinned to reviewed head $reviewed_head…"
  GH_TOKEN="$atok" gh pr merge "$pr" -R "$REPO" --squash --delete-branch --match-head-commit "$reviewed_head" \
    || die "merge failed — the branch head may have moved off the reviewed sha since the gate (a post-review push). Re-review + re-post the record, then re-run close."
  echo "CLOSED: PR #$pr merged (cloud-ship: $AUTHOR-authored, $REVIEWER-approved, reviewed head $reviewed_head)."
}

# ---- dispatch --------------------------------------------------------------------------------------------
CMD=${1:-}; shift || true
case "$CMD" in
  gate)  gate_record "${1:-}" "${2:-}" "${3:-}" ;;
  dispo-gate) printf '%s\n' "$@" | dispo_gate_check; exit $? ;;   # offline: the ready-only close-gate over a label set
  close) do_close "$@" ;;
  *) echo "usage: close-cloud-ship.sh gate <record-file> <remote-head> <branch>" >&2
     echo "       close-cloud-ship.sh dispo-gate <label>...   (ready-only close-gate over a label set)" >&2
     echo "       close-cloud-ship.sh close -R <owner/repo> -i <issue> -b <branch> [-a claude|codex]" >&2
     exit 1 ;;
esac
