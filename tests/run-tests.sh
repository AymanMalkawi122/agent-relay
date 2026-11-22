#!/usr/bin/env bash
set -uo pipefail

# Exercises every script exit path in a throwaway directory. No network, no
# Copilot - just the file protocol. Run from anywhere: ./tests/run-tests.sh

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T"
umask 022
export RELAY_LISTENER_WAIT_SECS=0    # don't wait for a worker unless a test asks

pass=0 fail=0
check() { # check <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"
    else fail=$((fail+1)); echo "FAIL $1 (expected '$2', got '$3')"; fi
}
q() { "$@" >/dev/null 2>&1; echo $?; }
L() { "$S/relay-listen.sh" --interval 1 "$@"; }

# --- init: listener detection, id validation, single-use ids
out="$("$S/relay-init.sh" a - <<<task)"
check "init: no listener"             "LISTENER: none"   "$(grep -o 'LISTENER: none' <<<"$out")"
check "init: status PENDING"          "PENDING"          "$(head -n1 .agent-relay/a/status)"
check "init: reused id refused"       "65"               "$(q "$S/relay-init.sh" a - <<<again)"
check "init: reuse left task intact"  "task"             "$(cat .agent-relay/a/task.md)"
check "init: id with space refused"   "64"               "$(q "$S/relay-init.sh" "has space" - <<<x)"
check "init: ../ id refused"          "64"               "$(q "$S/relay-init.sh" "../escaped" - <<<x)"
check "init: nothing escaped"         "no"               "$([[ -e escaped ]] && echo yes || echo no)"
check "init: dot-leading id refused"  "64"               "$(q "$S/relay-init.sh" .stop - <<<x)"
check "write-status: bad id refused"  "64"               "$(q "$S/relay-write-status.sh" "../a" RUNNING)"

# --- listen: claims oldest first, never twice
sleep 1; "$S/relay-init.sh" b - <<<task >/dev/null
check "listen: claims oldest"         "a"                "$(L --timeout 2 2>/dev/null)"
check "listen: marks RUNNING"         "RUNNING"          "$(head -n1 .agent-relay/a/status)"
check "listen: next is b"             "b"                "$(L --timeout 2 2>/dev/null)"
check "listen: idle exit 1"           "1"                "$(q L --timeout 2)"
out="$("$S/relay-init.sh" c - <<<task)"
check "init: listener active"         "LISTENER: active" "$(grep -o 'LISTENER: active' <<<"$out")"

# --- listen: two listeners race for one task - exactly one wins
L --timeout 4 >l1 2>/dev/null &
L --timeout 4 >l2 2>/dev/null &
wait
check "listen: race has one winner"   "c"                "$(cat l1 l2)"

# --- listen: stale PENDING is expired, not run; fresh one is claimed
"$S/relay-init.sh" forgotten - <<<old >/dev/null; touch -t 202601010000 .agent-relay/forgotten/status
"$S/relay-init.sh" fresh - <<<new >/dev/null
check "listen: skips stale, claims fresh" "fresh"        "$(L --timeout 2 --max-age 3600 2>/dev/null)"
check "listen: stale marked EXPIRED"  "EXPIRED"          "$(head -n1 .agent-relay/forgotten/status)"
check "watch: EXPIRED exit 8"         "8"                "$(q "$S/relay-watch.sh" forgotten --interval 1 --timeout 5)"

# --- watch: DONE / ERROR / BLOCKED / watchdog / stall
"$S/relay-write-result.sh" a - <<<result
check "watch: DONE exit 0"            "0"                "$(q "$S/relay-watch.sh" a --interval 1 --timeout 5)"
"$S/relay-write-status.sh" b ERROR "boom"
check "watch: ERROR exit 2"           "2"                "$(q "$S/relay-watch.sh" b --interval 1 --timeout 5)"
"$S/relay-write-status.sh" b BLOCKED "question?"
check "watch: BLOCKED exit 3"         "3"                "$(q "$S/relay-watch.sh" b --interval 1 --timeout 5)"
"$S/relay-write-status.sh" b RUNNING
check "watch: watchdog exit 1"        "1"                "$(q "$S/relay-watch.sh" b --interval 1 --timeout 2)"
check "watch: stall-warn exit 5"      "5"                "$(q "$S/relay-watch.sh" b --interval 1 --stall-warn 2 --timeout 30)"

