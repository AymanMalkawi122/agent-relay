#!/usr/bin/env bash
set -uo pipefail

# Worker-side counterpart to relay-watch.sh. Blocks until a PENDING task
# appears, claims it (flips it to RUNNING), prints its task-id on stdout and
# exits - so a worker can loop: listen -> do task -> write result -> listen.
# Oldest PENDING task (by status mtime) is claimed first. Claiming uses an
# atomic mkdir lock, so two workers listening at once never take the same task.
#
# Usage: relay-listen.sh [--interval SECONDS] [--timeout SECONDS]
#                      [--max-age SECONDS] [--clear-stop]
#   --max-age     PENDING tasks older than this are marked EXPIRED instead of
#                 run (default 3600, 0 = never) - nobody is waiting on them any
#                 more, and a forgotten write task shouldn't run by surprise.
#   --clear-stop  delete a leftover .agent-relay/.stop before listening. Pass it
#                 on the FIRST listen of a new worker loop only.
# While waiting it touches .agent-relay/.listener every poll, so relay-init.sh can
# tell the master a worker loop is live and no manual relay is needed.
#
# Exit codes: 0 = claimed a task (id on stdout), 1 = idle timeout with no new
#             task (just re-run to keep listening), 4 = stop requested by the
#             master (.agent-relay/.stop exists; left in place so every worker
#             listening stops - the next loop's --clear-stop removes it),
#             64 = usage error

interval=5
timeout=300
max_age=3600
clear_stop=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) interval="$2"; shift 2 ;;
        --timeout) timeout="$2"; shift 2 ;;
        --max-age) max_age="$2"; shift 2 ;;
        --clear-stop) clear_stop=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

if stat --version >/dev/null 2>&1; then mtime() { stat -c %Y "$1"; }
else mtime() { stat -f %m "$1"; }; fi

root=".agent-relay"
mkdir -p "$root"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
started=$(date +%s)

(( clear_stop )) && rm -f "${root}/.stop"

while true; do
    if [[ -e "${root}/.stop" ]]; then
        rm -f "${root}/.listener"
        echo "STOP requested by master" >&2
        exit 4
    fi

    touch "${root}/.listener"

    # ls -tr: oldest status first. Status is written last by relay-init.sh, so
    # a PENDING status implies task.md is already complete.
    while IFS= read -r status_file; do
        [[ "$(head -n1 "$status_file" 2>/dev/null)" == "PENDING" ]] || continue
        base="$(dirname "$status_file")"
        task_id="$(basename "$base")"
        [[ "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
        mkdir "${base}/.claimed" 2>/dev/null || continue
        age=$(( $(date +%s) - $(mtime "$status_file") ))
        if (( max_age > 0 && age > max_age )); then
            "${script_dir}/relay-write-status.sh" "$task_id" EXPIRED "not claimed within ${max_age}s (waited ${age}s); skipped by listener"
            continue
        fi
        "${script_dir}/relay-write-status.sh" "$task_id" RUNNING "claimed by listener"
        echo "$task_id"
        exit 0
    done < <(ls -tr "${root}"/*/status 2>/dev/null)

    if (( $(date +%s) - started > timeout )); then
        echo "IDLE - no new task in ${timeout}s, re-run to keep listening" >&2
        exit 1
    fi

    sleep "$interval"
done
