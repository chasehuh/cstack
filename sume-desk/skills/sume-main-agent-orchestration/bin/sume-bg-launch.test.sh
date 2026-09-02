#!/usr/bin/env bash
# Offline tests for agent-holders (the steer-kill behind sume-bg-launch
# --resume). Fakes pgrep/ps/kill/uname on PATH; no real processes touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOLDERS="$ROOT/agent-holders.sh"
U="01a05de0-e4d4-7471-a074-891cf3ec7c94"
OTHER="01a05ddf-55ee-7ea2-8251-deb3960c8ef3"
THIRD="01a05e1f-90bb-7561-b9a9-8f5e4f9558c6"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/bin"
mkdir -p "$FAKE"
export FAKE_PROCS="$TMP/procs"        # pid<TAB>ppid<TAB>pgid<TAB>command
export FAKE_KILL_LOG="$TMP/kill.log"
export FAKE_IMMORTAL="${FAKE_IMMORTAL:-}"
export FAKE_SELF_PARENT=$$
: > "$FAKE_KILL_LOG"

cat > "$FAKE/uname" <<'SH'
#!/usr/bin/env bash
echo Darwin
SH
# macOS shape: -lf prints "pid command", -af prints pids only (ancestors flag).
cat > "$FAKE/pgrep" <<'SH'
#!/usr/bin/env bash
mode=""; pat=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -lf|-fl) mode=lf; shift ;;
    -af|-fa) mode=af; shift ;;
    --) shift; pat="$1"; shift ;;
    *) pat="$1"; shift ;;
  esac
done
while IFS=$'\t' read -r pid ppid pgid cmd; do
  [[ "$cmd" == *"$pat"* ]] || continue
  if [[ "$mode" == "lf" ]]; then printf '%s %s\n' "$pid" "$cmd"; else printf '%s\n' "$pid"; fi
done < "$FAKE_PROCS"
SH
cat > "$FAKE/ps" <<'SH'
#!/usr/bin/env bash
# ps -o ppid= -p PID | ps -o pgid= -p PID
field="$2"; pid="$4"
while IFS=$'\t' read -r p ppid pgid cmd; do
  [[ "$p" == "$pid" ]] || continue
  case "$field" in ppid=) echo "$ppid" ;; pgid=) echo "$pgid" ;; esac
  exit 0
done < "$FAKE_PROCS"
# Unknown pid = the agent-holders process itself → its parent is the test shell.
[[ "$field" == "ppid=" ]] && echo "${FAKE_SELF_PARENT:-1}"
SH
cat > "$FAKE/kill" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_KILL_LOG"
sig="${1#-}"; shift
[[ "$1" == "--" ]] && shift
target="$1"
tmp="$FAKE_PROCS.tmp"; : > "$tmp"
while IFS=$'\t' read -r pid ppid pgid cmd; do
  dead=0
  if [[ "$target" == -* ]]; then
    [[ "$pgid" == "${target#-}" ]] && dead=1
  else
    [[ "$pid" == "$target" ]] && dead=1
  fi
  if [[ "$dead" == 1 && "$pid" == "$FAKE_IMMORTAL" && "$sig" == "TERM" ]]; then dead=0; fi
  if [[ "$dead" == 1 && "$pid" == "$FAKE_IMMORTAL" && "$sig" == "KILL" && "${FAKE_TRULY_IMMORTAL:-0}" == 1 ]]; then dead=0; fi
  [[ "$dead" == 1 ]] || printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$pgid" "$cmd" >> "$tmp"
done < "$FAKE_PROCS"
mv "$tmp" "$FAKE_PROCS"
SH
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
export AGENT_HOLDERS_WAIT=1
export AGENT_HOLDERS_KILL="$FAKE/kill"

