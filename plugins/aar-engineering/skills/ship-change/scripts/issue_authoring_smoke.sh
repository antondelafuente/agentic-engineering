#!/bin/bash
# issue_authoring_smoke.sh — unit-style smoke for the engineer AUTHORING allowlist (#11):
#   wf.sh issue <fam> create|comment …
# Self-contained: fake gh, no network and no real tokens. Focus: the flag ALLOWLIST parser (#91) now also
# permits gh's ATTACHED short-value shorthand (-btext == -b text, -Rowner/repo, -ttitle) for the already-
# allowed value flags (R t b F l a m p), while STILL rejecting disallowed boolean shorthands/bundles
# (-w, -we, -wb) and NEVER consuming the following argv token as an attached flag's value.
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

# Fake gh: logs every invocation (with the resolved GH_TOKEN + args) and accepts the create/comment surface
# the authoring path uses. It never validates gh flag semantics — the wf.sh allowlist is the unit under test;
# gh's own parsing is out of scope here.
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
set -u
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-<none>}" "$*" >> "${GH_FAKE_LOG:-/dev/null}"
sub=${1:-}; shift || true
[ "$sub" = issue ] && { sub=${1:-}; shift || true; }
case "$sub" in
  create)  echo "https://github.com/example/repo/issues/123"; exit 0 ;;
  comment) exit 0 ;;
  *) echo "fake gh: unsupported issue $sub $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FAKE_LOG="$TMP/gh.log"

# Engineer-token env so authoring runs on the ENGINEER path (ATOK non-empty → straight `gh issue …`).
ENGENV=(WF_ENGINEER_TOKEN_CMD_CLAUDE='printf claude-token'
        WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token')

echo "=== create: attached short values (-Rrepo -ttitle -bbody) are allowed and passed through ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo -tTitleHere -bBodyHere 2>&1); rc=$?
echo "$out"
check "create with attached shorts exits zero" "[ $rc -eq 0 ]"
check "create ran on the engineer token" "grep -q 'TOKEN=claude-token ARGS=issue create' \"\$GH_FAKE_LOG\""
check "create passed the attached -R through verbatim" "grep -q -- '-Rexample/repo' \"\$GH_FAKE_LOG\""
check "create passed the attached -t through verbatim" "grep -q -- '-tTitleHere' \"\$GH_FAKE_LOG\""
check "create passed the attached -b through verbatim" "grep -q -- '-bBodyHere' \"\$GH_FAKE_LOG\""

echo "=== create: spaced form is preserved, including a value that BEGINS with '-' ==="
: > "$GH_FAKE_LOG"
# `-b -x`: the value token `-x` begins with '-' and must be consumed as -b's value (want_val=1), NOT
# misread as a disallowed flag. This is the spaced-form / want_val preservation the attached case must not
# break — the sibling comment in wf.sh (`a body like -x`) calls out exactly this shape.
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -R example/repo -t "A Title" -b -x 2>&1); rc=$?
echo "$out"
check "create spaced form with a '-'-leading value exits zero" "[ $rc -eq 0 ]"
check "the '-'-leading spaced value -x was NOT misread as a flag" "grep -q -- '-b -x' \"\$GH_FAKE_LOG\""

echo "=== create: equals forms (-R=repo, --body=text) are preserved ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -R=example/repo --body=hello 2>&1); rc=$?
echo "$out"
check "create equals form exits zero" "[ $rc -eq 0 ]"
check "the equals values are passed through verbatim" "grep -q -- '-R=example/repo --body=hello' \"\$GH_FAKE_LOG\""

echo "=== create: an EMPTY '=' value (-b=, --body=) fails closed (#11 names -b= as a form NOT to admit) ==="
# #11's permit clause excludes the "'=' empty-value form such as -b=", and "preserve the existing equals
# forms" lists only the NON-empty -b=text/--body=text. So an empty '=' value is not admitted — fail closed,
# same as the maintainer-verb path (#164). (Non-empty equals forms are covered by the preserved-forms test
# above.)
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo -b= 2>&1); rc=$?
echo "$out"
check "create -b= exits nonzero" "[ $rc -ne 0 ]"
check "create -b= names the empty-value rule" "grep -qi 'empty' <<<\"\$out\""
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo --body= 2>&1); rc=$?
echo "$out"
check "create --body= exits nonzero" "[ $rc -ne 0 ]"

echo "=== comment: attached short value on comment is accepted and the positional issue number is forwarded ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue codex comment -Rexample/repo -bAckReply 123 2>&1); rc=$?
echo "$out"
check "comment with attached -b exits zero" "[ $rc -eq 0 ]"
check "comment ran on the engineer token" "grep -q 'TOKEN=codex-token ARGS=issue comment' \"\$GH_FAKE_LOG\""
check "comment passed the attached -b through verbatim" "grep -q -- '-bAckReply' \"\$GH_FAKE_LOG\""
check "the positional issue number 123 is forwarded to gh" "grep -qE 'issue comment .* 123( |\$)' \"\$GH_FAKE_LOG\""

