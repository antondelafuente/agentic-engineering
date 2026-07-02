# Proposal: Allow attached short values in `wf.sh issue` (#11)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh issue <family> create|comment ...` protects engineer-authored issue writes with a fail-closed
allowlist. It accepts the existing spaced short-flag value form (`-b body`) and the equals form (`-b=body`),
but rejects GitHub CLI's valid attached short-value shorthand such as `-bbody`, `-Rowner/repo`, and `-ttitle`.

That is safe, but it is an unnecessary usability over-rejection. The spaced form works, so this is not a
security hole or a blocked workflow; it is a compatibility gap in the authoring allowlist parser.

## Approach

Keep the existing hard boundary: `wf.sh issue` still allows only `create|comment` on the authoring path, and
only the non-interactive value flags already approved by the #91 model.

Inside the create/comment allowlist scan, add one case for attached short-value tokens. A single-dash token is
allowed only when its first character after `-` is one of the already-allowed short value flags
(`R`, `t`, `b`, `F`, `l`, `a`, `m`, `p`) and at least one value character follows it. The attached value is
self-contained, so the parser must not set `want_val` or consume the next argv token.

Also update the sibling helper that interprets `-R` for the ambient-identity accountability trail.
`repo_arg_from_gh_args` must resolve `-Rowner/repo` to the same repo as `-R owner/repo` and `-R=owner/repo`;
otherwise a tokenless install using `WF_ALLOW_AMBIENT_IDENTITY=1` would execute the requested command but post
its override note to the fallback repo. The nearby `issue_number_from_gh_issue_args` helper already treats
attached short values as self-contained flags because it ignores unknown `-` tokens and does not consume the
next positional issue number; the smoke pins that behavior for `comment -bbody 8 ...`.

Add a dedicated fake-`gh` smoke for the authoring path. It should prove that `-Rexample/repo -ttitle -bbody`
passes through on `create`, `-bbody` passes through on `comment`, attached `-Rexample/repo` is used for the
ambient override note, an attached value before a positional issue number does not consume that issue number,
the existing spaced and equals forms still pass, and unallowed shorthand/bundles such as `-w`, `-we`, and
`-wb` still fail closed. Wire the smoke into `.aar-ci/checks.sh` when `wf.sh` changes, next to the existing
maintainer-verb smoke.

## Alternatives considered

- Require the spaced form forever. This keeps the parser smaller, but it makes the protected wrapper reject
  valid `gh` syntax for no meaningful safety gain.
- Broaden all `wf.sh issue` verb parsers to accept attached values. The maintainer verbs have their own fixed
  argument shapes and do not need this issue's compatibility change; widening them here would add blast radius
  without evidence.
- Normalize argv before validation. The current parser only validates before handing the original argv to
  `gh`; recognizing attached-value tokens in place is smaller and avoids changing command behavior.
- Factor all issue-flag knowledge into one shared parser helper. The flag lists are duplicated today across
  the authoring allowlist and a few helper parsers; this change keeps the compatibility fix small, while the
  new smoke covers the dependent helper that matters for `-R`.

## Blast radius

This touches only the SWE pipeline:

- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`
- one self-contained smoke script under the same skill
- `.aar-ci/checks.sh` wiring for that smoke
- the `aar-engineering` plugin manifest version

Within `wf.sh`, the touched behavior is the create/comment authoring allowlist plus the `repo_arg_from_gh_args`
helper used by the ambient override note. The issue-command flag knowledge is duplicated in a few local
parsers; this PR intentionally does not widen the maintainer verbs.

It does not change product runtime behavior, branch protection, engineer-token minting, cloud-ship, or the
maintainer verbs.

## Rollout + rollback

Rollout is the normal `ship-change` merge path. The deterministic checks run `bash -n`, the new
issue-authoring smoke, the existing issue-verb/identity/locate-audit/fdispo/guard smokes, and the fake-HOME
plugin smoke because this is a plugin change.

Rollback is a normal revert of the squash commit. Reverting restores the prior fail-closed behavior: attached
short values are rejected again, while spaced values continue to work.
