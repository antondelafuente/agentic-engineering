# Proposal: Allow attached short-flag values in the `wf.sh issue` authoring allowlist (#11)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`plugins/aar-engineering/skills/ship-change/scripts/wf.sh issue <family> create|comment …` runs the
engineer-authoring path behind a flag ALLOWLIST (#91): each `-`-prefixed argv token is matched against a
fixed set of non-interactive value flags (`-R -t -b -F -l -a -m -p` and their `--long` forms), and anything
else fails closed. The allowlist matches on `${a%%=*}` (the token up to any `=`), so it recognises exactly two
value shapes: the spaced form (`-b text`, next token is the value) and the equals form (`-b=text`,
`--body=text`).

The GitHub CLI, like most getopt-style tools, ALSO accepts an ATTACHED short-value shorthand where the value
is glued to the flag letter: `-btext` (= `-b text`), `-Rowner/repo`, `-ttitle`. Because `${a%%=*}` of
`-btext` is the whole token `-btext` — which matches none of the allowlisted flags — the parser rejects it as
an unknown flag. This fails **closed** (the spaced form always works), so it is a LOW usability
over-rejection, not a security gap: an agent that reaches for the natural `-bBody` shorthand gets a hard
BLOCK instead of a filed issue/comment.

## Approach

Extend the single-dash arm of the create/comment allowlist scan with ONE additional `case` pattern that
recognises the attached short-value shorthand for the flags that already take a value:

```sh
-[RtbFlamp]?*) ;;   # gh attached short value: -btext, -Rowner/repo, -ttitle — self-contained, want_val stays 0
```

The pattern (matched against `${a%%=*}`, like the existing arm) permits a single-dash token when:

- its first letter is one of the allowed VALUE flags — `R t b F l a m p` (case-sensitive; `-r`, `-w`, etc.
  are unaffected);
- there is at least one character after that flag letter (`?*`); and
- it is not the `-b=` empty-equals form — that token's `${a%%=*}` is `-b`, so it is matched by the exact-flag
  arm above, never by the new pattern.

That third condition is straight from #11, which lists `-b=` as an "`=` empty-value form" the authoring
allowlist must not admit. Two things follow, and both are honored: (a) the NEW attached rule must not FIRE for
`-b=` — matching on `${a%%=*}` guarantees this, since `-b=` collapses to `-b`; and (b) `-b=` must not be
admitted at all. #11's "preserve the existing … equals forms" clause lists only the NON-empty `-b=text` /
`--body=text`, so preserving equals forms does not require accepting the empty `-b=`. We therefore reject an
empty `=`-value in the exact-flag arm (`[ -n "${a#*=}" ]`), fail-closed, the same posture the maintainer-verb
path (#164) already takes on empty `=`-forms. This is implementing #11's listed condition, not tightening
beyond it; non-empty equals values are untouched.

The remainder of an attached token is its SELF-CONTAINED value. Critically, `want_val` STAYS `0`, so the
attached form never consumes the following argv token — a subsequent positional (e.g. the issue number after
`comment <N>`) or, importantly, a subsequent DISALLOWED flag (`-btext -w`) is still validated and rejected.
This preserves the #91 fail-closed contract: the scan is a validator, and no disallowed token is skipped as a
phantom "value".

Spaced (`-b text`, including a value that itself begins with `-`, e.g. `-b -x`) and NON-empty equals
(`-b=text`, `--body=text`) forms are untouched; the empty `-b=` / `--body=` forms fail closed per #11.
Disallowed boolean shorthands and bundles (`-w`, `-we`, `-wb`) still fail closed because their leading letter
is not an allowed value flag.

### The ambient-fallback repo extractor must learn the attached form too

`repo_arg_from_gh_args` derives the repo slug from the `gh issue` args for the `WF_ALLOW_AMBIENT_IDENTITY=1`
override-trail comment. It already parsed `-R owner/repo` and `-R=owner/repo`; once the allowlist admits the
attached `-Rowner/repo`, this helper must parse it as well — otherwise the real create/comment targets the
requested repo while the override-trail comment posts to the FALLBACK repo. Add one `-R?*) repo=${a#-R}`
case, ordered AFTER `-R=*` so `-R=owner/repo` is not mis-stripped. (The other value flags need no change here:
their attached forms are simply ignored, and only `-R` selects the repo.)

### Scope: authoring path only

The change is confined to the `create|comment` authoring allowlist. The narrow MAINTAINER verbs
(`close|label|dispose`, `issue_maintainer_verb`) run their own distinct stateful scan and are deliberately
left unchanged: #11 is scoped to the authoring path, those verbs use structured `--long` flags in practice,
and broadening them is out of scope for this LOW usability fix.

## Testing

Add a focused, self-contained smoke —
`plugins/aar-engineering/skills/ship-change/scripts/issue_authoring_smoke.sh` — modeled on the sibling
`issue_verbs_smoke.sh`: a fake `gh` on `PATH`, fake engineer tokens, no network. It asserts:

- allowed attached values `-Rexample/repo`, `-tTitleHere`, `-bBodyHere` on `create` are accepted and passed
  through to `gh` verbatim, on the engineer token;
- an allowed attached value on `comment` (`-bAckReply`);
- the following-token non-consumption guarantee. The scan forwards argv to `gh` unchanged, so asserting a
  positional number still reaches `gh` cannot by itself prove non-consumption; the OBSERVABLE proof is that a
  DISALLOWED flag right after an attached value (`create … -bBody -w`) STILL BLOCKS — had `want_val` been
  wrongly set, `-w` would have been skipped as `-bBody`'s value. The comment case (`comment … -bAckReply 123`)
  additionally checks the attached value is accepted and the positional `123` is forwarded;
- the spaced form with a value that BEGINS with `-` (`-b -x`) and the non-empty equals forms (`-R=repo`,
  `--body=text`) remain accepted;
- an empty `=`-value (`-b=`, `--body=`) fails closed (#11's excluded form);
- disallowed `-w`, `-we`, `-wb`, `--web`, and an unknown authoring subcommand still fail closed;
- the ambient-fallback path (`WF_ALLOW_AMBIENT_IDENTITY=1`, no engineer token): with a distinct fallback repo
  configured, an attached `-Rexample/repo` on both `create` and `comment` drives the override-trail comment to
  `example/repo`, NOT the fallback repo — the regression guard for the `repo_arg_from_gh_args` change.

Wire it into `.aar-ci/checks.sh` as its own block that runs when `wf.sh` OR the smoke itself changes (the
`#166 F3` convention already used by the read-only-ambient smoke), fail-closed if the smoke is missing, so an
edit to the smoke alone is still exercised.

## Blast radius

SWE pipeline authoring surface only. The touched product files are:

- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh` — one added `case` pattern (the attached form) in
  the authoring allowlist scan, an empty-`=`-value guard in the exact-flag arm (#11's excluded `-b=` form),
  plus one `-R?*` case in `repo_arg_from_gh_args` so the ambient override-trail helper resolves the attached
  `-Rowner/repo` to the same repo the command targets.
- `plugins/aar-engineering/skills/ship-change/scripts/issue_authoring_smoke.sh` — new smoke.
- `.aar-ci/checks.sh` — new `wf.sh`-or-smoke-triggered block running the smoke.
- `plugins/aar-engineering/.claude-plugin/plugin.json` — version bump `0.4.1` → `0.4.2` (a non-manifest
  plugin file changed).
- `proposals/11-attached-short-values.md` — this doc.

The change ADMITS a previously-rejected valid gh shorthand for already-allowed value flags and additionally
fails closed on the empty `=`-value form #11 lists as excluded; non-empty equals values and the maintainer
verbs are untouched. Every direction is fail-safe: no disallowed flag gains admission.

## Alternatives considered

- **Do nothing (keep the spaced form as the only accepted shape).** Rejected: the issue is an explicit LOW
  regression to fix; the attached form is idiomatic gh and agents reach for it.
- **Broaden the maintainer verbs at the same time.** Rejected: out of scope for #11, and the change brief
  says not to broaden `close|label|dispose` unless a test proves they share the exact bug and it is still
  clearly safe. Left for a separate change if ever wanted.
- **Rebuild argv (strip/normalise flags) instead of validating in place.** Rejected: the allowlist is
  deliberately a pass-through validator (`gh issue "$@"`), which keeps gh as the single source of flag
  semantics. A one-pattern extension keeps that model; a normaliser would duplicate gh's parser.

## Rollout + rollback

Rollout is the normal `ship-change` path: design review, implementation, code review, `.aar-ci/checks.sh`,
behavior smoke, final review, merge. The local validation commands for this change:

```sh
bash -n plugins/aar-engineering/skills/ship-change/scripts/wf.sh
bash plugins/aar-engineering/skills/ship-change/scripts/issue_authoring_smoke.sh
bash .aar-ci/checks.sh proposals/11-attached-short-values.md .aar-ci/checks.sh \
  plugins/aar-engineering/.claude-plugin/plugin.json \
  plugins/aar-engineering/skills/ship-change/scripts/wf.sh \
  plugins/aar-engineering/skills/ship-change/scripts/issue_authoring_smoke.sh
```

The change-relevant checks are all green: JSON/`bash -n`/py-syntax, the disposition-reference + gate-label
sync, the version-bump gate, and the `issue_authoring` / `issue_verbs` / `locate_audit` / `identity` /
`gh_guard`-static smokes. Four sibling smokes are environment-gated and fail on the credential-less, root
cloud-ship VM identically to a clean `origin/main` checkout — they are not affected by this change and are
validated by the box's CI: the fake-HOME discovery smoke (needs `~/.claude/.credentials.json` to seed),
`fd_state` and `readonly_ambient` (their negative-permission assertions don't hold when the runner is root),
and the `gh_guard` behavior smoke (forced-credential push needs network). The authoritative merge-gate run is
the box's, on a runner with credentials and non-root isolation.

Rollback is a clean revert of the `wf.sh` `case` pattern + empty-`=` guard + `repo_arg_from_gh_args` case,
the smoke, the CI wiring, and the version bump.
