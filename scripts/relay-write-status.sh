#!/usr/bin/env bash
set -euo pipefail

# Atomically flips a task's status line and touches its heartbeat.
# Usage: relay-write-status.sh <task-id> <PENDING|RUNNING|AWAITING_APPROVAL|BLOCKED|DONE|ERROR|EXPIRED> [message]

task_id="${1:?usage: relay-write-status.sh <task-id> <STATUS> [message]}"
new_status="${2:?usage: relay-write-status.sh <task-id> <STATUS> [message]}"
message="${3:-}"

[[ "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid task-id: ${task_id}" >&2; exit 64; }

base=".agent-relay/${task_id}"
[[ -d "$base" ]] || { echo "no such task: ${task_id}" >&2; exit 1; }

# Same-directory temp file so the rename below is atomic.
tmp=$(mktemp "${base}/.status.XXXXXX")
# mktemp creates 0600; use the normal umask-based mode so others can read it.
chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$tmp"
{
    printf '%s\n' "$new_status"
    [[ -n "$message" ]] && printf '%s\n' "$message"
} > "$tmp"
mv "$tmp" "${base}/status"

touch "${base}/heartbeat"
