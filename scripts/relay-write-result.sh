#!/usr/bin/env bash
set -euo pipefail

# Atomically writes the task result payload, then flips status to DONE.
# Usage: relay-write-result.sh <task-id> <result-file-or-'-'>

task_id="${1:?usage: relay-write-result.sh <task-id> <result-file-or-'-'>}"
result_src="${2:?usage: relay-write-result.sh <task-id> <result-file-or-'-'>}"

[[ "$task_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid task-id: ${task_id}" >&2; exit 64; }

base=".agent-relay/${task_id}"
[[ -d "$base" ]] || { echo "no such task: ${task_id}" >&2; exit 1; }

tmp=$(mktemp "${base}/.result.XXXXXX")
# mktemp creates 0600; give the file the normal umask-based mode instead so
# a worker or master running as another user can read it.
chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$tmp"
if [[ "$result_src" == "-" ]]; then
    cat > "$tmp"
else
    cp "$result_src" "$tmp"
fi
mv "$tmp" "${base}/result.md"

# Status flip must be the last step — it's the signal the result is ready.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${script_dir}/relay-write-status.sh" "$task_id" DONE
