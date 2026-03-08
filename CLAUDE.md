# Interpulse

Session context monitoring — dual-threshold pressure tracking with context window awareness, debounce, and auto-checkpointing.

## Hooks

- `hooks/context-monitor.sh` — Dual-threshold context monitor. Combines heuristic pressure (call count + time decay + token estimate) with real `context_window.remaining_percentage` from Claude Code. Warns at Yellow/Orange/Red thresholds. Debounces warnings (5 calls between repeats, severity escalation bypasses). Auto-checkpoints at Red.

## State

- Session state: `/tmp/interpulse-${SESSION_ID}.json` — call count, pressure score, estimated tokens, heavy call count.
- Debounce state: `/tmp/interpulse-debounce-${SESSION_ID}.json` — calls since last warning, last severity level.

## Skill

- `/interpulse:pressure` — Show current session pressure dashboard.

## Dual-Threshold Model

Level = max(pressure_level, context_level) — either metric can trigger warnings.

**Pressure thresholds (heuristic):**
- Each tool call adds 1.0 (or 1.5 for Read/Grep/Task/WebFetch/WebSearch)
- Pressure decays 0.5 per 10 minutes of inactivity
- Token estimate: cumulative tool output length / 4
- Green < 60, Yellow 60+, Orange 90+, Red 120+ (or token equivalents at 150k/180k/200k)

**Context thresholds (ground truth, normalized for 16.5% autocompact buffer):**
- Green: usable > 35%, Yellow: usable <= 35%, Orange: usable <= 20%, Red: usable <= 10%
- Falls back to pressure-only when `context_window` is absent (subagents, older Claude Code)
