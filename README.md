# agent-relay — offload Claude Code work to a Copilot worker

A small file-based task **relay** between **Claude Code** (the *master*) and
**GitHub Copilot Chat in VS Code** (the *worker*). Claude writes a task file,
a Copilot chat running in a listen loop picks it up, does the work, and writes
the result back. Claude waits in the background for free and reads only the
result.

Bash + coreutils only. No servers, no sockets, no extensions.

## ⚠️ This is a plan B, not a workflow upgrade

Use it **when you're running low on Claude Code tokens / usage limits** and
want to push as much work as possible onto Copilot, which draws on your
Copilot quota instead. That's the whole point.

If you have Claude budget to spare, **don't use this** — Claude Code's own
subagents are faster, need no second app, no human in the loop for
approvals, and share Claude's tooling directly. agent-relay adds a hop, a
second model, and a human who occasionally has to click "Allow".

### Where the savings actually come from

| Claude still pays for | Claude no longer pays for |
|---|---|
| writing `task.md` | raw tool output — search hits, file contents, API/MCP JSON |
| reading `result.md` | the work loop itself (Copilot's reasoning and tool calls) |
| any verification you ask it to do | waiting — the watcher runs in the background and notifies on exit |

So it pays off most on **big input, small output** tasks:

- Good fit: cross-repo searches, "find every X", Jira / GitHub lookups,
  summarising logs or long files, mechanical edits with a clear spec.
- Poor fit: back-and-forth design work, tasks where Claude has to see the
  raw data anyway, anything you'd have to fully re-verify (re-verifying
  re-spends the tokens you were trying to save).

Copilot's answers are another model's answers — spot-check what matters.

## See it run

[`docs/index.html`](docs/index.html) is an animated diagram of one full run:
two workers sharing a queue, an approval announcement, an `ERROR`, and the
stop signal. Open it in a browser. It's a single file with no build step.

## How it works

```
  Claude Code (master)                         Copilot Chat (worker)
  ────────────────────                         ─────────────────────
  relay-init.sh <id>  ──▶ .agent-relay/<id>/task.md
                        .agent-relay/<id>/status = PENDING
                                               relay-listen.sh (looping)
                                                 sees PENDING, claims it
                        status = RUNNING   ◀──   prints <id>
                                               reads task.md, does the work
                        status = AWAITING_APPROVAL ◀── before risky tool calls
                        status = RUNNING           ◀── after they return
                        result.md, status = DONE ◀── relay-write-result.sh
  relay-watch.sh <id> (background) exits 0
  reads result.md                              back to relay-listen.sh
```

- **No relay per task.** Once `/relay-worker` is running, Copilot claims new
  tasks on its own. `relay-init.sh` tells Claude whether a listener is live
  (`LISTENER: active`), or that every worker is busy and the task is queued
  (`LISTENER: busy`), via a heartbeat file.
- **Approval prompts surface.** VS Code's "Allow?" dialogs are invisible to
  Claude, so Copilot announces risky calls first (`AWAITING_APPROVAL`). If
  that state sticks for 15s, Claude's watcher exits and Claude tells you
  which tool is waiting.
- **Nothing hangs silently.** If no worker picks a task up within 30s, Claude
  says so. Stall warning at 90s of no progress, watchdog at the timeout.
- **Forgotten tasks don't run by surprise.** A task left unclaimed for over
  an hour is marked `EXPIRED` instead of being run when a worker next starts.

## Requirements

- macOS or Linux, bash
- Claude Code
- VS Code with GitHub Copilot Chat (Agent mode)
- Both running on the **same machine**, against the **same folder**

## Setup

Put this folder anywhere you like, then run the installer from your
workspace — the folder you'll **open in VS Code and run Claude Code from**
(task files go in `<workspace>/.agent-relay/`):

```bash
cd ~/path/to/workspace
/path/to/agent-relay/install.sh            # all defaults
```

Every path has a default and every default can be changed, with a flag or
an environment variable:

| What | Default | Flag | Env var |
|---|---|---|---|
| Workspace | current directory | first argument | `AGENT_RELAY_WORKSPACE` |
| Skill location | `~/.claude/skills` (`--scope user`) | `--scope project` → `<workspace>/.claude/skills`, or `--skills-dir DIR` | `AGENT_RELAY_SCOPE`, `AGENT_RELAY_SKILLS_DIR` |
| Install mode | `link` (symlink; updates with the folder) | `--mode copy` (self-contained) | `AGENT_RELAY_MODE` |
| `/relay-worker` prompt | `<workspace>/.github/prompts` | `--prompts-dir DIR` | `AGENT_RELAY_PROMPTS_DIR` |

