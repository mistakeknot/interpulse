---
name: status
description: Show current session pressure dashboard
---

# Interpulse Status

Show the current session's context pressure metrics from interpulse's monitoring hook.

## Instructions

Read the session state file at `/tmp/interpulse-${SESSION_ID}.json` where `SESSION_ID` is the current session's ID.

If the file doesn't exist, report "No interpulse data for this session (hooks may not be active)."

If the file exists, parse the JSON and display a pressure dashboard:

```
Session Pressure
──────────────────────────────
Context pressure:  {pressure} [{bar}] {level}
Estimated tokens:  ~{est_tokens/1000}k / 200k
Tool calls:        {calls} ({heavy_calls} heavy)
Session age:       {computed from first call to now}
──────────────────────────────
```

For the pressure bar, use a 16-char bar where filled = pressure/120 * 16.
For the level label: Green (< 60), Yellow (60-89), Orange (90-119), Red (>= 120).

Also check the token thresholds: Yellow >= 150k, Orange >= 180k, Red >= 200k. Report whichever level is higher between pressure and tokens.

If the session is in Yellow or above, add a recommendation line:
- Yellow: "Tip: Consider committing current work before starting new tasks."
- Orange: "Warning: Finish current work and commit. Avoid new subagents."
- Red: "URGENT: Context near exhaustion. Commit and wrap up immediately."
