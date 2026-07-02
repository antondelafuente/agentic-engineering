# Proposal: ship-change SKILL.md cross-references cloud-ship as the preferred execution path when a cloud env is configured (#20)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

A route-test finding (2026-07-02): a fresh agent told to fix an issue followed `ship-change`'s pointer
straight into on-box `wf.sh`, even though the deployment's operating rules named `cloud-ship` as the default
execution path. The routing policy lived only in a boot/deployment doc the agent never consulted on the way to
the decision — so the product skill it *did* read (`ship-change`'s `SKILL.md`) silently routed it onto the
on-box path. The instance patched its own boot pointer, but the product carries the same gap: `ship-change`'s
`SKILL.md` describes the single-machine lifecycle and never mentions that a sibling two-machine skill
(`cloud-ship`) exists, let alone that it is the preferred path when a cloud environment is configured.

`cloud-ship` already exists (`proposals/18-cloud-ship.md`; `plugins/aar-engineering/skills/cloud-ship/`) and
`aar-engineering`'s `plugin.json` description already names it as the sibling skill. The one place an agent
lands when it decides *how* to ship a change — `ship-change/SKILL.md` — is the place that does not carry the
routing hint. This is a docs-only gap, not a behavior bug in either driver.

## Approach

Add a short, **deployment-conditional** paragraph near the top of
`plugins/aar-engineering/skills/ship-change/SKILL.md` (right after the opening "engineering counterpart to
`run-experiment`" paragraph, in the file's existing bold-lead-in voice):

- When the deployment configures a Claude Code cloud environment, **prefer** the sibling `cloud-ship` skill
  for repo-self-contained changes — it runs the author + cross-family review legs on a cloud VM and gates the
  bot close on the trusted host (the box holds the engineer keys).
- `ship-change` **remains the on-box path and the fallback** — used when the change needs box-local state, or
  when the cloud surface fails twice on the same Issue.
- The routing is **deployment-conditional**: nothing in the product assumes a cloud environment exists, and
  where none is configured `ship-change` is simply the path.

Mirror one line of the same routing hint in the `SKILL.md` **frontmatter description** (the free-text YAML
block scalar, so no schema constraint), so an agent skimming the description before opening the body also sees
the pointer. The `plugin.json` description already cross-references `cloud-ship`, so no manifest description
change is needed there beyond the required version bump.

Per repo convention, bump `aar-engineering`'s `plugin.json` version (`0.4.0 → 0.4.1`, a docs-only patch) —
required by `.aar-ci/checks.sh` §5 whenever a non-manifest plugin file changes so consumers pick up the
change. This proposal doc is the ADR/changelog record (the repo keeps no separate `CHANGELOG` file; the
`proposals/` ADR is the durable record).

## Alternatives considered

- **Put the routing hint only in the frontmatter description (skip the body paragraph).** The description is
  easy to skim past and truncated in some surfaces; the agent that hit this made its routing decision inside
  the lifecycle narrative. The body paragraph is where a reader deciding *how* to ship actually is. Keep both,
  with the body as the substantive statement and the frontmatter as the mirror.
- **Only edit the deployment/boot doc (what the instance already did).** That fixes one instance but leaves
  the product silent, so the next deployment or the next fresh agent re-hits the same gap. The issue explicitly
  asks the product to carry the routing hint too.
- **Make cloud-ship the unconditional default in the prose.** Rejected — the product must not assume a cloud
  environment exists (many deployments have none). The hint must stay conditional on the deployment having
  configured one, with `ship-change` as the always-valid path and fallback.
- **Add the hint to `marketplace.json`'s plugin blurb.** Out of scope and it would widen the blast radius (a
  `marketplace.json` edit triggers the README-namespace check and smokes every declared plugin); the two
  in-skill touchpoints (body + frontmatter) are where the routing decision is actually made.

## Blast radius

Docs-only, SWE-pipeline layer, one skill. Touches
`plugins/aar-engineering/skills/ship-change/SKILL.md` (one added paragraph + one frontmatter line), the
`aar-engineering` `plugin.json` version, and this proposal. No change to `wf.sh`, `cloud-ship`'s scripts, the
review gates, `.aar-ci`, or any product/research scaffold. No behavior change to either driver; the fake-HOME
behavior smoke still passes because skill discovery is unaffected (only prose changed). Where no cloud
environment is configured, the added guidance is inert.

## Rollout + rollback

Zero-risk docs change; ships through the normal cross-family review + checks. Rollback = revert the paragraph,
the frontmatter line, and the version bump. Verified by `.aar-ci/checks.sh` (JSON validity, version-increase,
fake-HOME discovery smoke) plus a read-through that the routing hint stays deployment-conditional.
