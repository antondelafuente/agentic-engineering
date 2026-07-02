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

Add a dedicated fake-`gh` smoke for the authoring path. It should prove that `-Rexample/repo -ttitle -bbody`
passes through on `create`, `-bbody` passes through on `comment`, an attached value before a positional issue
number does not consume that issue number, and unallowed shorthand/bundles such as `-w`, `-we`, and `-wb`
still fail closed. Wire the smoke into `.aar-ci/checks.sh` when `wf.sh` changes, next to the existing
maintainer-verb smoke.

## Alternatives considered

- Require the spaced form forever. This keeps the parser smaller, but it makes the protected wrapper reject
  valid `gh` syntax for no meaningful safety gain.
- Broaden all `wf.sh issue` verb parsers to accept attached values. The maintainer verbs have their own fixed
  argument shapes and do not need this issue's compatibility change; widening them here would add blast radius
  without evidence.
- Normalize argv before validation. The current parser only validates before handing the original argv to
  `gh`; recognizing attached-value tokens in place is smaller and avoids changing command behavior.

## Blast radius

This touches only the SWE pipeline:

- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`
- one self-contained smoke script under the same skill
- `.aar-ci/checks.sh` wiring for that smoke
- the `aar-engineering` plugin manifest version

It does not change product runtime behavior, branch protection, engineer-token minting, cloud-ship, or the
maintainer verbs.

## Rollout + rollback

Rollout is the normal `ship-change` merge path. The deterministic checks run `bash -n`, the new
issue-authoring smoke, the existing issue-verb/identity/locate-audit/fdispo/guard smokes, and the fake-HOME
plugin smoke because this is a plugin change.

Rollback is a normal revert of the squash commit. Reverting restores the prior fail-closed behavior: attached
short values are rejected again, while spaced values continue to work.