# --- watch: approval grace - held -> 6, cleared in time -> no alert
"$S/relay-write-status.sh" b AWAITING_APPROVAL "some tool"
check "watch: approval held exit 6"   "6"                "$(q "$S/relay-watch.sh" b --interval 1 --approval-grace 2 --timeout 30)"
( sleep 2; "$S/relay-write-status.sh" b RUNNING; sleep 1; "$S/relay-write-result.sh" b - <<<r ) &
check "watch: approval cleared -> 0"  "0"                "$(q "$S/relay-watch.sh" b --interval 1 --approval-grace 5 --timeout 30)"
wait

# --- watch: back-to-back announced tool calls are progress, not a pending prompt
"$S/relay-init.sh" flappy - <<<x >/dev/null; mkdir .agent-relay/flappy/.claimed
( for i in 1 2 3 4 5 6 7 8; do "$S/relay-write-status.sh" flappy AWAITING_APPROVAL "tool $i"; sleep 1.5
      "$S/relay-write-status.sh" flappy RUNNING; sleep 0.1; done
  "$S/relay-write-result.sh" flappy - <<<done ) &
check "watch: quick tool calls, no false alarm" "0"      "$(q "$S/relay-watch.sh" flappy --interval 2 --approval-grace 4 --timeout 60)"
wait

# --- watch: unclaimed warning only when nobody is listening and nobody is busy
for t in c fresh; do "$S/relay-write-result.sh" "$t" - <<<r; done   # finish tasks claimed above
rm -f .agent-relay/.listener
"$S/relay-init.sh" orphan - <<<x >/dev/null
check "watch: unclaimed exit 7"       "7"                "$(q "$S/relay-watch.sh" orphan --interval 1 --unclaimed-warn 2 --timeout 30)"
"$S/relay-init.sh" busy - <<<x >/dev/null; mkdir .agent-relay/busy/.claimed
( for i in 1 2 3 4 5 6 7; do "$S/relay-write-status.sh" busy RUNNING "step $i"; sleep 1; done ) &   # worker busy, progressing
check "watch: no unclaimed warn while worker busy" "1"   "$(q "$S/relay-watch.sh" orphan --interval 1 --unclaimed-warn 2 --timeout 4)"
wait
touch -t 202601010000 .agent-relay/busy/status   # busy task abandoned (worker crashed)
check "watch: abandoned task doesn't suppress warn" "7"  "$(q "$S/relay-watch.sh" orphan --interval 1 --unclaimed-warn 2 --timeout 30)"
"$S/relay-write-result.sh" busy - <<<r

# --- stop: every listener stops; --clear-stop removes a leftover
touch .agent-relay/.stop
L --timeout 5 >/dev/null 2>&1 & p1=$!
L --timeout 5 >/dev/null 2>&1 & p2=$!
wait $p1; e1=$?; wait $p2; e2=$?
check "stop: both listeners exit 4"   "4 4"              "$e1 $e2"
check "stop: .stop left in place"     "yes"              "$([[ -e .agent-relay/.stop ]] && echo yes || echo no)"
check "stop: --clear-stop starts clean" "orphan"         "$(L --timeout 2 --clear-stop 2>/dev/null)"
check "stop: .stop cleared"           "no"               "$([[ -e .agent-relay/.stop ]] && echo yes || echo no)"

# --- files get normal umask-based permissions, not mktemp's 0600
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
check "perms: status readable (644)"  "644"              "$(perm .agent-relay/a/status)"
check "perms: result readable (644)"  "644"              "$(perm .agent-relay/a/result.md)"

