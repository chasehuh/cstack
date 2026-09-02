#!/usr/bin/env bash
# List or stop every process that still holds an agent session uuid: the
# wrapper bash, the tokenmaxxing supervisor, and the raw grok / claude child.
#
#   agent-holders list <uuid>     # pid<TAB>pgid<TAB>command, one per holder
#   agent-holders kill <uuid>     # TERM the holders' process groups, wait,
#                                 # KILL leftovers; exit 0 clear, 3 still held
#   agent-holders close <uuid>    # no holder alive: append synthetic
#                                 # task_completed / turn_completed records so
#                                 # Grok can resume a session killed mid-turn
#
# Rules (issue sumelabs/sume#5706):
# - Key on `--resume <uuid>` / `--session-id <uuid>` argv tokens, never on a
#   bare uuid: steer prompts mention the uuid they are steering.
# - macOS `pgrep -a` means "include ancestors" and prints PIDs only; the argv
#   listing is `pgrep -lf`. Linux procps uses `-af`.
# - Never touch a process running `gt merge` / `gt submit`, this process, or
#   its ancestors (the shell that launched us has the uuid in its argv too).
# - Killing the tokenmaxxing supervisor alone orphans the raw grok child
#   (no SIGTERM forward), so the raw child is matched and killed by argv.
set -euo pipefail

usage() {
  echo "usage: agent-holders list|kill|close <uuid>" >&2
  exit 2
}

cmd="${1:-}"
uuid="${2:-}"
[[ -n "$cmd" && -n "$uuid" ]] || usage
case "$uuid" in
  *[!a-zA-Z0-9_.-]*) echo "agent-holders: bad uuid: $uuid" >&2; exit 2 ;;
esac

WAIT_SECS="${AGENT_HOLDERS_WAIT:-15}"
# `kill` is a bash builtin; tests point this at a fake binary.
KILL_BIN="${AGENT_HOLDERS_KILL:-kill}"

argv_list() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pgrep -lf -- "$uuid" 2>/dev/null || true
  else
    pgrep -af -- "$uuid" 2>/dev/null || true
  fi
}

ancestors() {
  local p=$$ pp
  while [[ -n "$p" && "$p" != "0" && "$p" != "1" ]]; do
    printf '%s\n' "$p"
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
    [[ -n "$pp" && "$pp" != "$p" ]] || break
    p=$pp
  done
}

pgid_of() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ' || true
}

# pid<TAB>pgid<TAB>command
holders() {
  local skip
  skip=$(ancestors | tr '\n' ' ')
  argv_list | awk -v u="$uuid" -v skip=" $skip " '
    {
      pid = $1
      if (index(skip, " " pid " ") > 0) next
      line = $0
      if (line ~ /gt merge|gt submit/) next
      if (line ~ /agent-holders/) next
      if (line !~ /agent-human-stream|sume-bg-launch|supervise|grok|claude/) next
      if (line ~ ("(^|[ \t])(--resume|--session-id|-r|-s)[= ]" u "([ \t]|$)")) print pid "\t" line
    }' | while IFS=$'\t' read -r pid line; do
      [[ -n "$pid" ]] || continue
      printf '%s\t%s\t%s\n' "$pid" "$(pgid_of "$pid")" "$line"
    done
}

signal_holders() {
  local sig="$1" my_pgid pid pgid line
  my_pgid=$(pgid_of $$)
  local -a groups=()
  while IFS=$'\t' read -r pid pgid line; do
    [[ -n "$pid" ]] || continue
    if [[ -n "$pgid" && "$pgid" != "$my_pgid" ]]; then
      case " ${groups[*]-} " in
        *" $pgid "*) ;;
        *)
          groups+=("$pgid")
          echo "agent-holders: $sig group $pgid (${line:0:80})" >&2
          "$KILL_BIN" "-$sig" -- "-$pgid" 2>/dev/null || true
          ;;
      esac
    fi
    "$KILL_BIN" "-$sig" "$pid" 2>/dev/null || true
  done < <(holders)
}

wait_clear() {
  local deadline=$(( $(date +%s) + $1 ))
  while :; do
    [[ -z "$(holders)" ]] && return 0
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.5
  done
}

