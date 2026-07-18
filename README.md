# agentic-engineering

The engineering team's tooling — ship product/scaffold changes through a GitHub-backed, cross-family-reviewed lifecycle. General-purpose: build any software via PR-reviewed agents. The agents *are* the engineers; a change is authored by one model family and reviewed by the other.

## Install

```
/plugin marketplace add antondelafuente/agentic-engineering
/plugin install aar-engineering@agentic-engineering
/plugin install verify-claims@agentic-engineering
```

- **aar-engineering** — the `ship-change` lifecycle (Issue -> worktree -> design doc -> draft PR -> cross-family `--scaffold`/`--code` review -> checks -> fail-closed merge).
- **verify-claims** — the cross-family review engine ship-change gates on (`--scaffold`/`--code`), self-contained in this repo.

See `AGENTS.md` for the engineering pipeline and the Issue disposition contract.

Running the full lifecycle yourself (not just installing the skills) requires two engineer GitHub Apps plus
the `WF_ENGINEER_TOKEN_CMD_*` seams and branch protection set up; see
`plugins/aar-engineering/skills/ship-change/RUNBOOK.md` → **Self-hosting**.
