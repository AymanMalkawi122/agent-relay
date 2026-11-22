#!/usr/bin/env bash
set -euo pipefail

# Initializes a new agent-relay task directory, then reports whether a worker
# is running the relay-listen.sh loop (fresh .agent-relay/.listener heartbeat).
# Usage: relay-init.sh <task-id> <task-description-file-or-'-'>
#   <task-id>: letters, digits, '.', '_', '-'; must start with a letter or
#   digit, and must not already exist - task-ids are single-use (reusing one
#   would hand a worker's old answer to the new task).
# Env: RELAY_LISTENER_FRESH_SECS (default 900) - how recent the heartbeat must
#      be. The heartbeat goes quiet while the worker is busy on a task, so
#      keep this above the listener's --timeout plus a typical task length.
#      RELAY_LISTENER_WAIT_SECS (default 15) - if no worker is seen right away,
#      keep checking this long before reporting none/stale (0 = don't wait).
# Prints one LISTENER line: active | busy (no relay needed) or none | stale.

task_id="${1:?usage: relay-init.sh <task-id> <task-description-file-or-'-'>}"
desc_src="${2:?usage: relay-init.sh <task-id> <task-description-file-or-'-'>}"

[[ "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "invalid task-id '${task_id}': use letters, digits, '.', '_', '-' (starting with a letter or digit)" >&2
    exit 64
}

if stat --version >/dev/null 2>&1; then mtime() { stat -c %Y "$1"; }
else mtime() { stat -f %m "$1"; }; fi

base=".agent-relay/${task_id}"
mkdir -p .agent-relay
# Plain mkdir fails if the directory exists - that's the single-use check.
mkdir "$base" 2>/dev/null || {
    echo "task-id '${task_id}' already exists - pick a new one (e.g. ${task_id}-2)" >&2
    exit 65
}

if [[ "$desc_src" == "-" ]]; then
    cat > "${base}/task.md"
else
    cp "$desc_src" "${base}/task.md"
fi

# Atomic init: write to a temp file in the same dir, then rename. Status is
# written last, so a PENDING status implies task.md is complete.
tmp=$(mktemp "${base}/.status.XXXXXX")
# mktemp creates 0600; use the normal umask-based mode so others can read it.
chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$tmp"
printf 'PENDING\n' > "$tmp"
mv "$tmp" "${base}/status"

: > "${base}/heartbeat"

echo "Task initialized at ${base}"

fresh="${RELAY_LISTENER_FRESH_SECS:-900}"
wait_secs="${RELAY_LISTENER_WAIT_SECS:-15}"
hb=".agent-relay/.listener"

# A worker busy on another task isn't touching the heartbeat, but it will
# pick this task up when it finishes. Counts tasks that progressed recently.
busy_count() {
    local f n=0 now
    now=$(date +%s)
    for f in .agent-relay/*/status; do
        [[ -e "$f" && "$f" != "${base}/status" ]] || continue
        case "$(head -n1 "$f" 2>/dev/null)" in
            RUNNING|AWAITING_APPROVAL|BLOCKED)
                (( now - $(mtime "$f") <= fresh )) && n=$((n + 1)) ;;
        esac
    done
    echo "$n"
}

# Report as soon as a worker is seen. If none is, keep checking for up to
# RELAY_LISTENER_WAIT_SECS: a worker that is just starting, or just finishing a
# task, shows up within seconds, and saying "none" then would make the master
# interrupt the human for nothing.
deadline=$(( $(date +%s) + wait_secs ))
while true; do
    if [[ -e "$hb" ]]; then
        age=$(( $(date +%s) - $(mtime "$hb") ))
        if (( age <= fresh )); then
            echo "LISTENER: active (heartbeat ${age}s ago) - no relay needed"
            exit 0
        fi
    fi
    busy=$(busy_count)
    if (( busy > 0 )); then
        echo "LISTENER: busy (${busy} task(s) in progress) - no relay needed; the task is queued and runs when a worker frees up"
        exit 0
    fi
    (( $(date +%s) >= deadline )) && break
    sleep 1
done

if [[ -e "$hb" ]]; then
    echo "LISTENER: stale (heartbeat ${age:-?}s ago, checked for ${wait_secs}s) - relay the task-id or restart the worker loop"
else
    echo "LISTENER: none (checked for ${wait_secs}s) - relay the task-id or start the worker loop"
fi
