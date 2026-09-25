# interpulse — Development Guide

## Canonical References
1. [`PHILOSOPHY.md`](./PHILOSOPHY.md) — direction for ideation and planning decisions.
2. `CLAUDE.md` — implementation details, architecture, testing, and release workflow.

> Cross-AI documentation for interpulse. Works with Claude Code, Codex CLI, and other AI coding tools.

## Quick Reference

| Item | Value |
|------|-------|
| Repo | `https://github.com/mistakeknot/interpulse` |
| Namespace | `interpulse:` |
| Manifest | `.claude-plugin/plugin.json` |
| Components | 1 skill, 0 commands, 0 agents, 2 hooks (PostToolUse, Stop), 2 scripts |
| License | MIT |

### Release workflow
```bash
scripts/bump-version.sh <version>   # bump, commit, push, publish
```

## Overview

**interpulse** is a session context pressure monitor with dual-threshold awareness — combines heuristic pressure tracking (tool calls + time decay + token estimation) with real context window remaining percentage from Claude Code. Debounces warnings to avoid spam, with severity escalation bypass.

**Problem:** Claude Code sessions accumulate context silently. By the time you notice degradation, you've lost important context to compaction. No early warning system.

**Solution:** PostToolUse hook uses dual-threshold logic: `level = max(pressure_level, context_level)`. Pressure tracks tool call weight with time decay. Context reads Claude Code's `context_window.remaining_percentage` and normalizes for the 16.5% autocompact buffer. Either metric can trigger warnings. Debounces at 5 calls between warnings, with severity escalation bypassing debounce.

