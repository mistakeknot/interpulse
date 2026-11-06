#!/usr/bin/env bash
# Stop hook: coordinator-handoff — nudge bb coordinator/worker threads to
# hand off once REAL transcript context crosses an absolute token threshold.
#
# Ported (not copied) from Clavain hooks/context-handoff.sh (bead mk-42j9.13),
# adapted to interpulse's
# conventions and hardened against a fail-open-state-drift finding from that
# port's own security review (see "STATE PERSISTENCE" below).
#
# Context measure: the last main-chain (isSidechain=false, type=assistant,
# message.model != "<synthetic>") record's
# input_tokens + cache_creation_input_tokens + cache_read_input_tokens,
# via lib/interpulse-lib.sh's _ip_transcript_tokens (bounded 256 KiB tail
# read, shared with hooks/context-monitor.sh's PostToolUse extension so both
# mechanisms measure and threshold on the exact same absolute number).
# Synthetic records (Claude Code's own zero-usage markers for rate-limit/
# OAuth-expiry/similar turns, matching scripts/burn-report.py:83's skip) are
# excluded so a turn that ends on one of those doesn't measure as 0 and go
# silent.
#
# This is an ABSOLUTE threshold (default 90000 tokens, INTERPULSE_COORD_CONTEXT_DEFAULT), not a percentage of
# the model's context window: context-monitor.sh's existing heuristic
# Yellow/Orange/Red bands are a percentage of window size and fire far too
# late on 1M-context models (100k tokens is 10% there, not the "context
# nearly exhausted" that 85% implies elsewhere). This hook and the
# context-monitor.sh extension deliberately do not scale with window size.
#
# Settings:
#   INTERPULSE_COORD_CONTEXT_TOKENS  threshold, default INTERPULSE_COORD_CONTEXT_DEFAULT
#                                    (90000, set in lib/interpulse-lib.sh)
#   INTERPULSE_COORD_HOOK=off        disables the hook entirely
#   INTERPULSE_COORD_STATE_DIR       per-session band-throttle dir (default
#                                    ~/.interpulse/coordinator-handoff)
#   INTERPULSE_COORD_CONTEXT_WINDOW  explicit override for the window used to
#                                    convert a fractional bb rotateAt (e.g.
#                                    0.3) into a token count. Unset by
#                                    default: read live from
#                                    `bb thread context "$BB_THREAD_ID" --json`
#                                    fresh every time this hook does a bb
#                                    lookup. If unavailable, a fractional
#                                    rotateAt is treated as NOT satisfying the
#                                    rotation-ok check (fail toward emitting
#                                    the directive, never toward silence).
#
# STATE PERSISTENCE (fail-open-state-drift hardening):
#
#   Band throttle (at most one bb consult per 25k-token band per session):
#   the band file is written ONLY after this Stop reaches a fully determined
#   outcome (silence because rotation is genuinely ok, a coordinator block,
#   or a worker advisory) -- never before or during the bb lookups that
#   outcome depends on. The band file is also DELETED whenever context is
#   measured below the threshold (P2-2): otherwise a session that dropped
#   below threshold (e.g. via /compact) and later climbed back into the same
#   band number would find that band already marked and stay silent, losing
#   the required block for up to 25k tokens.
#
#   The Clavain original wrote the band file BEFORE any bb lookup, as a
#   throttle optimization. That means a bb failure/timeout partway through
#   this Stop's checks (which still exits 0, silent, by design) left the
#   band file claiming the band HAD been checked -- so a real coordinator
#   sitting well over threshold got no directive for the rest of that
#   25k-token band, purely because bb hiccuped once. That is exactly a
#   fail-open path that swallows an error and silently defaults to "handled"
#   when it could not actually determine that. Every bb-lookup failure path
#   below `exit`s before the band file is ever touched, so the very next
#   Stop (even one token later, same band) retries against bb instead of
#   trusting a determination that never completed.
#
#   Reading the band file back (P2-3) never trusts a bare `&&`-chained
#   command substitution: `cat` on an unreadable file (foreign-owned state
#   dir, bad restore, permission change) must not trip the script-wide ERR
#   trap and silence the hook permanently -- see the PREV_BAND read below.
#
#   Nothing beyond the plain band integer is cached across bands. Rotation
#   state, coordinator/worker status and the live context window are always
#   re-read fresh from bb the moment a NEW band is reached -- there is no
#   session-scoped cache of any of those that could drift stale (matches
#   Clavain's P2-3 fix: a per-session cache previously froze this state from
#   the first check of the session).
#
#   If the state directory itself can't be created/written (disk full,
#   permissions), this hook does NOT abort silently -- STATE_WRITABLE=false
#   lets every subsequent Stop still perform the full, fresh determination
#   (just without the band throttle optimization). Aborting the whole hook
#   on a filesystem hiccup would itself be a silent "under threshold" default
#   for a condition (coordinator over threshold) this hook never actually
#   re-checked.
#
# Rotation (bead mk-w6ic8): bb declines to rotate a thread whose rotate-at is
# below 2x its marking's seedTokens ("threshold-below-seed"), and rotates on
# idle once context passes a valid rotate-at. So a coordinator's directive is
# only ever `bb handoff coordinator enable --self --rotate-at N` with N =
# max(threshold, 2x seed). It never advises `--replace` or a model: on
# generation-2 coordinators `--replace` exits 1 (legacy-migration-hold), and
# the coordinator's seat is chosen by bb, not by this hook. A thread already
# enabled at a valid N earns silence for the FIRST 25k-token band above it;
# a later Stop still past that gets a non-blocking note (no manual handoff).
# The vizier thread (title "Masaq' | vizier...") rotates by idle and is never
# advised. Nothing here persists trust beyond the current band: everything is
# re-read fresh from bb on each new band.
#
# Runtime budget (P2-4): each external call (bb) is capped at 1s via
# `timeout`, and an overall elapsed-time check skips the remaining OPTIONAL
# lookups (the live context-window read) once this Stop has already run for
# about 6s, falling back to the documented safe default ("window unknown").
# hooks.json's Stop entry timeout is 10s, giving headroom above the worst case.
#
# Coordinator: blocking `{"decision":"block","reason":...}`.
# Worker: advisory `{"systemMessage":...}`, never a block.
# Silent (exit 0, no output) on: jq missing, a headless/`claude -p` session
# or a dispatched child that inherited a coordinator's BB_THREAD_ID (see
# _ip_is_headless below), INTERPULSE_COORD_HOOK=off,
# no BB_THREAD_ID, stop_hook_active, below threshold, a same-band repeat
# that already reached a determined outcome, or any bb lookup
# failure/timeout (which never persists band state -- see above).
#
# Known limits: requires bash >= 4.4 (`${x,,}`) and coreutils `timeout`
# (stock macOS bash/coreutils are not supported -- the hook exits 1 there
# and never enforces); PostToolUse's `additionalContext` output shape in
# hooks/context-monitor.sh is unchanged by this hardening pass.
set -uo pipefail
trap 'exit 0' ERR

