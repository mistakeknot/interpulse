# interpulse — Development Guide

## Canonical References
1. [`PHILOSOPHY.md`](./PHILOSOPHY.md) — direction for ideation and planning decisions.
2. `CLAUDE.md` — implementation details, architecture, testing, and release workflow.

## Philosophy Alignment Protocol
Review [`PHILOSOPHY.md`](./PHILOSOPHY.md) during:
- Intake/scoping
- Brainstorming
- Planning
- Execution kickoff
- Review/gates
- Handoff/retrospective

For brainstorming/planning outputs, add two short lines:
- **Alignment:** one sentence on how the proposal supports the module's purpose within Demarch's philosophy.
- **Conflict/Risk:** one sentence on any tension with philosophy (or 'none').

If a high-value change conflicts with philosophy, either:
- adjust the plan to align, or
- create follow-up work to update `PHILOSOPHY.md` explicitly.


> Cross-AI documentation for interpulse. Works with Claude Code, Codex CLI, and other AI coding tools.

## Quick Reference

| Item | Value |
|------|-------|
| Repo | `https://github.com/mistakeknot/interpulse` |
| Namespace | `interpulse:` |
| Manifest | `.claude-plugin/plugin.json` |
| Components | 1 skill, 0 commands, 0 agents, 1 hook (PostToolUse), 2 scripts |
| License | MIT |

### Release workflow
```bash
scripts/bump-version.sh <version>   # bump, commit, push, publish
```

## Overview

**interpulse** is a session context pressure monitor — tracks tool calls with time-decay, estimates token usage, and warns at configurable thresholds. Auto-checkpoints at Red.

**Problem:** Claude Code sessions accumulate context silently. By the time you notice degradation, you've lost important context to compaction. No early warning system.

**Solution:** PostToolUse hook tracks pressure via weighted tool calls and token estimation. Skill shows dashboard. Deliberately conservative — warn early rather than late.

**Plugin Type:** Claude Code skill + hook plugin
**Current Version:** 0.1.2

## Architecture

```
interpulse/
├── .claude-plugin/
│   └── plugin.json               # 1 skill
├── skills/
│   └── status/SKILL.md           # Pressure dashboard
├── hooks/
│   ├── hooks.json                # PostToolUse registration
│   └── context-monitor.sh        # Pressure tracker with warn/checkpoint logic
├── lib/
│   └── interpulse-lib.sh         # Shared state management (_ip_session_id, _ip_state_file, etc.)
├── scripts/
│   ├── bump-version.sh
│   └── validate-gitleaks-waivers.sh
├── tests/
│   ├── pyproject.toml
│   └── structural/
├── CLAUDE.md
├── AGENTS.md                     # This file
├── PHILOSOPHY.md
├── README.md
└── LICENSE
```

## Pressure Model

| Parameter | Value |
|-----------|-------|
| Standard tool call | +1.0 pressure |
| Heavy tool calls (Read, Grep, Task, WebFetch, WebSearch) | +1.5 pressure |
| Idle decay | -0.5 per 10 minutes |
| Token estimate | cumulative tool output length / 4 |

### Thresholds
| Zone | Pressure | Est. Tokens | Action |
|------|----------|-------------|--------|
| Green | < 60 | < 150k | Normal |
| Yellow | 60+ | ~150k | Warning |
| Orange | 90+ | ~180k | Strong warning |
| Red | 120+ | ~200k | Auto-checkpoint |

## Session State

Ephemeral file at `/tmp/interpulse-${SESSION_ID}.json`:
```json
{"calls": 0, "last_call_ts": 0, "pressure": 0.0, "heavy_calls": 0, "est_tokens": 0}
```

Resets each session by design — pressure tracking is session-scoped.

## Component Conventions

### Shared Library
`lib/interpulse-lib.sh` provides `_ip_session_id`, `_ip_state_file`, `_ip_read_state`, `_ip_write_state`. Guards against double-loading. Sourced by both the hook and skill scripts.

### Hook
`hooks/context-monitor.sh` — PostToolUse hook, fires on `Edit|Write|Bash|Task|NotebookEdit|MultiEdit`. Timeout: 5s. Registered in `hooks/hooks.json` (separate from plugin.json).

## Integration Points

| Tool | Relationship |
|------|-------------|
| intercheck | interpulse extracted from intercheck; intercheck now focuses on code quality |
| interspect | interspect monitors routing quality; interpulse monitors context pressure (complementary) |

## Testing

```bash
cd tests && uv run pytest -q
```

## Known Constraints

- Thresholds are heuristic — actual compaction depends on message structure, not just token count
- Session state is ephemeral (`/tmp/`) — no cross-session pressure history
- Extracted from intercheck; context monitoring is orthogonal to code quality
