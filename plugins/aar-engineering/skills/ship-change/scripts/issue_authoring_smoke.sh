#!/bin/bash
# issue_authoring_smoke.sh - unit-style smoke for the engineer AUTHORING allowlist (#11).
# Self-contained: fake gh, no network and no real tokens. Focus: create/comment accept gh's attached
# short-value shorthand for already-allowed value flags, while unknown flags still fail closed.
set -uo pipefail
unset BASH_ENV ENV
unset GH_TOKEN
unset WF_ENGINEER_TOKEN_CMD_CLAUDE WF_ENGINEER_TOKEN_CMD_CODEX WF_REVIEWER_TOKEN_CMD
unset WF_ENGINEER_GIT_AUTHOR_CLAUDE WF_ENGINEER_GIT_AUTHOR_CODEX
unset WF_ALLOW_AMBIENT_IDENTITY AUDIT_VERIFIER_CMD

WF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wf.sh
[ -f "$WF" ] || { echo "FAIL: wf.sh not found next to smoke" >&2; exit 1; }

fail=0
check(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1" >&2; fail=1; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/issue-authoring-smoke.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin"

cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
set -u
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-<none>}" "$*" >> "${GH_FAKE_LOG:-/dev/null}"
sub=${1:-}; shift || true
[ "$sub" = issue ] && { sub=${1:-}; shift || true; }
case "$sub" in
  create)
    echo "https://github.com/example/repo/issues/123"
    exit 0 ;;
  comment)
    want=0
    for a in "$@"; do
      if [ "$want" = 1 ]; then
        if [ "$a" = "-" ]; then cat >/dev/null; fi
        want=0
        continue
      fi
      case "$a" in -F|--body-file) want=1 ;; esac
    done
    exit 0 ;;
  *) echo "fake gh: unsupported issue $sub $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FAKE_LOG="$TMP/gh.log"

ENGENV=(WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token')

echo "=== create: attached short values are accepted and passed through ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue codex create -Rexample/repo -ttitle -bbody 2>&1); rc=$?
echo "$out"
check "attached create exits zero" "[ $rc -eq 0 ]"
check "attached create used the codex engineer token" "grep -q 'TOKEN=codex-token ARGS=issue create -Rexample/repo -ttitle -bbody' \"\$GH_FAKE_LOG\""

echo "=== comment: attached -b does not consume the next positional issue number ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue codex comment -bbody 8 -Rexample/repo 2>&1); rc=$?
echo "$out"
check "attached comment exits zero" "[ $rc -eq 0 ]"
check "comment passed attached -b and the following positional issue number unchanged" "grep -q 'TOKEN=codex-token ARGS=issue comment -bbody 8 -Rexample/repo' \"\$GH_FAKE_LOG\""

echo "=== ambient override trail: attached -R is recognized as the target repo ==="
: > "$GH_FAKE_LOG"
out=$(GH_TOKEN=ambient-token WF_ALLOW_AMBIENT_IDENTITY=1 bash "$WF" issue codex create -Rexample/repo -ttitle -bbody 2>&1); rc=$?
echo "$out"
check "ambient attached create exits zero" "[ $rc -eq 0 ]"
check "ambient create override note used attached -R repo" "grep -q 'TOKEN=ambient-token ARGS=issue comment 123 -R example/repo --body-file -' \"\$GH_FAKE_LOG\""

echo "=== ambient override trail: attached -b before issue number still parses the issue number ==="
: > "$GH_FAKE_LOG"
out=$(GH_TOKEN=ambient-token WF_ALLOW_AMBIENT_IDENTITY=1 bash "$WF" issue codex comment -bbody 8 -Rexample/repo 2>&1); rc=$?
echo "$out"
check "ambient attached comment exits zero" "[ $rc -eq 0 ]"
check "ambient comment override note used parsed issue number and attached -R repo" "grep -q 'TOKEN=ambient-token ARGS=issue comment 8 -R example/repo --body-file -' \"\$GH_FAKE_LOG\""

echo "=== existing spaced and equals forms still pass ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue codex create -R example/repo -t title -b body 2>&1); rc=$?
echo "$out"
check "spaced create exits zero" "[ $rc -eq 0 ]"
check "spaced create passed through" "grep -q 'TOKEN=codex-token ARGS=issue create -R example/repo -t title -b body' \"\$GH_FAKE_LOG\""
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue codex create -R=example/repo -t=title -b=body 2>&1); rc=$?
echo "$out"
check "equals create exits zero" "[ $rc -eq 0 ]"
check "equals create passed through" "grep -q 'TOKEN=codex-token ARGS=issue create -R=example/repo -t=title -b=body' \"\$GH_FAKE_LOG\""

echo "=== unknown shorthand and bundles still fail closed ==="
for bad in -w -we -wb; do
  out=$(env "${ENGENV[@]}" bash "$WF" issue codex create -Rexample/repo -ttitle -bbody "$bad" 2>&1); rc=$?
  echo "$out"
  check "$bad exits nonzero" "[ $rc -ne 0 ]"
  check "$bad is rejected by the allowlist" "grep -qi 'not allowed' <<<\"\$out\""
done

[ "$fail" = 0 ] && echo "issue_authoring_smoke: PASS" || { echo "issue_authoring_smoke: FAIL" >&2; exit 1; }