# The allowlist scan is a VALIDATOR: it forwards argv to gh UNCHANGED, so a token the scan wrongly treated as
# an attached flag's "value" would still reach gh — checking that a positional number is present cannot, by
# itself, prove non-consumption. The OBSERVABLE guarantee that the attached form leaves want_val=0 is this: a
# DISALLOWED flag placed right AFTER an attached value must STILL be validated and rejected (had want_val been
# wrongly set to 1, `-w` would be skipped as -bBody's value and slip through). That is the load-bearing test.
echo "=== attached short value does NOT consume the next argv token: a following disallowed -w still fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo -bBody -w 2>&1); rc=$?
echo "$out"
check "attached -b followed by -w still fails closed" "[ $rc -ne 0 ]"
check "the -w rejection names the allowlist" "grep -qi 'not allowed' <<<\"\$out\""

echo "=== allowlist: disallowed boolean shorthand -w fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo -w 2>&1); rc=$?
echo "$out"
check "-w exits nonzero" "[ $rc -ne 0 ]"

echo "=== allowlist: disallowed bundle -we fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo -we 2>&1); rc=$?
echo "$out"
check "-we exits nonzero" "[ $rc -ne 0 ]"

echo "=== allowlist: disallowed bundle -wb (leading disallowed letter) fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo -wb 2>&1); rc=$?
echo "$out"
check "-wb exits nonzero" "[ $rc -ne 0 ]"
check "-wb rejection names the allowlist" "grep -qi 'not allowed' <<<\"\$out\""

echo "=== allowlist: unknown long flag --web still fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude create -Rexample/repo --web 2>&1); rc=$?
echo "$out"
check "--web exits nonzero" "[ $rc -ne 0 ]"

echo "=== allowlist: an unknown authoring subcommand still fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude edit 42 -bx 2>&1); rc=$?
echo "$out"
check "issue edit exits nonzero" "[ $rc -ne 0 ]"

# --- ambient-fallback path (WF_ALLOW_AMBIENT_IDENTITY=1, no engineer token) ---------------------------------
# When no engineer identity is configured but the ambient override is enabled, wf.sh runs `gh issue` on the
# ambient token AND posts an override-trail comment to the repo it resolves from the args via
# repo_arg_from_gh_args. That helper must recognise the newly-allowed ATTACHED -Rowner/repo form, else the
# real create/comment targets the requested repo while the trail comment lands on the fallback repo (#11).
# A tiny git repo gives gh_repo a concrete FALLBACK slug (fallback/repo) distinct from the attached -R target.
FALLBACK="$TMP/fallback"; mkdir -p "$FALLBACK"
git -C "$FALLBACK" init -q
git -C "$FALLBACK" remote add origin https://github.com/fallback/repo.git
AMBENV=(WF_ALLOW_AMBIENT_IDENTITY=1 GH_TOKEN=ambient-token "ORIGIN_REPO=$FALLBACK")

echo "=== ambient create: attached -Rowner/repo drives the override-trail comment to the SAME repo (not fallback) ==="
: > "$GH_FAKE_LOG"
out=$(env "${AMBENV[@]}" bash "$WF" issue claude create -Rexample/repo -tT -bB 2>&1); rc=$?
echo "$out"
check "ambient create exits zero" "[ $rc -eq 0 ]"
check "the real create ran on the ambient token" "grep -q 'TOKEN=ambient-token ARGS=issue create' \"\$GH_FAKE_LOG\""
check "override-trail comment posted to the attached -R repo (example/repo)" "grep -q -- 'issue comment 123 -R example/repo' \"\$GH_FAKE_LOG\""
check "override-trail comment did NOT post to the fallback repo" "! grep -q -- '-R fallback/repo' \"\$GH_FAKE_LOG\""

echo "=== ambient comment: attached -Rowner/repo drives the override-trail comment to the SAME repo (not fallback) ==="
: > "$GH_FAKE_LOG"
out=$(env "${AMBENV[@]}" bash "$WF" issue codex comment -Rexample/repo -bAck 55 2>&1); rc=$?
echo "$out"
check "ambient comment exits zero" "[ $rc -eq 0 ]"
check "override-trail comment posted to the attached -R repo (example/repo)" "grep -q -- 'issue comment 55 -R example/repo' \"\$GH_FAKE_LOG\""
check "override-trail comment did NOT post to the fallback repo" "! grep -q -- '-R fallback/repo' \"\$GH_FAKE_LOG\""

[ "$fail" = 0 ] && echo "issue_authoring_smoke: PASS" || { echo "issue_authoring_smoke: FAIL" >&2; exit 1; }
