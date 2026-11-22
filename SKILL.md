---
name: agent-relay
description: >-
  File-based task relay protocol for coordinating a long-running master process
  (e.g. a Claude Code terminal) with a worker agent (e.g. GitHub Copilot)
  that offloads search/context-finding tasks. Use when you need the master
  to wait on a worker's result without manual polling, when a bash script
  must idle for a long time waiting on a keyword/file change, or when
  designing hand-off protocols between two agent instances that don't share
  memory. Self-contained — copy the `scripts/` folder to any repo.
---

# Agent Relay protocol

A minimal, dependency-free (bash + coreutils only) protocol for two agent
processes — a **master** (long-running orchestrator, e.g. a Claude Code
terminal) and a **worker** (e.g. a Copilot instance) — to hand off tasks and
results through plain files instead of a shared process or socket.

## Task scope

Tasks are **not** limited to read-only work. A worker can do anything it
could do in its own session — search, edit or create files, run commands,
call MCP tools — provided:

- **The worker runs in auto-approve mode** (in VS Code Copilot, tool
  auto-approval turned on), so most commands run without a permission
  prompt. Without it every command stops on a dialog the master can't see;
  `AWAITING_APPROVAL` + `--approval-grace` will surface each one, but the
  loop crawls. The `AWAITING_APPROVAL` rule stays on regardless — under auto
  mode it costs two fast status writes per call and catches whatever still
  isn't auto-approved.
- **`task.md` is the authorization.** Write the scope explicitly: which
  files/repos it may change, and whether anything irreversible or
  outward-facing is allowed (git push, opening/merging PRs, deleting files
  outside the task, deploys, Jira/Slack writes). The worker does what
  `task.md` says; anything irreversible or outward-facing that `task.md`
  doesn't explicitly ask for, it confirms via `BLOCKED` first.
- **Say "read-only" when you mean it.** Research tasks should still state
  it, so a worker in auto mode doesn't "helpfully" fix what it finds.

## Why this exists

Waiting on a background process is (near) free for an agent as long as it
doesn't poll — the harness notifies the agent when the terminal goes idle or
exits. Manual polling ("check every minute to be safe") reintroduces a
per-check token cost that scales with wall-clock time, which defeats the
purpose. This protocol pushes liveness checking into the bash watcher itself
(a watchdog timeout), so neither side needs to babysit the other.

## Roles

- **Master**: creates the task, launches the worker (or waits for it to pick
  up the task), and runs `relay-watch.sh` in the background to block until the
  task completes or stalls. Never polls manually.
- **Worker**: reads `task.md`, does the work, writes the result, then flips
  `status` to `DONE` (or `ERROR`) as its last action.

## File layout

Each task gets its own directory so multiple tasks can run concurrently:

```
.agent-relay/<task-id>/
├── task.md       # written once by the master — the request/instructions
├── status        # line 1: PENDING | RUNNING | AWAITING_APPROVAL | BLOCKED | DONE | ERROR | EXPIRED; line 2+: optional message
├── result.md     # written once by the worker — the payload, only valid once status=DONE
└── heartbeat     # mtime touched on every status write — liveness signal
```

`.agent-relay/` should be gitignored — it's transient coordination state, not a
build artifact.

## Guarantees

- **Atomic writes only.** Every write goes to a temp file in the same
  directory, then `mv` (atomic rename on the same filesystem) replaces the
  target. Readers never observe a partially written `status` or `result.md`.
- **No manual re-polling.** The watchdog timeout in `relay-watch.sh` detects a
  stuck/crashed worker on its own; the master doesn't need a second, separate
  manual check loop.
- **Single source of truth for "done."** Only `status` line 1 matters for
  control flow. Everything else is payload.

## Scripts

All scripts live in `scripts/` and take a `<task-id>` as the first argument.
Run them from the repo root (they operate on `.agent-relay/<task-id>/` relative
to the current directory).

### `relay-init.sh <task-id> <task-description-file-or-'-'>`

Master-side. Creates the task directory, writes `task.md`, sets
`status=PENDING`, then prints one `LISTENER:` line — this decides whether
the human needs to relay anything.

**Task-ids are single-use and restricted** to letters, digits, `.`, `_`, `-`
(starting with a letter or digit). An invalid id exits 64; an id that already
exists exits 65 — pick a new one (e.g. append `-2`). Reusing an id is refused
because a worker still on the old task would write its answer into the new
one, and the master would read it as the new task's result.