```bash
./install.sh ~/code/my-app --scope project --mode copy   # commit it with the project
AGENT_RELAY_SKILLS_DIR=~/dotfiles/claude/skills ./install.sh ~/code/my-app
./install.sh --dry-run                                   # preview, change nothing
./install.sh --help
```

`install.sh`:
1. installs the skill as `<skills-dir>/agent-relay` (refuses to clobber
   anything that isn't agent-relay; `--force` to switch link ↔ copy or repoint
   a link), and
2. writes `relay-worker.prompt.md` — the `/relay-worker` command, with your
   paths filled in. Paths with spaces are fine.

It **doesn't** touch your settings or `.gitignore`; it prints what to add:

1. **`.gitignore`** (if the workspace is a repo): `.agent-relay/`
2. **Auto-approve the relay scripts** in VS Code `settings.json`, under
   `"chat.tools.terminal.autoApprove"`:
   ```json
   "/agent-relay\\/scripts\\/relay-(listen|write-status|write-result)\\.sh\\b/": true
   ```
   Without this every listen and status write asks for approval and the loop
   crawls. For MCP tools the worker uses often (Jira, GitHub), pick
   **"Always allow"** the first time Copilot asks.
3. Optionally raise Copilot's per-turn request limit in VS Code settings, so
   the loop doesn't pause on "Continue?" after many tasks.

Re-run `install.sh` any time; it's idempotent.

## Using it

1. **Start the worker:** open `<workspace>` in VS Code → new Copilot Chat →
   **Agent** mode → type **`/relay-worker`**. Copilot's terminal will sit in
   `relay-listen.sh` — that's it listening.
2. **In Claude Code** (started from `<workspace>`), just ask:
   > use agent-relay to have copilot find all my Jira tickets this sprint

   Claude writes the task, sees `LISTENER: active`, and waits in the
   background. You'll hear back when it's done — or when Copilot needs you
   to approve something, in which case Claude names the tool.
3. **Stop the loop:** ask Claude to stop it (it creates `.agent-relay/.stop`),
   and every running worker replies "agent-relay loop stopped" (one mid-task
   finishes the task first). The next `/relay-worker` clears the stop file.

You can run **two or more workers** (one `/relay-worker` per Copilot chat);
each task goes to exactly one of them. Keep parallel tasks off the same
files, since nothing locks files across tasks.

If Copilot's chat gets long and sluggish, stop it and start a fresh chat with
`/relay-worker` — only the human can reset a worker's context.

## Gotchas

- **One-shot prompts stop the loop.** Always start workers with
  `/relay-worker`, never by pasting "do task X" — that leaves Copilot idle
  after one task.
- **A stale heartbeat isn't always a dead loop.** The heartbeat only ticks
  while Copilot is *waiting*; it goes quiet while it works a task and for a
  few seconds after. Only "stale for 30s+ with no task RUNNING" means the
  loop stopped.
- **Slow tools can look like pending approvals.** Grace is 15s; raise it
  with `relay-watch.sh --approval-grace N` if your tools are slower.
- **Say "read-only" when you mean it** in task descriptions, and state
  scope explicitly for anything that writes.
- **Task-ids are single-use.** Letters, digits, `.`, `_`, `-` only;
  `relay-init.sh` refuses an id that already exists (reusing one could hand an
  old answer to a new task).
- **Don't put the workspace in a synced or shared folder.** Anything that can
  write to `.agent-relay/` can hand Copilot instructions.
- **An idle loop still costs Copilot requests.** The listener exits every 5
  minutes and Copilot re-runs it, which counts toward its per-turn request
  limit — eventually the loop pauses on "Continue?".

## Repo layout

```
SKILL.md                     Claude Code skill: the protocol + master-side playbook
WORKER.md                    Copilot's instructions (the loop, approvals, stale prompts)
prompts/relay-worker.prompt.md.tmpl   template for the /relay-worker command
install.sh                   per-workspace installer
scripts/
  relay-init.sh                master: create a task, report listener state
  relay-watch.sh               master: block until done, or warn (approval/stall/unclaimed)
  relay-listen.sh              worker: wait for and claim the next PENDING task
  relay-write-status.sh        worker: atomic status flip
  relay-write-result.sh        worker: atomic result write + DONE
tests/run-tests.sh           exercises every exit path (no Copilot needed)
```

## Tests

```bash
./tests/run-tests.sh      # ~1 min, runs in a temp dir, never touches your real ~/.claude
```

## Uninstall

Run the installer with `--uninstall` and the same options you installed
with. It removes the skill and the prompt file, and only if they're
agent-relay's:

```bash
./install.sh ~/code/my-app --scope project --uninstall
rm -rf ~/code/my-app/.agent-relay          # task files, if you want them gone too
```
