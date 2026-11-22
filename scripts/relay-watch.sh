#!/usr/bin/env bash
set -uo pipefail

# Blocks until a task reaches DONE/ERROR/BLOCKED/EXPIRED, or trips an early
# warning or the watchdog. Meant to be run by the master process (e.g. via an
# async terminal call) so it gets notified on exit instead of polling manually.
#
# "Progress" is any write to the status file, not just a change of state
# word: every relay-write-status.sh call replaces the file (new inode, mtime,
# content), so RUNNING -> AWAITING_APPROVAL -> RUNNING between two polls still
# counts as progress.
#
# Usage: relay-watch.sh <task-id> [--interval SECONDS] [--timeout SECONDS]
#                    [--stall-warn SECONDS] [--approval-grace SECONDS]
#                    [--unclaimed-warn SECONDS]
# Exit codes: 0 = DONE
#             1 = watchdog: no progress for --timeout seconds (default 300)
#             2 = ERROR (message on status line 2)
#             3 = BLOCKED - worker needs a human decision (message on line 2)
#             5 = stall warning: RUNNING with no progress for --stall-warn
#                 seconds (default 0 = off) - the worker may be on a UI
#                 permission prompt it didn't announce; re-run to keep watching
#             6 = approval needed: one AWAITING_APPROVAL held longer than
#                 --approval-grace (default 15) - the tool on line 2 is on a
#                 permission prompt; re-run to keep watching
#             7 = unclaimed: still PENDING after --unclaimed-warn seconds
#                 (default 30, 0 = off) while no worker is listening and none
#                 is busy on another task - the worker loop is probably down
#             8 = EXPIRED - a listener skipped it for being too old
#             64 = usage error

task_id="${1:?usage: relay-watch.sh <task-id> [--interval N] [--timeout N]}"
shift

interval=5
timeout=300
stall_warn=0
approval_grace=15
unclaimed_warn=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) interval="$2"; shift 2 ;;
        --timeout) timeout="$2"; shift 2 ;;
        --stall-warn) stall_warn="$2"; shift 2 ;;
        --approval-grace) approval_grace="$2"; shift 2 ;;
        --unclaimed-warn) unclaimed_warn="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

[[ "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid task-id: ${task_id}" >&2; exit 64; }

if stat --version >/dev/null 2>&1; then
    signature() { stat -c '%i:%Y' "$1" 2>/dev/null; cat "$1" 2>/dev/null; }
    mtime() { stat -c %Y "$1"; }
else
    signature() { stat -f '%i:%m' "$1" 2>/dev/null; cat "$1" 2>/dev/null; }
    mtime() { stat -f %m "$1"; }
fi

root=".agent-relay"
base="${root}/${task_id}"
status_file="${base}/status"

[[ -d "$base" ]] || { echo "no such task: ${task_id}" >&2; exit 64; }

# True if some OTHER task is being worked on - a busy worker isn't listening,
# so a stale .listener heartbeat doesn't mean the loop is down. A task that
# hasn't progressed within --timeout is treated as abandoned (e.g. the worker
# crashed mid-task), so it can't suppress the warning forever.
other_task_active() {
    local f now
    now=$(date +%s)
    for f in "${root}"/*/status; do
        [[ "$f" == "$status_file" ]] && continue
        case "$(head -n1 "$f" 2>/dev/null)" in
            RUNNING|AWAITING_APPROVAL|BLOCKED)
                (( now - $(mtime "$f") <= timeout )) && return 0 ;;
        esac
    done
    return 1
}

last_sig=""
last_change=$(date +%s)

while true; do
    sig="$(signature "$status_file")"
    if [[ "$sig" != "$last_sig" ]]; then
        last_sig="$sig"
        last_change=$(date +%s)
    fi
    current=$(head -n1 "$status_file" 2>/dev/null || echo "")

    case "$current" in
        DONE)
            echo "task ${task_id}: DONE"
            exit 0
            ;;
        ERROR)
            echo "task ${task_id}: ERROR"
            sed -n '2p' "$status_file" >&2 || true
            exit 2
            ;;
        BLOCKED)
            # Not a failure or a stall - the worker is alive and waiting on a
            # human decision. Return immediately rather than waiting out the
            # watchdog, so the master can surface this to the human right away.
            echo "task ${task_id}: BLOCKED - needs human input"
            sed -n '2p' "$status_file" >&2 || true
            exit 3
            ;;
        EXPIRED)
            echo "task ${task_id}: EXPIRED - not claimed in time, skipped"
            sed -n '2p' "$status_file" >&2 || true
            exit 8
            ;;
    esac

    now=$(date +%s)
    idle=$(( now - last_change ))

    # The worker writes AWAITING_APPROVAL just before any tool that might
    # prompt, and RUNNING as soon as it returns. An already-approved tool
    # clears it within the grace period; a pending prompt never does.
    if [[ "$current" == "AWAITING_APPROVAL" ]] && (( idle > approval_grace )); then
        echo "task ${task_id}: APPROVAL NEEDED - worker is waiting on a permission prompt"
        sed -n '2p' "$status_file" >&2 || true
        exit 6
    fi

    # Backstop for a worker that skipped AWAITING_APPROVAL: a tool-approval
    # dialog appears before the tool runs, so it just looks like RUNNING.
    if [[ "$current" == "RUNNING" ]] && (( stall_warn > 0 && idle > stall_warn )); then
        echo "task ${task_id}: STALL WARNING - RUNNING for ${stall_warn}s with no progress; check the worker for a pending permission prompt" >&2
        exit 5
    fi

    if [[ "$current" == "PENDING" ]] && (( unclaimed_warn > 0 && idle > unclaimed_warn )); then
        hb_age=999999
        [[ -e "${root}/.listener" ]] && hb_age=$(( now - $(mtime "${root}/.listener") ))
        if (( hb_age > unclaimed_warn )) && ! other_task_active; then
            echo "task ${task_id}: UNCLAIMED - PENDING for ${idle}s, no worker listening (heartbeat ${hb_age}s old) and none busy; start one with /relay-worker" >&2
            exit 7
        fi
    fi

    if (( idle > timeout )); then
        echo "task ${task_id}: WATCHDOG - no progress in ${timeout}s (stuck at '${current}')" >&2
        exit 1
    fi

    sleep "$interval"
done