- `LISTENER: active ...` → a worker is running the `relay-listen.sh` loop and
  will claim the task on its own. **Don't ask the human to relay.** This is
  the default once a worker loop has been started.
- `LISTENER: busy ...` → every worker is in the middle of another task; this
  one is queued and is claimed when a worker frees up. **Don't relay.** Run
  more workers if tasks queue up often.
- `LISTENER: none` / `stale` → no live loop, even after waiting
  `RELAY_LISTENER_WAIT_SECS` (default 15) for one to appear, so a worker that
  is just starting or just finishing a task isn't misreported. Ask the human to start one —
  in VS Code Copilot that's typing **`/relay-worker`** in a new agent-mode
  chat (see "Persistent worker loop"). Don't hand them a one-shot,
  task-specific prompt: it leaves the worker stopped after one task.

Freshness is judged from `.agent-relay/.listener`, which `relay-listen.sh`
touches on every poll; override the window with `RELAY_LISTENER_FRESH_SECS`
(default 900).

```bash
scripts/relay-init.sh find-tz-usages-1 - <<'EOF'
Read-only. Find every place that builds a date without an explicit timezone
across the api, worker and billing services. Report file:line for each hit.
EOF
```

### `relay-write-status.sh <task-id> <PENDING|RUNNING|AWAITING_APPROVAL|DONE|ERROR|BLOCKED|EXPIRED> [message]`

Worker-side. Atomically flips the status line and touches the heartbeat.
Use `RUNNING` when starting long work, `ERROR` with a short message if the
task can't be completed, `BLOCKED` with a message if the worker needs a
human decision mid-task (see below) — not a failure, just paused.
`AWAITING_APPROVAL` with the tool name as the message immediately before
any tool call that might raise a permission prompt, then `RUNNING` again as
soon as it returns (see `--approval-grace`).

```bash
scripts/relay-write-status.sh find-tz-usages-1 RUNNING
scripts/relay-write-status.sh find-tz-usages-1 BLOCKED "needs approval to run a destructive query - confirm?"
```

### `relay-write-result.sh <task-id> <result-file-or-'-'>`

Worker-side. Atomically writes `result.md`, then flips `status=DONE` as the
final step. This is the normal way a worker finishes a task.

```bash
scripts/relay-write-result.sh find-tz-usages-1 - <<'EOF'
- api: RequestBuilder.java:57 (new GregorianCalendar, no zone)
- worker: DateUtil.java (needs audit, not yet patched)
EOF
```

### `relay-watch.sh <task-id> [--interval SECONDS] [--timeout SECONDS] [--stall-warn SECONDS] [--approval-grace SECONDS] [--unclaimed-warn SECONDS]`

Master-side. Blocks until the task ends or needs attention. Run it as a
background terminal call so the master is notified on exit instead of polling.

| Exit | Meaning | Master's move |
|---|---|---|
| 0 | `DONE` | read `result.md` |
| 1 | watchdog: no progress for `--timeout` (default 300) | tell the human it's stuck |
| 2 | `ERROR` (reason on status line 2) | relay the reason |
| 3 | `BLOCKED` (question on line 2) — immediate | tell the human the worker is asking in its chat |
| 5 | stall: `RUNNING`, no progress for `--stall-warn` (off by default) | tell the human to check the worker; re-run without `--stall-warn` |
| 6 | approval: one `AWAITING_APPROVAL` held past `--approval-grace` (default 15) | name the tool (line 2); re-run with a large grace |
| 7 | unclaimed: `PENDING` past `--unclaimed-warn` (default 30), nobody listening and nobody busy | ask the human to start a worker with `/relay-worker` |
| 8 | `EXPIRED` — a listener skipped it as too old | re-create it under a new id if still wanted |
| 64 | usage error: bad option, invalid task-id, or no such task | fix the command; don't retry it unchanged |

"Progress" means any write to the status file (every write replaces the file,
so the inode/mtime/content signature changes) — not just a different state
word. So a burst of quick announced tool calls counts as progress rather than
one long `AWAITING_APPROVAL`.

The unclaimed check ignores a busy worker (another task `RUNNING` /
`AWAITING_APPROVAL` / `BLOCKED` that progressed within `--timeout`), since a
busy worker isn't listening; a task stuck longer than that counts as
abandoned and doesn't suppress the warning.