seed() {
  # Our own ancestor chain must be excluded: the launching zsh (pid 100)
  # has the uuid in its argv too. The test shell is $$ with ppid $PPID; map
  # them onto pid 100 so ancestors() walks 100 → 1.
  cat > "$FAKE_PROCS" <<PROCS
100	1	100	/bin/zsh -c sume-bg-launch --backend grok --name hf --resume $U --prompt-file /tmp/p.md
$$	100	100	bash test-shell --resume $U
$PPID	1	100	zsh parent
501	100	501	/bin/bash /Users/x/.agents/skills/sume-main-agent-orchestration/bin/agent-human-stream.sh --backend grok --name hf --prompt-file /tmp/p.md --resume $U
502	501	501	/opt/homebrew/bin/bun run /Users/x/.local/src/tokenmaxxing/src/main.ts __supervise-grok --prompt-file /tmp/p.md --output-format streaming-messages-json --resume $U --effort xhigh
503	1	501	/Users/x/.grok/downloads/grok-1.0.11-macos-aarch64 --prompt-file /tmp/p.md --output-format streaming-messages-json --resume $U --effort xhigh
504	100	504	/Users/x/.grok/downloads/grok-1.0.11-macos-aarch64 -p STEERING same session $U keep going --session-id $OTHER
505	100	505	/bin/bash agent-human-stream.sh --backend grok --resume $U -- gt merge --dry-run
506	100	506	/Users/x/.grok/downloads/grok-1.0.11-macos-aarch64 -p fresh --session-id=$U
PROCS
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. list: wrapper, supervisor, raw child and --session-id=uuid match;
#    prompt mention (504), gt merge (505), and our ancestors (100) do not.
seed
got=$("$HOLDERS" list "$U" | cut -f1 | sort | tr '\n' ' ')
[[ "$got" == "501 502 503 506 " ]] || fail "list holders: got '$got' want '501 502 503 506 '"
pg=$("$HOLDERS" list "$U" | awk -F'\t' '$1==503{print $2}')
[[ "$pg" == "501" ]] || fail "pgid of raw child: got '$pg'"

# 2. kill: TERM the foreign process groups (501, 506) once each, then clear.
seed
"$HOLDERS" kill "$U" 2>/dev/null || fail "kill should succeed"
grep -q -- '-TERM -- -501' "$FAKE_KILL_LOG" || fail "no TERM to group 501: $(cat "$FAKE_KILL_LOG")"
grep -q -- '-TERM -- -506' "$FAKE_KILL_LOG" || fail "no TERM to group 506"
[[ $(grep -c -- '-TERM -- -501' "$FAKE_KILL_LOG") -eq 1 ]] || fail "group 501 signalled more than once"
grep -q -- '-TERM -- -100' "$FAKE_KILL_LOG" && fail "our own group 100 was signalled"
grep -q -- ' 504' "$FAKE_KILL_LOG" && fail "prompt-mention pid 504 was signalled"
grep -q -- ' 505' "$FAKE_KILL_LOG" && fail "gt merge pid 505 was signalled"
[[ -z "$("$HOLDERS" list "$U")" ]] || fail "holders remain after kill"

# 3. raw child survives TERM (supervisor orphan) → KILL escalates, still clears.
seed; : > "$FAKE_KILL_LOG"
FAKE_IMMORTAL=503 "$HOLDERS" kill "$U" 2>/dev/null || fail "kill with TERM-immune child should still clear via KILL"
grep -q -- '-KILL' "$FAKE_KILL_LOG" || fail "no KILL escalation"

# 4. truly immortal → exit 3, launcher must not proceed.
seed; : > "$FAKE_KILL_LOG"
set +e
FAKE_IMMORTAL=503 FAKE_TRULY_IMMORTAL=1 "$HOLDERS" kill "$U" 2>/dev/null
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "immortal holder: want exit 3 got $rc"

# 5. nothing held → exit 0, no signals.
seed; : > "$FAKE_KILL_LOG"
"$HOLDERS" kill "$OTHER" 2>/dev/null || fail "kill of unheld uuid should be a no-op success"
# 504 mentions $OTHER only via --session-id; it is a holder of OTHER, so it dies. Check a fresh uuid:
: > "$FAKE_KILL_LOG"
"$HOLDERS" kill "deadbeef-0000-0000-0000-000000000000" 2>/dev/null || fail "unknown uuid should exit 0"
[[ ! -s "$FAKE_KILL_LOG" ]] || fail "unknown uuid signalled something: $(cat "$FAKE_KILL_LOG")"

# 6. close: no holder → synthetic task_completed + turn_completed appended once; idempotent.
seed; : > "$FAKE_KILL_LOG"
export GROK_HOME="$TMP/grokhome"
SD="$GROK_HOME/sessions/%2Ftmp%2Fx/$THIRD"; mkdir -p "$SD"
printf '%s\n' '{"timestamp":1,"method":"_x.ai/session/update","params":{"sessionId":"'"$THIRD"'","update":{"sessionUpdate":"user_message_chunk","_meta":{"eventId":"'"$THIRD"'-1"}}}}' \
  '{"timestamp":2,"method":"_x.ai/session/update","params":{"sessionId":"'"$THIRD"'","update":{"sessionUpdate":"task_backgrounded","task_id":"call-1","tool_call_id":"call-1","command":"sleep 90","_meta":{"eventId":"'"$THIRD"'-2"}}}}' > "$SD/updates.jsonl"
printf '%s\n' '{"ts":"t","type":"turn_started"}' > "$SD/events.jsonl"
printf '{"request_id":"p1"}' > "$SD/summary.json"
"$HOLDERS" close "$THIRD" 2>/dev/null || fail "close should succeed with no holder"
grep -q '"task_completed"' "$SD/updates.jsonl" || fail "close did not append task_completed"
grep -q '"turn_completed"' "$SD/updates.jsonl" || fail "close did not append turn_completed"
grep -q '"turn_ended"' "$SD/events.jsonl" || fail "close did not append turn_ended"
ls "$SD"/updates.jsonl.pre-close-* >/dev/null 2>&1 || fail "no backup written"
n=$(grep -c . "$SD/updates.jsonl")
"$HOLDERS" close "$THIRD" 2>/dev/null || fail "second close should be a no-op"
[[ $(grep -c . "$SD/updates.jsonl") -eq $n ]] || fail "close is not idempotent"
# holder alive → close refuses (exit 3) and appends nothing
cat >> "$FAKE_PROCS" <<PROCS
601	100	601	/Users/x/.grok/downloads/grok-1.0.11-macos-aarch64 --prompt-file p.md --resume $THIRD
PROCS
printf '%s\n' '{"timestamp":3,"method":"_x.ai/session/update","params":{"sessionId":"'"$THIRD"'","update":{"sessionUpdate":"user_message_chunk","_meta":{"eventId":"'"$THIRD"'-9"}}}}' >> "$SD/updates.jsonl"
set +e; "$HOLDERS" close "$THIRD" 2>/dev/null; rc=$?; set -e
[[ "$rc" -eq 3 ]] || fail "close with live holder: want 3 got $rc"
unset GROK_HOME

echo "sume-bg-launch/agent-holders test: ok (darwin argv listing, group kill, orphan escalation, refuse, close)"