HOOK_START_S=$(date +%s)
# Optional-call time budget (P2-4): once this Stop has run this long,
# remaining OPTIONAL lookups (the live context-window read) are skipped in
# favor of their documented safe defaults, instead of risking the hooks.json
# Stop timeout and losing the whole determination
# (including a real block) to a slow/hung external process. Overridable only
# for tests.
_ip_elapsed_over_budget() {
    local budget="${INTERPULSE_COORD_TIME_BUDGET_S:-6}"
    local now
    now=$(date +%s) || return 1
    (( now - HOOK_START_S >= budget ))
}

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=lib/interpulse-lib.sh
source "$SCRIPT_DIR/../lib/interpulse-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

[[ "${INTERPULSE_COORD_HOOK:-}" == "off" ]] && exit 0

# --- Headless / dispatched-child guard (P1-1) ---------------
# A Stop hook's decision:"block" is injected as a NEW PROMPT TURN. In a
# headless `claude -p`/`--print` run that injected turn's reply REPLACES the
# reply the caller actually asked for (observed live 2026-07-20: a scripted
# data pass lost 44/45 responses to hook chatter).
#
# Separately: Clavain's scripts/dispatch.sh claude backend runs `claude -p`
# with the parent's environment, and nothing unsets BB_THREAD_ID, so a
# dispatched validation/review child inherits its coordinator PARENT's
# thread ID. Without this guard, that child's own Stop could resolve (via
# `bb handoff coordinator status --self`) to the marked PARENT thread and,
# if its block advised a handoff that archives the live
# coordinator. The headless check below covers this: a dispatched child is
# itself a `claude -p` process, so it is caught the same way.
#
# This is a self-contained port of Clavain hooks/lib-headless.sh's
# clavain_is_headless -- deliberately NOT sourced from an installed Clavain
# (this hook never imports Clavain internals).
# ancestors looking for a `claude` process; if found running as
# `-p`/`--print`, this session is headless. Fails OPEN (returns 1, "not
# headless") on any `ps` error, so a detector bug never suppresses the
# interactive block this hook exists to emit.
#
# A cheaper same-session check (comparing the Stop payload's session against
# whatever `bb thread context --self` reports) was considered too, but this
# hook has no bb call that is unconditionally made before the headless
# check -- adding one here would cost an extra bb round trip on every single
# Stop, not just above threshold, which this hook's whole design (bb
# consulted only once we already know we're above threshold) avoids. Absent
# a documented session-id field on an already-budgeted bb call, this stays
# a ps-only check.
_ip_is_headless() {
    local pid=$$ args exe
    local _i
    for _i in 1 2 3 4 5 6 7 8; do
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || return 1
        [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && return 1
        args="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
        # Match the executable's basename only, so a wrapper shell whose
        # command line merely mentions "claude" (a plugin path) is skipped
        # and the walk continues to the real claude ancestor.
        exe="${args%% *}"
        exe="${exe##*/}"
        if [[ "$exe" == "claude" ]]; then
            case " $args " in
                *" -p "*|*" --print "*) return 0 ;;
            esac
            return 1
        fi
    done
    return 1
}
_ip_is_headless && exit 0

