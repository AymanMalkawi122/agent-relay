#!/usr/bin/env bash
set -euo pipefail

# agent-relay installer. Every path has a default, and every default can be
# overridden with a flag or an environment variable - where things go is up
# to each developer. Run ./install.sh --help for the options.

usage() {
    cat <<'EOF'
Usage: ./install.sh [options] [workspace]

Installs agent-relay for one workspace:
  1. makes the skill visible to Claude Code (the master)
  2. writes the /relay-worker prompt file for Copilot (the worker)
It never edits your settings or .gitignore - it prints what to add.

Arguments:
  workspace              the folder you open in VS Code AND run Claude Code
                         from; task files go in <workspace>/.agent-relay/
                         default: $AGENT_RELAY_WORKSPACE, else the current directory

Options (each one can also be set with the environment variable in brackets):
  --scope user|project   where Claude Code finds the skill      [AGENT_RELAY_SCOPE]
                           user     ~/.claude/skills - every project (default)
                           project  <workspace>/.claude/skills - this project only
  --skills-dir DIR       install into DIR instead; overrides --scope
                                                                 [AGENT_RELAY_SKILLS_DIR]
  --mode link|copy       link: symlink this folder, so a git pull updates it (default)
                         copy: self-contained copy; re-run install to update
                                                                 [AGENT_RELAY_MODE]
  --prompts-dir DIR      where relay-worker.prompt.md is written
                         default: <workspace>/.github/prompts    [AGENT_RELAY_PROMPTS_DIR]
  --force                replace an existing agent-relay install at the target
  --dry-run              show what would happen, change nothing
  --uninstall            remove what install created (pass the same options)
  -h, --help             show this help

Examples:
  ./install.sh                                      # current dir, user scope, symlink
  ./install.sh ~/code/my-app --scope project --mode copy
  AGENT_RELAY_SKILLS_DIR=~/dotfiles/claude/skills ./install.sh ~/code/my-app
EOF
}

die() { echo "error: $*" >&2; exit 1; }
stop() { echo "STOP  $*" >&2; exit 1; }
need_val() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value (see --help)"; }