A third, independent signal tracks REAL transcript context against a fixed ABSOLUTE token threshold (default 100000), because the two signals above scale with the model's context window and fire far too late on 1M-context models. `hooks/context-monitor.sh` reports crossings of that absolute threshold (once per 25k-token band) alongside its existing heuristic bands. A Stop hook, `hooks/coordinator-handoff.sh`, uses the same absolute threshold and the same measurement function to decide whether a bb coordinator/worker thread needs a handoff nudge — blocking for coordinators, advisory for workers.

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
│   ├── hooks.json                # PostToolUse + Stop registration
│   ├── context-monitor.sh        # Pressure tracker with warn/checkpoint logic + absolute real-context reporting
│   └── coordinator-handoff.sh    # Stop hook: bb coordinator/worker handoff nudge at an absolute token threshold
├── lib/
│   └── interpulse-lib.sh         # Shared state management + transcript token measurement
├── scripts/
│   ├── bump-version.sh
│   └── validate-gitleaks-waivers.sh
├── tests/
│   ├── pyproject.toml
│   ├── structural/
│   ├── shell/                    # bats tests for the hooks (coordinator-handoff, context-monitor abs extension)
│   └── fixtures/coordinator-handoff/
├── CLAUDE.md
├── AGENTS.md                     # This file
├── PHILOSOPHY.md
├── README.md
└── LICENSE
```

## Dual-Threshold Model

Level = max(pressure_level, context_level) — either metric can trigger warnings.

### Pressure Thresholds (heuristic)

| Parameter | Value |
|-----------|-------|
| Standard tool call | +1.0 pressure |
| Heavy tool calls (Read, Grep, Task, WebFetch, WebSearch) | +1.5 pressure |
| Idle decay | -0.5 per 10 minutes |
| Token estimate | cumulative tool output length / 4 |

| Zone | Pressure | Est. Tokens | Action |
|------|----------|-------------|--------|
| Green | < 60 | < 150k | Normal |
| Yellow | 60+ | ~150k | Warning |
| Orange | 90+ | ~180k | Strong warning |
| Red | 120+ | ~200k | Auto-checkpoint |

### Context Thresholds (ground truth)

Reads `context_window.remaining_percentage` from PostToolUse stdin JSON and normalizes for Claude Code's 16.5% autocompact buffer. Falls back to pressure-only when absent.

| Zone | Usable Remaining | Example Raw % | Action |
|------|-----------------|---------------|--------|
| Green | > 35% | > 46% | Normal |
| Yellow | <= 35% | <= 46% | Warning |
| Orange | <= 20% | <= 33% | Strong warning |
| Red | <= 10% | <= 25% | Auto-checkpoint |

### Debounce

- 5 tool calls minimum between repeated warnings at the same level
- Severity escalation (e.g., yellow→orange, orange→red) bypasses debounce and fires immediately
- Debounce state stored at `/tmp/interpulse-debounce-${SESSION_ID}.json`

### Absolute Real-Context Threshold (independent of the two signals above)

`hooks/context-monitor.sh` (PostToolUse) and `hooks/coordinator-handoff.sh` (Stop) both measure the REAL transcript context via `lib/interpulse-lib.sh`'s `_ip_transcript_tokens` — the last main-chain assistant record's `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` — and compare it against a fixed **absolute** token count (`INTERPULSE_COORD_CONTEXT_TOKENS`, default 100000), never a percentage of the window. This is deliberate: on a 1M-token model, 150k real tokens is only ~15% used and never trips the percentage-based bands above.

- `context-monitor.sh` reports a crossing once per 25k-token band as `additionalContext`, independent of (and in addition to) its heuristic pressure/context-window level — it can fire while the heuristic level is still green.
- `coordinator-handoff.sh` (Stop) makes this a `{"decision":"block", ...}` for a bb **coordinator** thread (marked via `bb handoff coordinator status --self --json`, or has non-archived children), and an advisory `systemMessage` for a **worker** thread. Blocking re-fires once per 25k-token band past the threshold (100k, 125k, 150k, …), not on every Stop.
- The coordinator model name in the directive comes from Clavain's `scripts/coordinator-model.sh`, called as an external command (never reimplemented here) via `CLAVAIN_COORDINATOR_MODEL_CMD` (default `coordinator-model.sh`, resolved on `PATH`). If that command is missing or fails, this hook falls back to the hardcoded pair `claude-code claude-sonnet-5` and never emits an Opus-class model for this role.
- State (the per-session band file) is written only after a full determination completes for that Stop — never before or during a bb lookup that outcome depends on — so a transient bb failure never freezes a band as "checked" for the rest of its 25k tokens. See the header comment in `hooks/coordinator-handoff.sh` for the full rationale.

## Session State

Ephemeral file at `/tmp/interpulse-${SESSION_ID}.json`:
```json
{"calls": 0, "last_call_ts": 0, "pressure": 0.0, "heavy_calls": 0, "est_tokens": 0}
```

Resets each session by design — pressure tracking is session-scoped.

## Interband Payload

Written to `~/.interband/interpulse/pressure/${SESSION_ID}.json` for statusline and other consumers:
```json
{"level": "yellow", "pressure": 65.5, "est_tokens": 155000, "ts": 1741318800, "context_usable": 30, "context_raw": 41.5}
```

`context_usable` and `context_raw` are only present when `context_window.remaining_percentage` is available. The `level` field uses the pre-debounce severity so consumers always see the raw signal.

## Component Conventions

### Shared Library
`lib/interpulse-lib.sh` provides:
- `_ip_session_id`, `_ip_state_file`, `_ip_read_state`, `_ip_write_state` — session state management
- `_ip_context_remaining` — extract `context_window.remaining_percentage` from hook stdin JSON
- `_ip_normalize_usable_context` — normalize raw % to usable % (accounting for 16.5% buffer)
- `_ip_context_level` — map usable remaining % to severity level
- `_ip_max_level` — return the higher severity of two levels
- `_ip_transcript_path` — extract `transcript_path` from hook stdin JSON
- `_ip_transcript_tokens` — real transcript context tokens + model, from a bounded tail read; shared by both hooks so they always agree on the same absolute number
- `_ip_absolute_band` — 25k-token band index above a fixed threshold (empty when below it)

Guards against double-loading. Sourced by both hooks and skill scripts.

### Hooks
- `hooks/context-monitor.sh` — PostToolUse hook, fires on `Edit|Write|Bash|Task|NotebookEdit|MultiEdit`. Timeout: 5s.
- `hooks/coordinator-handoff.sh` — Stop hook. Timeout: 5s.

Both registered in `hooks/hooks.json` (separate from plugin.json).

## Integration Points

| Tool | Relationship |
|------|-------------|
| intercheck | interpulse extracted from intercheck; intercheck now focuses on code quality |
| interspect | interspect monitors routing quality; interpulse monitors context pressure (complementary) |

## Testing

```bash
cd tests && uv run pytest -q     # structural tests
bats tests/shell/*.bats          # hook behavior tests (coordinator-handoff, context-monitor abs extension)
```

## Known Constraints

- Pressure thresholds are heuristic — actual compaction depends on message structure, not just token count
- Context thresholds use ground truth when available, but `context_window.remaining_percentage` may be absent in subagents or older Claude Code versions
- Session state is ephemeral (`/tmp/`) — no cross-session pressure history
- Extracted from intercheck; context monitoring is orthogonal to code quality