# Not a bb session: nothing to hand off.
[[ -n "${BB_THREAD_ID:-}" ]] || exit 0

INPUT="$(cat)"

STOP_ACTIVE="$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" || exit 0
[[ "$STOP_ACTIVE" == "true" ]] && exit 0

TRANSCRIPT="$(_ip_transcript_path "$INPUT")"
[[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)" || exit 0
if [[ -z "$SESSION_ID" ]]; then
    # Missing session_id (P3): the literal "unknown" is shared by every such
    # session, so they'd all throttle each other's band file. Hash the
    # transcript path instead -- distinct transcripts get distinct keys.
    SESSION_ID="unknown-$(printf '%s' "$TRANSCRIPT" | cksum 2>/dev/null | cut -d' ' -f1)"
    [[ -n "$SESSION_ID" && "$SESSION_ID" != "unknown-" ]] || SESSION_ID="unknown"
fi

THRESHOLD="${INTERPULSE_COORD_CONTEXT_TOKENS:-$INTERPULSE_COORD_CONTEXT_DEFAULT}"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || exit 0

STATE_DIR="${INTERPULSE_COORD_STATE_DIR:-$HOME/.interpulse/coordinator-handoff}"
STATE_WRITABLE=true
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_WRITABLE=false
SAFE_SID="$(printf '%s' "$SESSION_ID" | tr '/:' '__')"
BAND_FILE="$STATE_DIR/${SAFE_SID}.band"

# --- Context measure (shared with context-monitor.sh's absolute tracking) ---
RESULT="$(_ip_transcript_tokens "$TRANSCRIPT")"
CONTEXT_TOKENS="${RESULT%% *}"

[[ "$CONTEXT_TOKENS" =~ ^[0-9]+$ ]] || exit 0
if (( CONTEXT_TOKENS < THRESHOLD )); then
    # P2-2: clear any stale band marker so re-entering a later band (e.g.
    # after a /compact drop and climbing back up) isn't suppressed by a
    # band number that was already "handled" before the drop.
    [[ "$STATE_WRITABLE" == true ]] && rm -f "$BAND_FILE" 2>/dev/null
    exit 0
fi

# --- Band throttle: read only (write deferred until a real outcome exists) --
band=$(( CONTEXT_TOKENS / 25000 ))
PREV_BAND=""
if [[ -f "$BAND_FILE" ]]; then
    # P2-3: never let a failing `cat` (unreadable file: foreign-owned state
    # dir, chmod 000, bad restore) reach the script-wide ERR trap as the
    # tail of an `&&` list -- that would silence this hook on every Stop,
    # permanently, with no bb call and no retry.
    PREV_BAND="$(cat "$BAND_FILE" 2>/dev/null)" || PREV_BAND=""
fi
[[ "$PREV_BAND" == "$band" ]] && exit 0

_persist_band() {
    [[ "$STATE_WRITABLE" == true ]] || return 0
    # Grouped so 2>/dev/null actually covers a failure to OPEN "$BAND_FILE"
    # for writing (e.g. a foreign-owned/unreadable band file left over from
    # a prior run): `cmd > "$f" 2>/dev/null` alone applies redirects
    # left-to-right, so a failed `> "$f"` open prints its "Permission
    # denied" straight to the real stderr before `2>/dev/null` ever takes
    # effect. Wrapping in a group applies both redirects to the group as a
    # unit first.
    { printf '%s' "$band" > "$BAND_FILE"; } 2>/dev/null || true
}


# --- Who counts as a coordinator (bb consulted fresh, once per band) ---
# Every bb-lookup failure below exits WITHOUT calling _persist_band, so the
# band file never claims this Stop reached a determination it didn't.
command -v bb >/dev/null 2>&1 || exit 0
# Every external call must be hard-bounded: without `timeout` we cannot
# bound them, so stay silent. `-k 0.2` sends SIGKILL if SIGTERM is ignored.
command -v timeout >/dev/null 2>&1 || exit 0
TIMEOUT_CMD=(timeout -k 0.2 1)

IS_COORDINATOR="false"
ROTATION_ENABLED="false"
ROTATE_AT=""

STATUS_JSON="$("${TIMEOUT_CMD[@]}" bb handoff coordinator status --self --json 2>/dev/null)" || exit 0
[[ -n "$STATUS_JSON" ]] || exit 0
MARKED="$(jq -r 'if .marking == null then "false" else "true" end' <<<"$STATUS_JSON" 2>/dev/null)" || exit 0

if [[ "$MARKED" == "true" ]]; then
    IS_COORDINATOR="true"
    ROTATION_ENABLED="$(jq -r '.rotationEnabled // false' <<<"$STATUS_JSON" 2>/dev/null)" || true
    ROTATE_AT="$(jq -r '.marking.rotateAt // empty' <<<"$STATUS_JSON" 2>/dev/null)" || true
else
    # Overall deadline: skip the second lookup if the first ate the budget.
    _ip_elapsed_over_budget && exit 0
    # --include-hidden: a hidden child still makes this thread a coordinator.
    CHILDREN_JSON="$("${TIMEOUT_CMD[@]}" bb thread list --parent-thread "$BB_THREAD_ID" --include-hidden --json 2>/dev/null)" || exit 0
    [[ -n "$CHILDREN_JSON" ]] || exit 0
    CHILD_COUNT="$(jq '[.[] | select(.archivedAt == null)] | length' <<<"$CHILDREN_JSON" 2>/dev/null)" || exit 0
    [[ "$CHILD_COUNT" =~ ^[0-9]+$ ]] || exit 0
    (( CHILD_COUNT > 0 )) && IS_COORDINATOR="true"
fi

if [[ "$IS_COORDINATOR" == "true" ]]; then
    # Effective rotate-at in tokens: a fraction in [0,1) is scaled by the
    # thread's live context window (bb's own fraction/absolute split is
    # `<1`, not `<=1`); anything else is treated as an absolute token count.
    ROTATE_EFFECTIVE=-1
    if [[ "$ROTATION_ENABLED" == "true" && -n "$ROTATE_AT" && "$ROTATE_AT" != "null" ]]; then
        IS_FRACTION="$(awk -v r="$ROTATE_AT" 'BEGIN{ print (r+0>0 && r+0<1) ? "yes" : "no" }' 2>/dev/null)" || IS_FRACTION="no"

        if [[ "$IS_FRACTION" == "yes" ]]; then
            WINDOW="${INTERPULSE_COORD_CONTEXT_WINDOW:-}"
            if [[ -z "$WINDOW" ]]; then
                if _ip_elapsed_over_budget; then
                    # P2-4: this lookup is OPTIONAL (see the fallback
                    # below) -- past the time budget, treat it the same as
                    # a failed/timed-out call rather than risk pushing this
                    # Stop past its hooks.json timeout.
                    WINDOW=""
                else
                    # `|| true`: a nonzero exit here (bb failure/timeout) falls
                    # through to "window unknown" below, never toward silence.
                    CONTEXT_JSON="$("${TIMEOUT_CMD[@]}" bb thread context "$BB_THREAD_ID" --json 2>/dev/null)" || true
                    WINDOW="$(jq -r '.usage.modelContextWindow // empty' <<<"$CONTEXT_JSON" 2>/dev/null)" || true
                    [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=""
                fi
            fi

            if [[ "$WINDOW" =~ ^[0-9]+$ ]]; then
                ROTATE_EFFECTIVE="$(awk -v r="$ROTATE_AT" -v w="$WINDOW" 'BEGIN{ printf "%d", r*w }' 2>/dev/null)"
            else
                # Window unknown: fail toward emitting the directive.
                ROTATE_EFFECTIVE=-1
            fi
        else
            ROTATE_EFFECTIVE="$(awk -v r="$ROTATE_AT" 'BEGIN{ printf "%d", r }' 2>/dev/null)"
        fi
        [[ "$ROTATE_EFFECTIVE" =~ ^-?[0-9]+$ ]] || ROTATE_EFFECTIVE=-1
    fi

    # Never advise the vizier thread: it rotates by idle on its own.
    TITLE="$("${TIMEOUT_CMD[@]}" bb thread show "$BB_THREAD_ID" --json 2>/dev/null | jq -r '.thread.title // empty' 2>/dev/null)" || TITLE=""
    case "$TITLE" in
        "Masaq' | vizier"*) _persist_band; exit 0 ;;
    esac

    # bb declines to rotate a thread whose rotate-at is below 2x its seed
    # ("threshold-below-seed"), and rotates on idle once context passes a valid
    # rotate-at. So the advice is only ever to (re)enable at a value that is
    # at least 2x the seed and at least this hook's own threshold. There is no
    # manual --replace handoff and no model advice here.
    SEED=0
    SEED_RAW="$(jq -r '.marking.seedTokens // empty' <<<"$STATUS_JSON" 2>/dev/null)" || SEED_RAW=""
    [[ "$SEED_RAW" =~ ^[0-9]+$ ]] && SEED="$SEED_RAW"
    DECLINE="$(jq -r '.lastDeclineReason // empty' <<<"$STATUS_JSON" 2>/dev/null)" || DECLINE=""
    MIN_ROTATE=$(( SEED * 2 ))
    TARGET="$THRESHOLD"
    (( MIN_ROTATE > TARGET )) && TARGET="$MIN_ROTATE"

    # Configured: enabled at a value bb will honor (>= 2x seed) and no higher
    # than the target, so rotation fires once context passes it.
    ROTATION_CONFIGURED="false"
    if [[ "$ROTATION_ENABLED" == "true" && "$ROTATE_EFFECTIVE" -ge 0 \
          && "$ROTATE_EFFECTIVE" -ge "$MIN_ROTATE" && "$ROTATE_EFFECTIVE" -le "$TARGET" ]]; then
        ROTATION_CONFIGURED="true"
    fi

    if [[ "$ROTATION_CONFIGURED" == "true" ]]; then
        # Trusted for the first 25k-token band above rotate-at; a later Stop
        # still past that means bb evidently has not rotated (not idle yet,
        # hold, cooldown, generation cap).
        if (( CONTEXT_TOKENS - ROTATE_EFFECTIVE < 25000 )); then
            _persist_band
            exit 0
        fi
        REASON="Context handoff (advisory): this coordinator is at ~${CONTEXT_TOKENS} tokens and rotation is enabled at ${ROTATE_EFFECTIVE}, but bb has not rotated it${DECLINE:+ (last decline: ${DECLINE})}. bb rotates a coordinator when it is idle; no manual handoff is needed."
        _persist_band
        jq -n --arg msg "$REASON" '{"systemMessage":$msg}'
        exit 0
    fi

    REASON="Context handoff: this coordinator thread is at ~${CONTEXT_TOKENS} tokens of context (threshold ${THRESHOLD}). Run: bb handoff coordinator enable --self --rotate-at ${TARGET}. The value must be at least 2x the thread's seed (${SEED} tokens) or bb declines to rotate; bb then rotates the thread on idle. Do not run bb handoff --replace."
    _persist_band
    jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
    exit 0
fi

REASON="Context handoff (advisory): this thread is at ~${CONTEXT_TOKENS} tokens of context (threshold ${THRESHOLD}). Consider wrapping up or handing the remaining work to a fresh thread."
_persist_band
jq -n --arg msg "$REASON" '{"systemMessage":$msg}'
exit 0