```bash
scripts/relay-watch.sh find-tz-usages-1 --interval 5 --timeout 300
```

**Permission prompts.** A chat agent's tool-approval dialog is raised by
the UI *before* the tool runs, and the agent can't ask the UI in advance
whether a given tool is already approved. So the worker announces every
risky call instead: `AWAITING_APPROVAL "<tool>"` right before it, `RUNNING`
right after. The watcher exits 6 only if `AWAITING_APPROVAL` is held longer
than `--approval-grace` (default 15s) — an already-approved tool returns
and clears it in time (no alert), a pending prompt never does. Detection
latency is roughly grace + interval; use `--interval 2` for ~17s. 10s proved too short: a cross-project Jira search legitimately ran longer and raised a false alarm. On exit 6,
tell the human which tool (status line 2) needs approving, then re-run.

`--stall-warn N` (off by default) is the backstop for a worker that forgot
to announce: exits 5 if the task sits at `RUNNING` with no status change for
N seconds. It can't tell a prompt from slow work, so on exit 5 tell the
human to check the worker, then re-run without `--stall-warn` (don't keep
re-alerting on a long task).

### `relay-listen.sh [--interval SECONDS] [--timeout SECONDS] [--max-age SECONDS] [--clear-stop]`

Worker-side. Blocks until any task is `PENDING`, claims the oldest one
(atomic `mkdir .claimed` lock, then flips it to `RUNNING`), prints its
task-id on stdout and exits 0. Exits 1 after `--timeout` seconds (default
300) with no new task — the worker just re-runs it. Exits 4 if the master
has created `.agent-relay/.stop`. See "Persistent worker loop" below.

- `--max-age N` (default 3600, 0 = never): a `PENDING` task older than N
  seconds is marked `EXPIRED` instead of run. Nobody is waiting on it any
  more, and a forgotten write task shouldn't run by surprise when a worker
  starts.
- `--clear-stop`: delete a leftover `.stop` before listening. The worker
  passes it on the **first** listen of a new loop only.

```bash
scripts/relay-listen.sh --interval 5 --timeout 300
```

## Persistent worker loop (relay once, not per task)

Instead of relaying every task-id, the human relays **one** standing
instruction when the worker session starts, and the worker loops on
`relay-listen.sh`:

1. Run `relay-listen.sh` and wait for it to exit.
2. Exit 0 → the printed task-id is claimed and already `RUNNING`. Read
   `.agent-relay/<task-id>/task.md`, do it, finish with `relay-write-result.sh`
   (or `relay-write-status.sh ... ERROR|BLOCKED "msg"`). Go to 1.
3. Exit 1 (idle) → go to 1.
4. Exit 4 (stop) → stop looping and say so.

The master side is unchanged apart from dropping the relay step:
`relay-init.sh` (which will report `LISTENER: active`), then `relay-watch.sh`
in the background. To end the loop, `touch .agent-relay/.stop`. Listeners
leave it in place, so **every** worker listening stops (a worker mid-task
stops after finishing it); the next loop's first listen (`--clear-stop`)
removes it.

Several workers can run at once (e.g. two Copilot chats, each on
`/relay-worker`): the `.claimed` lock gives each task to exactly one. The
lock doesn't stop two tasks from editing the same files — keep parallel
tasks on disjoint files or read-only. `LISTENER: active` means *at least
one* worker is listening, not how many.

The worker's instructions live in **`WORKER.md`** (next to this file) — the
single source of truth for the loop, the `AWAITING_APPROVAL` rule, and what
to do with stale relay prompts. Don't paste ad-hoc loop instructions; point
the worker at that file.

**Starting a worker (VS Code Copilot):** open a new Copilot Chat in agent
mode and type **`/relay-worker`**. That runs the prompt file
`<workspace>/.github/prompts/relay-worker.prompt.md` (generated by
`install.sh`, which can put it elsewhere with `--prompts-dir`), which gives Copilot the workspace and scripts
paths and tells it to read `WORKER.md` and start listening. The master must
run the `relay-*` scripts from that same `<workspace>`. For any other worker,
give it: "Workspace is <workspace>, scripts are <skill>/scripts. Read
<skill>/WORKER.md and follow it exactly, starting the loop now."

