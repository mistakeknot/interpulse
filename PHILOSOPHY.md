# interpulse Philosophy

## Purpose
Session context monitoring — pressure tracking with time-decay, token estimation, and threshold warnings. Extracted from intercheck.

## North Star
Surface context pressure before it causes degraded output.

## Working Priorities
- Pressure detection accuracy
- Warning timeliness (early enough to act)
- Token estimation precision

## Brainstorming Doctrine
1. Start from outcomes and failure modes, not implementation details.
2. Generate at least three options: conservative, balanced, and aggressive.
3. Explicitly call out assumptions, unknowns, and dependency risk across modules.
4. Prefer ideas that improve clarity, reversibility, and operational visibility.

## Planning Doctrine
1. Convert selected direction into small, testable, reversible slices.
2. Define acceptance criteria, verification steps, and rollback path for each slice.
3. Sequence dependencies explicitly and keep integration contracts narrow.
4. Reserve optimization work until correctness and reliability are proven.

## Decision Filters
- Does this warn before quality degrades?
- Does this reduce false alarms?
- Is the overhead negligible vs the context saved?
- Can the user act on the warning?