# Grok 1.0.11 will not resume a session whose last turn never closed (an
# in-flight model call or a backgrounded task with no task_completed): the
# resume blocks forever in session_create. After the holder is dead, close
# the turn on disk. Verified 2026-09-02 (sumelabs/sume#5706): append
# task_completed for open task_backgrounded records + turn_completed
# (stop_reason interrupted) to updates.jsonl and turn_ended to events.jsonl.
close_session() {
  if [[ -n "$(holders)" ]]; then
    echo "agent-holders: refusing to close $uuid — a live holder still exists" >&2
    return 3
  fi
  python3 - "$uuid" <<'PYCLOSE'
import glob, json, os, shutil, sys, time
uuid = sys.argv[1]
home = os.path.expanduser(os.environ.get("GROK_HOME") or "~/.grok")
dirs = glob.glob(os.path.join(home, "sessions", "*", uuid))
if not dirs:
    print(f"agent-holders: close: no session dir for {uuid} under {home}/sessions", file=sys.stderr)
    sys.exit(0)
d = dirs[0]
upd = os.path.join(d, "updates.jsonl"); ev = os.path.join(d, "events.jsonl")
if not os.path.exists(upd):
    sys.exit(0)
rows = []
for line in open(upd, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        continue
sid = uuid; open_tasks = {}; open_turn = False; last_meta = 0
for r in rows:
    p = r.get("params") or {}; u = p.get("update") or {}
    k = u.get("sessionUpdate")
    if k == "task_backgrounded":
        open_tasks[u.get("task_id")] = u
    elif k == "task_completed":
        open_tasks.pop((u.get("task_snapshot") or {}).get("task_id"), None)
    elif k == "user_message_chunk":
        open_turn = True
    elif k == "turn_completed":
        open_turn = False
    m = (u.get("_meta") or {}).get("eventId") or ""
    try:
        last_meta = max(last_meta, int(m.rsplit("-", 1)[-1]))
    except ValueError:
        pass
if not open_turn and not open_tasks:
    print(f"agent-holders: close: {uuid} already closed (nothing to do)", file=sys.stderr)
    sys.exit(0)
stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
for f in (upd, ev):
    if os.path.exists(f):
        shutil.copy2(f, f + ".pre-close-" + stamp)
prompt_id = None
try:
    prompt_id = json.load(open(os.path.join(d, "summary.json"), encoding="utf-8")).get("request_id")
except (OSError, ValueError):
    pass
now = int(time.time()); ms = now * 1000
def emit(update):
    global last_meta
    last_meta += 1
    update = dict(update)
    update["_meta"] = {"eventId": f"{sid}-{last_meta}", "agentTimestampMs": ms}
    with open(upd, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"timestamp": now, "method": "_x.ai/session/update",
                             "params": {"sessionId": sid, "update": update}}) + "\n")
for tid, u in open_tasks.items():
    emit({"sessionUpdate": "task_completed",
          "task_snapshot": {"task_id": tid, "tool_call_id": u.get("tool_call_id"),
                            "command": u.get("command") or "", "status": "killed",
                            "exit_code": 143, "output": "(killed by desk steer: agent-holders close)"}})
if open_turn:
    emit({"sessionUpdate": "turn_completed", "prompt_id": prompt_id,
          "stop_reason": "interrupted", "usage": {"inputTokens": 0, "outputTokens": 0}})
    with open(ev, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                             "type": "turn_ended", "outcome": "interrupted"}) + "\n")
print(f"agent-holders: closed open turn for {uuid} (tasks={len(open_tasks)}, turn={open_turn}); backups *.pre-close-{stamp}", file=sys.stderr)
PYCLOSE
}

case "$cmd" in
  list)
    holders
    ;;
  close)
    close_session
    ;;
  kill)
    if [[ -z "$(holders)" ]]; then
      exit 0
    fi
    signal_holders TERM
    if wait_clear "$WAIT_SECS"; then
      echo "agent-holders: session $uuid released" >&2
      close_session || true
      exit 0
    fi
    echo "agent-holders: holders survived TERM for ${WAIT_SECS}s; sending KILL" >&2
    signal_holders KILL
    if wait_clear 3; then
      echo "agent-holders: session $uuid released (KILL)" >&2
      close_session || true
      exit 0
    fi
    echo "agent-holders: session $uuid is still held:" >&2
    holders >&2
    exit 3
    ;;
  *)
    usage
    ;;
esac
