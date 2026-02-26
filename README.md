# interpulse

Session context monitoring for Claude Code.

## What this does

interpulse tracks how much of Claude Code's context window you've consumed during a session. Every tool call adds to a pressure score (heavier calls like Read, Grep, Task, WebFetch count more), pressure decays over idle time, and the plugin warns you as you approach the limit — Yellow at 60%, Orange at 75%, Red at 85%.

At Red, it auto-checkpoints context by writing a session summary, so you can recover gracefully instead of hitting a hard wall.

The pressure model is deliberately conservative: it's better to warn early and be wrong than to warn late and lose context.

## Installation

First, add the [interagency marketplace](https://github.com/mistakeknot/interagency-marketplace) (one-time setup):

```bash
/plugin marketplace add mistakeknot/interagency-marketplace
```

Then install the plugin:

```bash
/plugin install interpulse
```

## Usage

Check session pressure:

```
/interpulse:status
```

Or ask naturally:

```
"how much context have I used?"
"am I close to the limit?"
```

Warnings appear automatically as hooks fire — no manual checking needed for the alert thresholds.

## Pressure model

| Signal | Weight |
|--------|--------|
| Standard tool call | +1.0 |
| Heavy tool call (Read, Grep, Task, WebFetch, WebSearch) | +1.5 |
| Idle decay | -0.5 per 10 minutes |
| Token estimate | Cumulative tool output length / 4 |

| Threshold | Score | Tokens |
|-----------|-------|--------|
| Green | < 60 | < 150k |
| Yellow | 60+ | 150k+ |
| Orange | 90+ | 180k+ |
| Red | 120+ | 200k+ |

## Architecture

```
hooks/
  hooks.json              PostToolUse hook registration
  context-monitor.sh      Pressure tracker — scores, warns, checkpoints
lib/
  interpulse-lib.sh       Shared functions
skills/
  status/SKILL.md         Pressure dashboard skill
```

Session state lives at `/tmp/interpulse-${SESSION_ID}.json` — ephemeral by design, since pressure resets each session.

## Ecosystem

interpulse was extracted from [intercheck](https://github.com/mistakeknot/intercheck), which now focuses exclusively on code quality (syntax validation + auto-formatting). The context monitoring concern is orthogonal to code quality, so they're better as separate installs.