# --- init: "busy" when every worker is mid-task; waits for a starting worker
rm -rf "$T/w2"; mkdir "$T/w2"; cd "$T/w2"
"$S/relay-init.sh" job1 - <<<x >/dev/null; mkdir .agent-relay/job1/.claimed
"$S/relay-write-status.sh" job1 RUNNING
out="$("$S/relay-init.sh" job2 - <<<x)"
check "init: busy worker -> LISTENER busy" "LISTENER: busy" "$(grep -o 'LISTENER: busy' <<<"$out")"
"$S/relay-write-result.sh" job1 - <<<r
( sleep 2; touch .agent-relay/.listener ) &
out="$(RELAY_LISTENER_WAIT_SECS=6 "$S/relay-init.sh" job3 - <<<x)"
check "init: waits for a starting worker" "LISTENER: active" "$(grep -o 'LISTENER: active' <<<"$out")"
wait
rm -f .agent-relay/.listener
out="$(RELAY_LISTENER_WAIT_SECS=2 "$S/relay-init.sh" job4 - <<<x)"
check "init: none after waiting"      "LISTENER: none"   "$(grep -o 'LISTENER: none' <<<"$out")"
cd "$T"

# --- install: defaults, spaces, custom paths, safety, uninstall (sandboxed HOME)
I="$(cd "$S/.." && pwd)/install.sh"
export HOME="$T/home"; mkdir -p "$HOME"
unset AGENT_RELAY_WORKSPACE AGENT_RELAY_SCOPE AGENT_RELAY_SKILLS_DIR AGENT_RELAY_MODE AGENT_RELAY_PROMPTS_DIR
W="$T/my workspace"; mkdir -p "$W"
UL="$HOME/.claude/skills/agent-relay"
P="$W/.github/prompts/relay-worker.prompt.md"
check "install: defaults (cwd, user, link)" "0"          "$(cd "$W" && q "$I")"
check "install: skill linked"         "yes"              "$([[ -L "$UL" ]] && echo yes || echo no)"
check "install: prompt link ok with space" "1"           "$(grep -cF "(<$UL/WORKER.md>)" "$P")"
check "install: prompt quotes workspace" "1"             "$(grep -cF "cd \"$W\"" "$P")"
check "install: re-run is idempotent" "0"                "$(cd "$W" && q "$I")"
check "install: no .bak on re-run"    "no"               "$([[ -e "$P.bak" ]] && echo yes || echo no)"
check "install: project scope, copy"  "0"                "$(q "$I" "$W" --scope project --mode copy)"
check "install: real copy in project" "yes"              "$([[ -f "$W/.claude/skills/agent-relay/SKILL.md" && ! -L "$W/.claude/skills/agent-relay" ]] && echo yes || echo no)"
check "install: copy re-run refreshes" "0"               "$(q "$I" "$W" --scope project --mode copy)"
check "install: copy->link needs --force" "1"            "$(q "$I" "$W" --scope project)"
check "install: custom dirs via env"  "0"                "$(AGENT_RELAY_SKILLS_DIR="$T/sk" AGENT_RELAY_PROMPTS_DIR="$T/pr" q "$I" "$W")"
check "install: custom dirs used"     "yes"              "$([[ -L "$T/sk/agent-relay" && -f "$T/pr/relay-worker.prompt.md" ]] && echo yes || echo no)"
mkdir -p "$T/foreign/agent-relay"
check "install: won't replace foreign dir" "1"           "$(q "$I" "$W" --skills-dir "$T/foreign" --force)"
check "install: dry-run changes nothing" "no"            "$(q "$I" "$W" --skills-dir "$T/dry" --prompts-dir "$T/dry" --dry-run >/dev/null; [[ -e "$T/dry" ]] && echo yes || echo no)"
check "install: bad --mode refused"   "1"                "$(q "$I" "$W" --mode move)"
check "uninstall: user scope"         "0"                "$(q "$I" "$W" --uninstall)"
check "uninstall: link and prompt gone" "no no"          "$([[ -e "$UL" || -L "$UL" ]] && echo yes || echo no) $([[ -e "$P" ]] && echo yes || echo no)"
check "uninstall: project copy"       "0"                "$(q "$I" "$W" --scope project --uninstall)"
check "uninstall: copy gone"          "no"               "$([[ -e "$W/.claude/skills/agent-relay" ]] && echo yes || echo no)"

echo
echo "${pass} passed, ${fail} failed"
(( fail == 0 ))