# Expand a leading ~ (from env vars or quoted args) and make a path absolute.
abs_path() {
    local p="$1"
    [[ "$p" == "~" || "$p" == "~/"* ]] && p="${HOME}${p:1}"
    [[ "$p" == /* ]] || p="${PWD}/${p}"
    printf '%s' "$p"
}

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

workspace="${AGENT_RELAY_WORKSPACE:-}"
scope="${AGENT_RELAY_SCOPE:-user}"
skills_dir="${AGENT_RELAY_SKILLS_DIR:-}"
mode="${AGENT_RELAY_MODE:-link}"
prompts_dir="${AGENT_RELAY_PROMPTS_DIR:-}"
force=0
dry=0
uninstall=0
workspace_arg=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope)       need_val "$@"; scope="$2"; shift 2 ;;
        --skills-dir)  need_val "$@"; skills_dir="$2"; shift 2 ;;
        --mode)        need_val "$@"; mode="$2"; shift 2 ;;
        --prompts-dir) need_val "$@"; prompts_dir="$2"; shift 2 ;;
        --force)       force=1; shift ;;
        --dry-run)     dry=1; shift ;;
        --uninstall)   uninstall=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "unknown option: $1 (see --help)" ;;
        *)             [[ -z "$workspace_arg" ]] || die "only one workspace can be given"
                       workspace_arg="$1"; shift ;;
    esac
done

[[ -n "$workspace_arg" ]] && workspace="$workspace_arg"
workspace="$(abs_path "${workspace:-$PWD}")"
[[ -d "$workspace" ]] || die "workspace is not a directory: $workspace"
workspace="$(cd "$workspace" && pwd)"

case "$scope" in user|project) ;; *) die "--scope must be 'user' or 'project', got '$scope'" ;; esac
case "$mode"  in link|copy)    ;; *) die "--mode must be 'link' or 'copy', got '$mode'" ;; esac

if [[ -z "$skills_dir" ]]; then
    if [[ "$scope" == project ]]; then skills_dir="${workspace}/.claude/skills"
    else skills_dir="${HOME}/.claude/skills"; fi
fi
skills_dir="$(abs_path "$skills_dir")"
prompts_dir="$(abs_path "${prompts_dir:-${workspace}/.github/prompts}")"

dest="${skills_dir}/agent-relay"
prompt="${prompts_dir}/relay-worker.prompt.md"

# The prompt file embeds these paths in a markdown link, so they can't hold
# characters that would break it. Spaces are fine.
for p in "$workspace" "$dest"; do
    case "$p" in
        *$'\n'*|*'<'*|*'>'*|*'`'*) die "path contains a newline, '<', '>' or backtick, which the prompt file can't hold: $p" ;;
    esac
done

run() {
    if (( dry )); then printf 'would run:'; printf ' %q' "$@"; printf '\n'
    else "$@"; fi
}

# A directory is "ours" if it holds the agent-relay SKILL.md. Only those are
# ever deleted or replaced.
is_ours() { [[ -f "$1/SKILL.md" ]] && grep -qx 'name: agent-relay' "$1/SKILL.md"; }
# True if $1 is this source folder itself (not a link to it).
is_source() { [[ -d "$1" && ! -L "$1" && "$(cd "$1" && pwd -P)" == "$src_dir" ]]; }

(( dry )) && echo "dry run - nothing will be changed"

# ---------------------------------------------------------------- uninstall
if (( uninstall )); then
    if [[ -L "$dest" ]]; then
        run rm "$dest"; echo "removed skill link: $dest"
    elif is_source "$dest"; then
        echo "skip  $dest is the agent-relay source folder itself - not deleting it"
    elif [[ -d "$dest" ]]; then
        is_ours "$dest" || stop "$dest doesn't look like agent-relay - not removing it"
        run rm -rf "$dest"; echo "removed skill copy: $dest"
    else
        echo "none  no skill at $dest"
    fi
    if [[ -f "$prompt" ]]; then
        grep -q 'agent-relay' "$prompt" || stop "$prompt wasn't written by agent-relay - not removing it"
        run rm "$prompt"; echo "removed prompt file: $prompt"
    else
        echo "none  no prompt file at $prompt"
    fi
    echo
    echo "Task files were left alone. To delete them too:"
    printf '  rm -rf %q\n' "${workspace}/.agent-relay"
    exit 0
fi

# ---------------------------------------------------------------- 1. skill
run chmod +x "${src_dir}"/scripts/*.sh
run mkdir -p "$skills_dir"

if is_source "$dest"; then
    echo "ok    skill already lives at $dest"
elif [[ "$mode" == link ]]; then
    if [[ -L "$dest" ]]; then
        current="$(readlink "$dest")"
        if [[ "$current" == "$src_dir" ]]; then
            echo "ok    skill link already points here: $dest"
        elif (( force )); then
            run ln -sfn "$src_dir" "$dest"
            echo "fixed skill link (was -> $current): $dest -> $src_dir"
        else
            stop "$dest already points to $current - re-run with --force to repoint it here"
        fi
    elif [[ -e "$dest" ]]; then
        is_ours "$dest" || stop "$dest exists and isn't agent-relay - move it aside first"
        (( force )) || stop "$dest is a copied install - re-run with --force to replace it with a link"
        run rm -rf "$dest"
        run ln -s "$src_dir" "$dest"
        echo "replaced skill copy with link: $dest -> $src_dir"
    else
        run ln -s "$src_dir" "$dest"
        echo "added skill link: $dest -> $src_dir"
    fi
else
    if [[ -L "$dest" ]]; then
        (( force )) || stop "$dest is a symlink - re-run with --force to replace it with a copy"
        run rm "$dest"
    elif [[ -e "$dest" ]]; then
        is_ours "$dest" || stop "$dest exists and isn't agent-relay - move it aside first"
        run rm -rf "$dest"    # an earlier copy: refresh it
    fi
    run mkdir -p "$dest"
    run cp -R "${src_dir}/SKILL.md" "${src_dir}/WORKER.md" "${src_dir}/README.md" \
        "${src_dir}/scripts" "${src_dir}/prompts" "$dest/"
    echo "copied skill to: $dest"
fi

# ---------------------------------------------------------------- 2. prompt
# Plain string replacement, not sed: paths may contain '|', '&' or spaces.
shopt -u patsub_replacement 2>/dev/null || true
tmpl="$(<"${src_dir}/prompts/relay-worker.prompt.md.tmpl")"
rendered="${tmpl//\{\{WORKSPACE\}\}/$workspace}"
rendered="${rendered//\{\{SKILL_DIR\}\}/$dest}"

if [[ -f "$prompt" ]] && [[ "$(<"$prompt")" == "$rendered" ]]; then
    echo "ok    prompt file up to date: $prompt"
else
    if [[ -f "$prompt" ]]; then
        run cp "$prompt" "${prompt}.bak"
        echo "note  backed up previous prompt file to ${prompt}.bak"
    fi
    run mkdir -p "$prompts_dir"
    if (( dry )); then echo "would write: $prompt"
    else printf '%s\n' "$rendered" > "$prompt"; echo "wrote prompt file: $prompt"; fi
fi

# ---------------------------------------------------------------- warnings
case "$workspace" in
    /mnt/[a-z]/*)
        echo
        echo "warn  $workspace is on a Windows drive under WSL. Run VS Code connected"
        echo "      to WSL so Copilot's terminal is bash, and prefer a folder in your"
        echo "      Linux home - file access under /mnt is slow." ;;
esac
case "$workspace" in
    *OneDrive*|*Dropbox*|*"Google Drive"*|*iCloud*|*CloudStorage*)
        echo
        echo "warn  $workspace looks like a synced folder. Anything that can write to"
        echo "      .agent-relay/ can hand Copilot instructions - use a local folder." ;;
esac
if [[ "$mode" == link && "$dest" == "$workspace"/* ]]; then
    echo
    echo "note  the skill link inside the workspace points at $src_dir on this"
    echo "      machine. Don't commit it; use --mode copy if the team should share it."
fi

cat <<EOF

Done. Remaining manual steps:

  a) If the workspace is a git repo, add this line to its .gitignore:
       .agent-relay/

  b) Recommended: auto-approve the relay scripts in VS Code settings.json
     (otherwise every listen/status write asks for approval). Merge into
     "chat.tools.terminal.autoApprove":
       "/agent-relay\\\\/scripts\\\\/relay-(listen|write-status|write-result)\\\\.sh\\\\b/": true

  c) Start the worker: open ${workspace} in VS Code, new Copilot Chat,
     Agent mode, type:  /relay-worker

  d) Run Claude Code from ${workspace} and ask it to use the agent-relay skill.
EOF