Caveat: the loop only lives as long as the worker's chat turn does. Chat
agents typically cap tool calls per turn and/or ask for confirmation before
running terminal commands — the human may need to auto-approve these
scripts and raise the per-turn request limit in the worker's settings, or
the loop will pause on a "continue?" prompt. Run the master's watcher with
`--interval 2 --approval-grace 15 --stall-warn 90`: announced approvals
surface in ~17s, and a worker that forgets to announce is still caught at
90s rather than at the watchdog timeout. The announce rule needs the
`relay-write-status.sh` calls themselves to be auto-approved, or each
announcement becomes its own prompt.

## Worked example (master + worker hand-off)

1. Master runs `relay-init.sh <task-id> -` with the task description and reads
   its `LISTENER:` line. `active`/`busy` → go straight to step 2. `none`/`stale` →
   **stop and ask the human** to relay `<task-id>` (or start the worker
   loop) — see "No cross-process channel" below.
2. Master runs `relay-watch.sh <task-id>` in the background (async) and does
   not poll further — it will be notified on completion or watchdog timeout.
3. Worker reads `.agent-relay/<task-id>/task.md`, optionally writes
   `RUNNING` via `relay-write-status.sh`, does the search/context work, then
   calls `relay-write-result.sh` with the findings as its last step.
4. Master's background call exits (see the exit table under `relay-watch.sh`);
   it reads `result.md` only after confirming `status=DONE`.

## Dispatch pattern for Claude Code (background shell, not a subagent)

**Default: run `relay-watch.sh` as a background shell command** (Bash with
`run_in_background`) straight from the main session. It costs nothing while
it waits — the harness re-invokes you when it exits — and the main context
only ever sees the watcher's one-line exit message and then `result.md`.

Don't dispatch a Claude subagent just to wait: a subagent starts with its own
context (system prompt, instructions) and costs thousands of tokens per task,
which works against the whole point of this skill — saving Claude tokens. It
also can't easily stop mid-task to relay an approval request to the human.

Use a subagent only when you expect a **large `result.md`** that you want
condensed before it enters the main context. Then the subagent runs
`relay-init.sh`, `relay-watch.sh` and reads `result.md` itself, and returns a
summary. If you're already running as a subagent, just do the steps inline.

## Known limitations — ask the human here, don't assume

These are hard boundaries of running as two separate processes (e.g. a
Claude Code terminal and a VS Code Copilot Chat session). Don't try to work
around them automatically — pause and ask the human instead.

- **No cross-process channel.** There is no API or process link between the
  master's process and the worker's chat session beyond this shared
  filesystem. The master cannot "message" the worker directly, and the
  worker cannot be notified that a task exists without a human relaying the
  task-id into its chat — unless a worker is already running the
  persistent `relay-listen.sh` loop. **Trust `relay-init.sh`'s `LISTENER:` line:
  `active`/`busy` mean no relay; `none`/`stale` means stop and ask the human** to
  relay or start the loop, rather than assuming the task will be picked up.
- **No remote context-clear.** If a worker's context window is getting
  large (e.g. many tasks handled in one long-running chat session), the
  master has no way to reset it — there is no "clear context" command
  reachable from outside that chat session. A context reset is a UI-level
  action (starting a new chat) that only the human can perform. **If you
  suspect the worker's context is degraded, ask the human to start a fresh
  worker session** and point it at the last `result.md` (or a memory file)
  for continuity, instead of trying to instruct the worker to clear itself.
- **Human decisions mid-task.** A worker may need a human decision for
  something genuinely ambiguous, or irreversible/outward-facing and not
  explicitly authorized in `task.md` (see "Task scope"). When it
  happens, the worker should **not** silently wait on its own chat's prompt
  alone — that leaves the master's watcher blind until the watchdog times
  out, which reads as "stuck/crashed" rather than "waiting on you". Instead:
  flip `status` to `BLOCKED` with a one-line question as the message
  *before* asking the question in its own chat. `relay-watch.sh` returns
  immediately on `BLOCKED` (exit 3) so the master surfaces it to the human
  right away, without the worker having to route its result through the
  master — the actual Q&A still happens directly in the worker's own chat
  session. Once answered, the worker flips back to `RUNNING` and continues.

## Non-goals

- Not a message queue — one task directory handles one request/response pair.
  For multiple sequential hand-offs, use a new `task-id` each time (or a
  numbered subdirectory convention like `<task-id>/001/`, `<task-id>/002/`).
- Not a replacement for real IPC (sockets/pipes) in latency-sensitive
  contexts — the polling interval (default 5s) sets the floor on responsiveness.
