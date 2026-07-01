# Cloud dispatch: SessionStart hook to auto-load AAR auth on Claude Code web VMs (#16)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

We proved (2026-07-01) that codex — the cross-family reviewer ship-change depends on — runs on **Claude Code on the web** (Anthropic-hosted, ephemeral ~16GB VMs, no compute charge) once its auth is present in the VM's `~/.codex`. This unlocks running ship-change harness fixes on cloud instead of the always-on Hetzner box (which is RAM-constrained).

But a real `wf.sh` run has no place to hand-extract the auth first — it must be materialized automatically at session start. And a Claude Code cloud session only sees the **repo's** `.claude/` config: user-level `~/.claude/` and box-side env do NOT travel to the VM. So the auto-load must live in a repo.

## Approach

Add a **cloud-only `SessionStart` hook** in *this* repo (agentic-engineering), running `scripts/cloud-bootstrap.sh`. Guarded on `CLAUDE_CODE_REMOTE=true`, it decodes two env vars — set on the `aar-ship` cloud environment — into `$HOME`:
- `CODEX_AUTH_B64` → `~/.codex` (the chatgpt-mode OAuth reviewer auth).
- `ENGINEER_KEYS_B64` → `~/.config/{claude,codex}-engineer` (the engineer-bot App keys for the gated cross-family merge; supplied in phase 2 — the hook already handles it when present).

Only the env-var **names** appear in-repo; the secret values live solely in the `aar-ship` environment config (Anton-owned, web UI).

Why here and not the product repo: agentic-engineering owns the engineering tooling (`wf.sh` + the SWE reviewer). Cloud ship-change dispatches from here, so the auth glue belongs here — the product repo (automated-researcher) stays clean of cloud-dispatch infra, consistent with the product boundary.

## Alternatives considered

- **Per-target-repo hook** (put it in each repo ship-change changes): leaks cloud-dispatch glue into the product repo. Rejected.
- **Setup-script bake** (extract in the `aar-ship` setup script, snapshot-cached): works, but it's Anton-owned (web UI), not version-controlled, and env-var availability during the setup/snapshot phase is unconfirmed. The runtime SessionStart hook is in our control and always has the runtime env.

## Blast radius

Inert for every local/fleet session: the first line of `cloud-bootstrap.sh` exits 0 when `CLAUDE_CODE_REMOTE` is unset, so it never touches a local `~/.codex` or `~/.config`. Adds one script (`scripts/cloud-bootstrap.sh`) + one `.claude/settings.json` (new; no existing settings to merge) + a short AGENTS.md note. Enables cloud ship-change; no behavior change on the box.

## Rollout + rollback

Merge here. Phase-2 (`ENGINEER_KEYS_B64` bundle + a full cloud `wf.sh` PR end-to-end) follows; the hook already handles that var when present. Rollback: revert the PR — the hook is additive and guarded, so removal has no local effect.
