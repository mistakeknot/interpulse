# Interpulse

Session context monitoring — dual-threshold pressure tracking with context window awareness, debounce, and auto-checkpointing.

## Hooks

- `hooks/context-monitor.sh` (PostToolUse) — Dual-threshold context monitor. Combines heuristic pressure (call count + time decay + token estimate) with real `context_window.remaining_percentage` from Claude Code. Warns at Yellow/Orange/Red thresholds. Debounces warnings (5 calls between repeats, severity escalation bypasses). Auto-checkpoints at Red. ALSO tracks/reports the same absolute real-context threshold as the Stop hook below (see "Absolute Real-Context Threshold"), as an additional, independent signal — it does not replace or alter the heuristic bands.
- `hooks/coordinator-handoff.sh` (Stop) — nudges bb coordinator/worker threads to hand off once REAL transcript context crosses an absolute token threshold (default 100000, not a percentage of the model's window). Coordinators (bb-marked, or holding non-archived children) get a blocking `{"decision":"block",...}` naming the exact `bb handoff` commands; workers get an advisory `systemMessage`. Fires once per 25k-token band past the threshold. Resolves the coordinator's model by calling Clavain's `scripts/coordinator-model.sh` externally (never Opus, falls back to `claude-sonnet-5` if that command is unavailable).

## State

- Session state: `/tmp/interpulse-${SESSION_ID}.json` — call count, pressure score, estimated tokens, heavy call count.
- Debounce state: `/tmp/interpulse-debounce-${SESSION_ID}.json` — calls since last warning, last severity level.
- Absolute-threshold band state (context-monitor.sh): `/tmp/interpulse-absband-${SESSION_ID}`.
- Coordinator-handoff band state (coordinator-handoff.sh): `${INTERPULSE_COORD_STATE_DIR:-~/.interpulse/coordinator-handoff}/${SESSION_ID}.band` — written only after a full per-Stop determination completes, never before or during a bb lookup (see the header comment in the hook for why: a transient bb failure must not freeze a band as "checked").

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
