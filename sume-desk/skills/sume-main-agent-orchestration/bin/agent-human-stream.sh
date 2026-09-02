#!/usr/bin/env bash
# Human-readable wrapper for Claude Code and Grok Build headless streams.
#
#   agent-human-stream "Audit #1708 …"
#   agent-human-stream --backend grok --name land-4414 "Watch MQ …"
#   agent-human-stream --resume <uuid> "Follow-up …"
#   agent-human-stream --prompt-file /tmp/sume-grok-prompts/job.md
#   claude-human-stream "…"          # alias: --backend claude
#
# Extra backend flags go after the prompt:
#   agent-human-stream "…" --model opus
#   agent-human-stream "…" --model fable   # → claude-fable-5-1 (Fable 5.1)
#   agent-human-stream --backend grok --prompt-file job.md --effort high
set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"
SKILL_DIR="$(cd "$ROOT/.." && pwd)"
# Runtime logs live outside the git SoT tree (skills are symlinks into cstack).
CSTACK_STATE="${CSTACK_STATE:-$HOME/.cstack/state}"
REGISTRY="${AGENT_HUMAN_STREAM_REGISTRY:-${CLAUDE_HUMAN_STREAM_REGISTRY:-$CSTACK_STATE/opus-sessions.jsonl}}"
LIVE_DIR="${AGENT_HUMAN_STREAM_LIVE_DIR:-${CLAUDE_HUMAN_STREAM_LIVE_DIR:-$CSTACK_STATE/opus-live}}"

# Claude Code CLI 2.1.x (SDK + changelog): low|medium|high|xhigh|max.
# Fable / Opus 4.7+ take `max` natively. Do NOT remap max → high.
# Desk aliases: mid → medium, maximum → max, x-high → xhigh.
# Desk --model fable → claude-fable-5-1 (Fable 5.1). Bare `fable` is not enough
# after Claude Code 2.1.258 (help still lists the alias; wire the full id).
_claude_effort_wire() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    mid) printf '%s' medium ;;
    max|maximum) printf '%s' max ;;
    xhigh|x-high|xh|extra-high|extrahigh) printf '%s' xhigh ;;
    low|medium|high) printf '%s' "$lc" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Chase lock 2026-09-02: desk "Fable" is Fable 5.1, not the generic alias.
_claude_model_wire() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    fable|fable-5|fable5|fable-5.1|fable-5-1|claude-fable|claude-fable-5|claude-fable-5.1|claude-fable-5-1)
      printf '%s' claude-fable-5-1
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# Grok Build CLI: xhigh|high|medium|low (no max / mid).
# Aliases: mid → medium, max|maximum → xhigh (Grok ceiling).
_grok_effort_wire() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    mid) printf '%s' medium ;;
    max|maximum|xhigh|x-high|xh|extra-high|extrahigh) printf '%s' xhigh ;;
    low|medium|high) printf '%s' "$lc" ;;
    *) printf '%s' "$1" ;;
  esac
}

usage() {
  cat <<'EOF'
Human-readable wrapper around Claude Code and Grok Build headless NDJSON.

  agent-human-stream [--backend claude|grok|auto] [--name <slug>] <prompt> [backend flags…]
  agent-human-stream --prompt-file <path>         # read prompt after flags; no $(cat)
  agent-human-stream --claude "…"                 # same as --backend claude
  agent-human-stream --grok "…"                   # same as --backend grok
  agent-human-stream --resume <uuid> --prompt-file <path>
  agent-human-stream --sessions
  agent-human-stream --self-test

Auto backend (default):
  --backend grok / --grok / AGENT_HUMAN_STREAM_BACKEND=grok
  --model grok*  → grok
  --model opus|fable|sonnet|haiku|claude* → claude
  --model fable → claude-fable-5-1 (Fable 5.1; do not leave bare fable)
  --resume <uuid> uses the last backend recorded for that session
  otherwise → claude (Opus/Fable path unchanged)

Claude (tokenmaxxing `claude` on this desk):
  claude -p … --output-format stream-json --verbose --permission-mode bypassPermissions
  Default --effort when omitted (code lane): opus → medium, fable → max,
  grok → xhigh. Research must pass --effort (grok medium / opus+fable low).
  Fable 5.1 may use the full Claude enum: low|medium|high|xhigh|max.
  Named levels pass through. Do not clamp Fable at high.
  Aliases: mid → medium, maximum → max, x-high → xhigh.

Grok Build (`grok` on PATH):
  grok -p … --output-format streaming-messages-json --permission-mode bypassPermissions --always-approve
  Native ACP streaming-json is also accepted by the formatter if you pass
  --output-format streaming-json after the prompt.
  Grok --effort enum: xhigh, high, medium, low (not mid / not max).
  Aliases: mid → medium, max|maximum → xhigh (Grok ceiling).

Resume:
  --resume <uuid>   | AGENT_RESUME_SESSION / CLAUDE_RESUME_SESSION / GROK_RESUME_SESSION
  --continue        most recent session in this cwd (refused for grok when another job is open here)
  --fork-session    new session id, copy history
  Grok --resume refuses to start while a live process still holds the uuid;
  steer with sume-bg-launch (kills the holder group first).

Long sessions (grok):
  Fresh grok runs mint --session-id up front (live log + registry know the uuid at t=0).
  --until-landed <PR#>   land-loop: after each model turn, re-prompt the same session
                         until `git log origin/main --grep='(#PR)'` hits; then LANDED: yes.
  --until-regex <re>     same loop, proof = regex on the last —— final —— text.
  --max-cycles N         land-loop bound (default 12) → LANDED: no, exit 4.
  --cycle-sleep S        seconds between cycles (default 60).
  --wall-timeout <dur>   6h | 90m | 3600 — TERM the session group, abort row.
  --allow-monitor        land jobs deny monitor/scheduler_* tools unless set.
  --no-caffeinate        darwin runs caffeinate -i for the wrapper lifetime by default.

Watch:
  tail -f ~/.cstack/state/opus-live/LATEST.log

On stream start/end the formatter prints:
  📎 session_id=<uuid>  backend=<claude|grok>
and again just above —— final ——.
EOF
}

BACKEND="${AGENT_HUMAN_STREAM_BACKEND:-auto}"
RESUME="${AGENT_RESUME_SESSION:-${GROK_RESUME_SESSION:-${CLAUDE_RESUME_SESSION:-}}}"
NAME=""
CONTINUE=0
FORK=0
LIST_SESSIONS=0
SELF_TEST=0
PROMPT=""
PROMPT_FILE=""
EXTRA=()
UNTIL_LANDED=""
UNTIL_REGEX=""
MAX_CYCLES="${AGENT_HUMAN_STREAM_MAX_CYCLES:-12}"
CYCLE_SLEEP="${AGENT_HUMAN_STREAM_CYCLE_SLEEP:-60}"
WALL_TIMEOUT="${AGENT_HUMAN_STREAM_WALL_TIMEOUT:-}"
ALLOW_MONITOR=0
NO_CAFFEINATE="${AGENT_HUMAN_STREAM_NO_CAFFEINATE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --sessions)
      LIST_SESSIONS=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    --backend)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --backend requires claude|grok|auto" >&2
        exit 2
      fi
      BACKEND=$2
      shift 2
      ;;
    --backend=*)
      BACKEND=${1#--backend=}
      shift
      ;;
    --claude)
      BACKEND=claude
      shift
      ;;
    --grok)
      BACKEND=grok
      shift
      ;;
    --resume|-r)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --resume requires a session uuid" >&2
        exit 2
      fi
      RESUME=$2
      shift 2
      ;;
    --name|-n)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --name requires a label" >&2
        exit 2
      fi
      NAME=$2
      shift 2
      ;;
    -c|--continue)
      CONTINUE=1
      shift
      ;;
    --fork-session)
      FORK=1
      shift
      ;;
    --prompt-file)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --prompt-file requires a path" >&2
        exit 2
      fi
      PROMPT_FILE=$2
      shift 2
      ;;
    --prompt-file=*)
      PROMPT_FILE=${1#--prompt-file=}
      shift
      ;;
    --until-landed)
      UNTIL_LANDED=${2:?--until-landed needs a PR number}
      shift 2
      ;;
    --until-regex)
      UNTIL_REGEX=${2:?--until-regex needs a pattern}
      shift 2
      ;;
    --max-cycles)
      MAX_CYCLES=${2:?--max-cycles needs a number}
      shift 2
      ;;
    --cycle-sleep)
      CYCLE_SLEEP=${2:?--cycle-sleep needs seconds}
      shift 2
      ;;
    --wall-timeout)
      WALL_TIMEOUT=${2:?--wall-timeout needs a duration (e.g. 6h, 90m, 3600)}
      shift 2
      ;;
    --allow-monitor)
      ALLOW_MONITOR=1
      shift
      ;;
    --no-caffeinate)
      NO_CAFFEINATE=1
      shift
      ;;
    --)
      shift
      if [[ $# -lt 1 ]]; then
        echo "error: missing prompt after --" >&2
        exit 2
      fi
      PROMPT=$1
      shift
      EXTRA=("$@")
      break
      ;;
    -*)
      # --prompt-file stands in for the positional prompt, so leftover flags
      # are backend extras (--effort, --model, …).
      if [[ -n "$PROMPT_FILE" ]]; then
        EXTRA=("$@")
        break
      fi
      echo "error: unknown wrapper option: $1 (wrapper flags before prompt; backend flags after)" >&2
      echo "run: $0 --help" >&2
      exit 2
      ;;
    *)
      PROMPT=$1
      shift
      EXTRA=("$@")
      break
      ;;
  esac
done

if [[ "$LIST_SESSIONS" -eq 1 ]]; then
  if [[ ! -f "$REGISTRY" ]]; then
    echo "(no registry yet: $REGISTRY)" >&2
    exit 0
  fi
  tail -n 30 "$REGISTRY"
  exit 0
fi

if [[ "$SELF_TEST" -eq 1 ]]; then
  _got="$(_grok_effort_wire mid)"
  if [[ "$_got" != "medium" ]]; then
    echo "self-test: grok effort alias mid → medium failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_grok_effort_wire max)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: grok effort alias max → xhigh failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_grok_effort_wire maximum)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: grok effort alias maximum → xhigh failed (got ${_got})" >&2
    exit 1
  fi
  for _keep in medium high low xhigh; do
    _got="$(_grok_effort_wire "$_keep")"
    if [[ "$_got" != "$_keep" ]]; then
      echo "self-test: grok effort ${_keep} should pass through (got ${_got})" >&2
      exit 1
    fi
  done
  _got="$(_claude_effort_wire max)"
  if [[ "$_got" != "max" ]]; then
    echo "self-test: claude effort max must stay max (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire maximum)"
  if [[ "$_got" != "max" ]]; then
    echo "self-test: claude effort alias maximum → max failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire mid)"
  if [[ "$_got" != "medium" ]]; then
    echo "self-test: claude effort alias mid → medium failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire xhigh)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: claude effort xhigh must stay xhigh (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire high)"
  if [[ "$_got" != "high" ]]; then
    echo "self-test: claude effort high must stay high (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_model_wire fable)"
  if [[ "$_got" != "claude-fable-5-1" ]]; then
    echo "self-test: --model fable must wire to claude-fable-5-1 (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_model_wire claude-fable-5-1)"
  if [[ "$_got" != "claude-fable-5-1" ]]; then
    echo "self-test: claude-fable-5-1 must pass through (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_model_wire opus)"
  if [[ "$_got" != "opus" ]]; then
    echo "self-test: --model opus must stay opus (got ${_got})" >&2
    exit 1
  fi
  _tmp=$(mktemp -d)
  cat > "$_tmp/grok" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "grok 0.0.0-fake (self-test) [stable]"; exit 0; fi
printf '%s\n' "$@" > "${GROK_ARGV_FILE:?}"
echo '{"type":"result","session_id":"00000000-0000-0000-0000-000000000000","result":"ok"}'
EOF
  chmod +x "$_tmp/grok"
  cat > "$_tmp/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CLAUDE_ARGV_FILE:?}"
echo '{"type":"result","session_id":"00000000-0000-0000-0000-000000000000","result":"ok"}'
EOF
  chmod +x "$_tmp/claude"
  GROK_ARGV_FILE="$_tmp/argv.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend grok --no-caffeinate "self-test mid alias" --effort mid >/dev/null
  if ! grep -qx 'medium' "$_tmp/argv.txt"; then
    echo "self-test: grok argv missing effort medium:" >&2
    cat "$_tmp/argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'mid' "$_tmp/argv.txt"; then
    echo "self-test: grok argv still has bare mid:" >&2
    cat "$_tmp/argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  echo "prompt-file self-test ok" > "$_tmp/p.md"
  GROK_ARGV_FILE="$_tmp/argv-file.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend grok --no-caffeinate --prompt-file "$_tmp/p.md" --effort high >/dev/null
  if ! grep -qx -- '--prompt-file' "$_tmp/argv-file.txt" || ! grep -qx -- "$_tmp/p.md" "$_tmp/argv-file.txt"; then
    echo "self-test: --prompt-file did not reach grok natively:" >&2
    cat "$_tmp/argv-file.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if ! grep -qx -- '--session-id' "$_tmp/argv-file.txt"; then
    echo "self-test: fresh grok run must mint --session-id:" >&2
    cat "$_tmp/argv-file.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  # land-loop: fake grok answers "watching" first, "LANDED: yes" on the 2nd call.
  cat > "$_tmp/grok-land" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "grok 0.0.0-fake (self-test) [stable]"; exit 0; fi
printf '%s\n' "$@" >> "${GROK_ARGV_FILE:?}"
n=$(cat "${GROK_CALLS:?}" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$GROK_CALLS"
if [[ "$n" -ge "${GROK_LAND_AT:-2}" ]]; then
  echo '{"type":"result","session_id":"00000000-0000-0000-0000-000000000000","result":"LANDED: yes — main has (#1)"}'
else
  echo '{"type":"result","session_id":"00000000-0000-0000-0000-000000000000","result":"Watching MQ draft; not on main yet."}'
fi
EOF
  chmod +x "$_tmp/grok-land"
  mkdir -p "$_tmp/landbin" && ln -sfn "$_tmp/grok-land" "$_tmp/landbin/grok" && ln -sfn "$_tmp/claude" "$_tmp/landbin/claude"
  echo "land self-test" > "$_tmp/land.md"
  : > "$_tmp/argv-land.txt"; echo 0 > "$_tmp/calls-land"
  set +e
  GROK_ARGV_FILE="$_tmp/argv-land.txt" GROK_CALLS="$_tmp/calls-land" GROK_LAND_AT=2 \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg-land.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live-land" \
    PATH="$_tmp/landbin:$PATH" \
    "$SOURCE" --backend grok --name self-test-land --no-caffeinate --until-regex 'LANDED: yes' \
      --max-cycles 3 --cycle-sleep 0 --prompt-file "$_tmp/land.md" --effort high >/dev/null 2>&1
  _rc=$?
  set -e
  _land_log=$(ls "$_tmp"/live-land/*self-test-land*.log | head -1)
  if [[ "$_rc" -ne 0 ]] || ! grep -q '↻ land-loop cycle 1/3' "$_land_log" || ! grep -q '^LANDED: yes' "$_land_log"; then
    echo "self-test: land-loop did not re-prompt to proof (rc=$_rc):" >&2
    cat "$_land_log" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if [[ "$(cat "$_tmp/calls-land")" != "2" ]] || ! grep -qx -- '--resume' "$_tmp/argv-land.txt" \
     || ! grep -q 'monitor,scheduler_create,scheduler_delete' "$_tmp/argv-land.txt"; then
    echo "self-test: land-loop argv wrong (calls=$(cat "$_tmp/calls-land")):" >&2
    cat "$_tmp/argv-land.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if ! grep -q '"event": "exit"' "$_tmp/reg-land.jsonl" || ! grep -q '"landed": "yes"' "$_tmp/reg-land.jsonl"; then
    echo "self-test: registry exit row missing landed=yes:" >&2
    cat "$_tmp/reg-land.jsonl" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  # bound: never proves → LANDED: no, exit 4
  : > "$_tmp/argv-land2.txt"; echo 0 > "$_tmp/calls-land2"
  set +e
  GROK_ARGV_FILE="$_tmp/argv-land2.txt" GROK_CALLS="$_tmp/calls-land2" GROK_LAND_AT=99 \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg-land2.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live-land2" \
    PATH="$_tmp/landbin:$PATH" \
    "$SOURCE" --backend grok --name self-test-land-bound --no-caffeinate --until-regex 'LANDED: yes' \
      --max-cycles 1 --cycle-sleep 0 --prompt-file "$_tmp/land.md" >/dev/null 2>&1
  _rc=$?
  set -e
  _land_log2=$(ls "$_tmp"/live-land2/*self-test-land-bound*.log | head -1)
  if [[ "$_rc" -ne 4 ]] || ! grep -q '^LANDED: no' "$_land_log2" || [[ "$(cat "$_tmp/calls-land2")" != "2" ]]; then
    echo "self-test: land-loop bound wrong (rc=$_rc calls=$(cat "$_tmp/calls-land2")):" >&2
    cat "$_land_log2" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  # init watchdog: a grok that never prints must be killed → exit 5 + ❌ line.
  cat > "$_tmp/grok-hang" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "grok 0.0.0-fake (self-test) [stable]"; exit 0; fi
sleep 30
EOF
  chmod +x "$_tmp/grok-hang"
  mkdir -p "$_tmp/hangbin" && ln -sfn "$_tmp/grok-hang" "$_tmp/hangbin/grok" && ln -sfn "$_tmp/claude" "$_tmp/hangbin/claude"
  set +e
  AGENT_HUMAN_STREAM_INIT_TIMEOUT=2 \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg-hang.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live-hang" \
    PATH="$_tmp/hangbin:$PATH" \
    "$SOURCE" --backend grok --name self-test-hang --no-caffeinate "self-test hang" >/dev/null 2>&1
  _rc=$?
  set -e
  _hang_log=$(ls "$_tmp"/live-hang/*self-test-hang*.log | head -1)
  if [[ "$_rc" -ne 5 ]] || ! grep -q '❌ no output from grok in 2s' "$_hang_log"; then
    echo "self-test: init watchdog did not fire (rc=$_rc):" >&2
    cat "$_hang_log" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if pgrep -f "$_tmp/grok-hang" >/dev/null 2>&1; then
    echo "self-test: hung grok survived the init watchdog" >&2
    pkill -f "$_tmp/grok-hang" || true
    rm -rf "$_tmp"
    exit 1
  fi
  GROK_ARGV_FILE="$_tmp/argv-max.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend grok --no-caffeinate "self-test max alias" --effort max >/dev/null
  if ! grep -qx 'xhigh' "$_tmp/argv-max.txt"; then
    echo "self-test: grok argv missing effort xhigh from max:" >&2
    cat "$_tmp/argv-max.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'max' "$_tmp/argv-max.txt"; then
    echo "self-test: grok argv still has bare max:" >&2
    cat "$_tmp/argv-max.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  CLAUDE_ARGV_FILE="$_tmp/claude-argv.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend claude --name self-test-max "self-test claude max" --model fable --effort max >/dev/null
  if ! grep -qx 'max' "$_tmp/claude-argv.txt"; then
    echo "self-test: claude argv missing effort max:" >&2
    cat "$_tmp/claude-argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'high' "$_tmp/claude-argv.txt"; then
    echo "self-test: claude --effort max was remapped to high:" >&2
    cat "$_tmp/claude-argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  CLAUDE_ARGV_FILE="$_tmp/claude-argv-maximum.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend claude --name self-test-maximum "self-test claude maximum" --model fable --effort maximum >/dev/null
  if ! grep -qx 'max' "$_tmp/claude-argv-maximum.txt"; then
    echo "self-test: claude argv missing effort max from maximum:" >&2
    cat "$_tmp/claude-argv-maximum.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'maximum' "$_tmp/claude-argv-maximum.txt"; then
    echo "self-test: claude argv still has bare maximum:" >&2
    cat "$_tmp/claude-argv-maximum.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if ! grep -qx 'claude-fable-5-1' "$_tmp/claude-argv.txt"; then
    echo "self-test: claude argv missing model claude-fable-5-1 from --model fable:" >&2
    cat "$_tmp/claude-argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'fable' "$_tmp/claude-argv.txt"; then
    echo "self-test: claude argv still has bare --model fable:" >&2
    cat "$_tmp/claude-argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  CLAUDE_ARGV_FILE="$_tmp/claude-argv-fable-default.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend claude --name self-test-fable-default "self-test fable default effort" --model fable >/dev/null
  if ! grep -qx 'max' "$_tmp/claude-argv-fable-default.txt"; then
    echo "self-test: fable omitted --effort must default to max:" >&2
    cat "$_tmp/claude-argv-fable-default.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  rm -rf "$_tmp"
  exec python3 "$ROOT/agent-human-stream.test.py"
fi

if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "error: --prompt-file not found: $PROMPT_FILE" >&2
    exit 2
  fi
  if [[ ! -s "$PROMPT_FILE" ]]; then
    echo "error: --prompt-file is empty: $PROMPT_FILE" >&2
    exit 2
  fi
  if [[ -n "$PROMPT" ]]; then
    echo "error: use either --prompt-file or a positional prompt, not both" >&2
    exit 2
  fi
  PROMPT=$(cat "$PROMPT_FILE")
  if [[ -z "$PROMPT" ]]; then
    echo "error: --prompt-file read empty: $PROMPT_FILE" >&2
    exit 2
  fi
fi

if [[ -z "$PROMPT" ]]; then
  echo "error: missing prompt" >&2
  echo "usage: $0 [--backend claude|grok|auto] [--resume <uuid>|--continue] [--name <label>] (--prompt-file <path> | <prompt>) [backend args...]" >&2
  exit 2
fi

if [[ -n "$RESUME" && "$CONTINUE" -eq 1 ]]; then
  echo "error: use either --resume <uuid> or --continue, not both" >&2
  exit 2
fi

BACKEND=$(printf '%s' "$BACKEND" | tr '[:upper:]' '[:lower:]')
case "$BACKEND" in
  claude|grok|auto) ;;
  *)
    echo "error: --backend must be claude, grok, or auto (got: $BACKEND)" >&2
    exit 2
    ;;
esac

_has_effort=0
_resolved_model=""
_passed_effort=""
_has_output_format=0
_has_permission_mode=0
_has_always_approve=0
_has_session_id=0
_has_disallowed_tools=0
_i=0
while [[ $_i -lt ${#EXTRA[@]} ]]; do
  _a="${EXTRA[$_i]}"
  case "$_a" in
    --effort|--reasoning-effort)
      _has_effort=1
      _passed_effort="${EXTRA[$((_i + 1))]:-}"
      _i=$((_i + 2))
      continue
      ;;
    --effort=*|--reasoning-effort=*)
      _has_effort=1
      _passed_effort="${_a#*=}"
      _i=$((_i + 1))
      continue
      ;;
    --model|-m)
      _resolved_model="${EXTRA[$((_i + 1))]:-}"
      _i=$((_i + 2))
      continue
      ;;
    --model=*|-m=*)
      _resolved_model="${_a#*=}"
      _i=$((_i + 1))
      continue
      ;;
    --output-format)
      _has_output_format=1
      _i=$((_i + 2))
      continue
      ;;
    --output-format=*)
      _has_output_format=1
      _i=$((_i + 1))
      continue
      ;;
    --permission-mode)
      _has_permission_mode=1
      _i=$((_i + 2))
      continue
      ;;
    --permission-mode=*)
      _has_permission_mode=1
      _i=$((_i + 1))
      continue
      ;;
    --always-approve|--yolo)
      _has_always_approve=1
      _i=$((_i + 1))
      continue
      ;;
    --session-id|-s)
      _has_session_id=1
      _i=$((_i + 2))
      continue
      ;;
    --session-id=*|-s=*)
      _has_session_id=1
      _i=$((_i + 1))
      continue
      ;;
    --disallowed-tools|--disallowed-tools=*)
      _has_disallowed_tools=1
      _i=$((_i + 1))
      continue
      ;;
  esac
  _i=$((_i + 1))
done

lookup_session_field() {
  local sid="$1" field="$2"
  [[ -n "$sid" && -f "$REGISTRY" ]] || return 0
  python3 -c '
import json, sys
path, sid, field = sys.argv[1], sys.argv[2], sys.argv[3]
found = ""
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("session_id") == sid and rec.get(field):
                found = str(rec[field])
except OSError:
    pass
print(found)
' "$REGISTRY" "$sid" "$field"
}

if [[ -z "$_resolved_model" && -n "$RESUME" ]]; then
  _resolved_model=$(lookup_session_field "$RESUME" model)
fi
if [[ -n "$_resolved_model" ]]; then
  _wired_model="$(_claude_model_wire "$_resolved_model")"
  if [[ "$_wired_model" != "$_resolved_model" ]]; then
    echo "note: mapping claude --model ${_resolved_model} → ${_wired_model} (Fable 5.1)" >&2
    _resolved_model="$_wired_model"
  fi
fi

if [[ "$BACKEND" == "auto" && -n "$RESUME" ]]; then
  _reg_backend=$(lookup_session_field "$RESUME" backend)
  case "$_reg_backend" in
    claude|grok) BACKEND=$_reg_backend ;;
  esac
fi

if [[ "$BACKEND" == "auto" ]]; then
  _model_lc=$(printf '%s' "${_resolved_model}" | tr '[:upper:]' '[:lower:]')
  case "$_model_lc" in
    grok|grok*|grok-*)
      BACKEND=grok
      ;;
    opus|opus*|fable|fable*|sonnet|sonnet*|haiku|haiku*|claude|claude-*)
      BACKEND=claude
      ;;
    *)
      BACKEND=claude
      ;;
  esac
fi

# Grok session guards (sumelabs/sume#5706): a second `grok -p --resume` against
# a live session blocks forever in session_create (empty live log), and
# `--continue` picks whichever job in this cwd started last.
if [[ "$BACKEND" == "grok" && -n "$RESUME" && "${AGENT_HUMAN_STREAM_FORCE_RESUME:-0}" != "1" ]]; then
  _held=$("$ROOT/agent-holders.sh" list "$RESUME" 2>/dev/null || true)
  if [[ -n "$_held" ]]; then
    echo "error: session $RESUME is still held by a live process:" >&2
    printf '%s\n' "$_held" >&2
    echo "steer with: sume-bg-launch --backend grok --name <slug> --resume $RESUME --prompt-file <path>" >&2
    exit 3
  fi
fi
if [[ "$BACKEND" == "grok" && -n "$RESUME" && "${AGENT_HUMAN_STREAM_NO_CLOSE:-0}" != "1" ]]; then
  "$ROOT/agent-holders.sh" close "$RESUME" || true
fi
if [[ "$BACKEND" == "grok" && "$CONTINUE" -eq 1 && "${AGENT_HUMAN_STREAM_ALLOW_CONTINUE:-0}" != "1" ]]; then
  _open=$(python3 - "$REGISTRY" "$PWD" <<'PY2' || true
import json, sys, time
path, cwd = sys.argv[1], sys.argv[2]
starts, closed = {}, set()
cutoff = time.time() - 24 * 3600
try:
    for line in open(path, encoding="utf-8"):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("backend") != "grok" or rec.get("cwd") != cwd:
            continue
        pid = rec.get("pid")
        ev = rec.get("event")
        try:
            ts = time.mktime(time.strptime(rec.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
        except Exception:
            ts = 0
        if ev == "start" and ts >= cutoff:
            starts[pid] = rec.get("name") or "?"
        elif ev in ("end", "abort", "exit"):
            closed.add(pid)
except OSError:
    pass
print(" ".join(f"{pid}:{name}" for pid, name in starts.items() if pid not in closed))
PY2
)
  if [[ -n "$_open" ]]; then
    echo "error: --continue is ambiguous for grok: open job(s) in this cwd: $_open" >&2
    echo "use --resume <uuid> (registry: agent-human-stream --sessions)" >&2
    exit 3
  fi
fi

_effort="$_passed_effort"
if [[ "$BACKEND" == "claude" && "$_has_effort" -eq 0 ]]; then
  _model_lc=$(printf '%s' "${_resolved_model:-opus}" | tr '[:upper:]' '[:lower:]')
  case "$_model_lc" in
    fable|fable*|claude-fable*)
      _effort="${CLAUDE_HUMAN_STREAM_EFFORT_FABLE:-${AGENT_HUMAN_STREAM_EFFORT_FABLE:-max}}"
      ;;
    *)
      _effort="${CLAUDE_HUMAN_STREAM_EFFORT_OPUS:-${AGENT_HUMAN_STREAM_EFFORT_OPUS:-medium}}"
      ;;
  esac
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for model=${_resolved_model:-opus}; override with --effort)" >&2
elif [[ "$BACKEND" == "grok" && "$_has_effort" -eq 0 ]]; then
  _effort="$(_grok_effort_wire "${AGENT_HUMAN_STREAM_EFFORT_GROK:-xhigh}")"
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for grok code lane; research → --effort medium)" >&2
fi

# Claude: rewrite desk aliases so --effort max/xhigh reach the CLI as-is.
if [[ "$BACKEND" == "claude" && ${#EXTRA[@]} -gt 0 ]]; then
  _filtered=()
  _i=0
  while [[ $_i -lt ${#EXTRA[@]} ]]; do
    _a="${EXTRA[$_i]}"
    case "$_a" in
      --model|-m)
        _val="${EXTRA[$((_i + 1))]:-}"
        _wire="$(_claude_model_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping claude --model ${_val} → ${_wire} (Fable 5.1)" >&2
        fi
        _filtered+=("$_a" "$_wire")
        _resolved_model="$_wire"
        _i=$((_i + 2))
        continue
        ;;
      --model=*|-m=*)
        _flag="${_a%%=*}"
        _val="${_a#*=}"
        _wire="$(_claude_model_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping claude --model ${_val} → ${_wire} (Fable 5.1)" >&2
        fi
        _filtered+=("${_flag}=${_wire}")
        _resolved_model="$_wire"
        _i=$((_i + 1))
        continue
        ;;
      --effort|--reasoning-effort)
        _val="${EXTRA[$((_i + 1))]:-}"
        _wire="$(_claude_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping claude --effort ${_val} → ${_wire} (Claude Code enum)" >&2
        fi
        _filtered+=("$_a" "$_wire")
        _effort="$_wire"
        _i=$((_i + 2))
        continue
        ;;
      --effort=*|--reasoning-effort=*)
        _flag="${_a%%=*}"
        _val="${_a#*=}"
        _wire="$(_claude_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping claude --effort ${_val} → ${_wire} (Claude Code enum)" >&2
        fi
        _filtered+=("${_flag}=${_wire}")
        _effort="$_wire"
        _i=$((_i + 1))
        continue
        ;;
    esac
    _filtered+=("$_a")
    _i=$((_i + 1))
  done
  EXTRA=("${_filtered[@]+"${_filtered[@]}"}")
fi

# Grok does not accept Claude-only --verbose / stream-json name.
if [[ "$BACKEND" == "grok" && ${#EXTRA[@]} -gt 0 ]]; then
  _filtered=()
  _i=0
  while [[ $_i -lt ${#EXTRA[@]} ]]; do
    _a="${EXTRA[$_i]}"
    case "$_a" in
      --verbose)
        echo "note: dropping --verbose (Claude-only) for grok" >&2
        _i=$((_i + 1))
        continue
        ;;
      --output-format)
        _fmt="${EXTRA[$((_i + 1))]:-}"
        if [[ "$_fmt" == "stream-json" ]]; then
          _fmt="streaming-messages-json"
          echo "note: mapping --output-format stream-json → streaming-messages-json" >&2
        fi
        _filtered+=(--output-format "$_fmt")
        _i=$((_i + 2))
        continue
        ;;
      --output-format=stream-json)
        _filtered+=(--output-format streaming-messages-json)
        echo "note: mapping --output-format stream-json → streaming-messages-json" >&2
        _i=$((_i + 1))
        continue
        ;;
      --effort|--reasoning-effort)
        _val="${EXTRA[$((_i + 1))]:-}"
        _wire="$(_grok_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping grok --effort ${_val} → ${_wire} (Grok CLI enum)" >&2
        fi
        _filtered+=("$_a" "$_wire")
        _effort="$_wire"
        _i=$((_i + 2))
        continue
        ;;
      --effort=*|--reasoning-effort=*)
        _flag="${_a%%=*}"
        _val="${_a#*=}"
        _wire="$(_grok_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping grok --effort ${_val} → ${_wire} (Grok CLI enum)" >&2
        fi
        _filtered+=("${_flag}=${_wire}")
        _effort="$_wire"
        _i=$((_i + 1))
        continue
        ;;
    esac
    _filtered+=("$_a")
    _i=$((_i + 1))
  done
  EXTRA=("${_filtered[@]+"${_filtered[@]}"}")
fi

if [[ -n "$UNTIL_LANDED$UNTIL_REGEX" && "$BACKEND" != "grok" ]]; then
  echo "error: --until-landed / --until-regex are grok land-loop options" >&2
  exit 2
fi

# ---------- session id (grok): mint up front so the live log + registry know it ----------
SESSION_ID=""
if [[ "$BACKEND" == "grok" && -z "$RESUME" && "$CONTINUE" -eq 0 && "$_has_session_id" -eq 0 \
      && "${AGENT_HUMAN_STREAM_NO_MINT:-0}" != "1" ]]; then
  SESSION_ID=$( (uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())') | tr 'A-Z' 'a-z')
elif [[ -n "$RESUME" && "$FORK" -eq 0 ]]; then
  SESSION_ID="$RESUME"
fi

# Land jobs: the model must block in run_terminal_command, not hand the wait
# to a background monitor (that ends the -p turn: sumelabs/sume#5706 R4).
if [[ "$BACKEND" == "grok" && -n "$UNTIL_LANDED$UNTIL_REGEX" && "$ALLOW_MONITOR" -eq 0 && "$_has_disallowed_tools" -eq 0 ]]; then
  EXTRA+=(--disallowed-tools "monitor,scheduler_create,scheduler_delete")
fi

CMD_BASE=()
if [[ "$BACKEND" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "error: claude not on PATH (want tokenmaxxing supervisor on this desk)" >&2
    exit 127
  fi
  CMD_BASE=(claude --output-format stream-json --verbose)
  if [[ "$_has_permission_mode" -eq 0 ]]; then
    CMD_BASE+=(--permission-mode bypassPermissions)
  fi
else
  if ! command -v grok >/dev/null 2>&1; then
    echo "error: grok not on PATH. Install Grok Build: curl -fsSL https://x.ai/cli/install.sh | bash" >&2
    exit 127
  fi
  CMD_BASE=(grok)
  if [[ "$_has_output_format" -eq 0 ]]; then
    CMD_BASE+=(--output-format streaming-messages-json)
  fi
  if [[ "$_has_permission_mode" -eq 0 ]]; then
    CMD_BASE+=(--permission-mode bypassPermissions)
  fi
  if [[ "$_has_always_approve" -eq 0 ]]; then
    CMD_BASE+=(--always-approve)
  fi
  CMD_BASE+=(--no-auto-update)
fi
# Claude /resume picker; Grok has no --name display flag — keep it in our logs only.
if [[ -n "$NAME" && "$BACKEND" == "claude" ]]; then
  CMD_BASE+=(--name "$NAME")
fi
CMD_BASE+=("${EXTRA[@]+"${EXTRA[@]}"}")

# First run: prompt + session flags. Grok reads the prompt file natively
# (prompt stays out of `ps` / tokenmaxxing.log; no ARG_MAX ceiling).
CMD=("${CMD_BASE[@]}")
if [[ "$BACKEND" == "grok" && -n "$PROMPT_FILE" ]]; then
  CMD+=(--prompt-file "$PROMPT_FILE")
else
  CMD+=(-p "$PROMPT")
fi
if [[ -n "$RESUME" ]]; then
  CMD+=(--resume "$RESUME")
elif [[ "$CONTINUE" -eq 1 ]]; then
  CMD+=(--continue)
elif [[ -n "$SESSION_ID" ]]; then
  CMD+=(--session-id "$SESSION_ID")
fi
if [[ "$FORK" -eq 1 ]]; then
  CMD+=(--fork-session)
fi

PROMPT_HEAD=$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-200)
GROK_VERSION=""
if [[ "$BACKEND" == "grok" ]]; then
  GROK_VERSION=$(grok --version 2>/dev/null | head -1 | awk '{print $2}' || true)
fi

export AGENT_HUMAN_STREAM_BACKEND="$BACKEND"
export AGENT_HUMAN_STREAM_MODEL="${_resolved_model:-}"
export AGENT_HUMAN_STREAM_EFFORT="${_effort:-}"
export AGENT_HUMAN_STREAM_PROMPT_HEAD="$PROMPT_HEAD"
export AGENT_HUMAN_STREAM_NAME="$NAME"
export AGENT_HUMAN_STREAM_REGISTRY="$REGISTRY"
export AGENT_HUMAN_STREAM_PID="$$"
AGENT_HUMAN_STREAM_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
export AGENT_HUMAN_STREAM_PGID
export AGENT_HUMAN_STREAM_CWD="$PWD"
export AGENT_HUMAN_STREAM_SESSION_ID="$SESSION_ID"
export AGENT_HUMAN_STREAM_GROK_VERSION="$GROK_VERSION"
export AGENT_HUMAN_STREAM_WALL_TIMEOUT="$WALL_TIMEOUT"
export AGENT_HUMAN_STREAM_UNTIL_LANDED="$UNTIL_LANDED"
export AGENT_HUMAN_STREAM_RESUME_FROM="${RESUME:-}"
if [[ "$CONTINUE" -eq 1 ]]; then
  export AGENT_HUMAN_STREAM_RESUME_FROM="${AGENT_HUMAN_STREAM_RESUME_FROM:-continue}"
fi
# Legacy names so a leftover claude-human-stream.py still tees correctly.
export CLAUDE_HUMAN_STREAM_BACKEND="$BACKEND"
export CLAUDE_HUMAN_STREAM_MODEL="$AGENT_HUMAN_STREAM_MODEL"
export CLAUDE_HUMAN_STREAM_EFFORT="$AGENT_HUMAN_STREAM_EFFORT"
export CLAUDE_HUMAN_STREAM_PROMPT_HEAD="$PROMPT_HEAD"
export CLAUDE_HUMAN_STREAM_NAME="$NAME"
export CLAUDE_HUMAN_STREAM_REGISTRY="$REGISTRY"
export CLAUDE_HUMAN_STREAM_PID="$$"
export CLAUDE_HUMAN_STREAM_CWD="$PWD"
export CLAUDE_HUMAN_STREAM_RESUME_FROM="$AGENT_HUMAN_STREAM_RESUME_FROM"

mkdir -p "$LIVE_DIR"
LIVE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LIVE_LABEL="${NAME:-$BACKEND}"
LIVE_LABEL=${LIVE_LABEL//[^a-zA-Z0-9._-]/_}
if [[ -n "$RESUME" ]]; then
  LIVE_LABEL="${LIVE_LABEL}-resume-${RESUME:0:8}"
elif [[ -n "$SESSION_ID" ]]; then
  LIVE_LABEL="${LIVE_LABEL}-${SESSION_ID:0:8}"
fi
LIVE_LOG="$LIVE_DIR/${LIVE_STAMP}-${LIVE_LABEL}.log"
: >"$LIVE_LOG"
ln -sfn "$LIVE_LOG" "$LIVE_DIR/LATEST.log"
if [[ -n "$NAME" ]]; then
  # Parallel jobs: LATEST.log follows the newest launch of any job; this one follows this job.
  ln -sfn "$LIVE_LOG" "$LIVE_DIR/LATEST-${NAME//[^a-zA-Z0-9._-]/_}.log"
fi
export AGENT_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"
export CLAUDE_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"

mkdir -p "$(dirname "$REGISTRY")"
python3 "$ROOT/agent-registry.py" start || true

echo "backend: $BACKEND" >&2
if [[ -n "$SESSION_ID" ]]; then
  echo "📎 session_id=$SESSION_ID  backend=$BACKEND${NAME:+  name=$NAME}  (pre-assigned)" >&2
fi
echo "👁 live_log: $LIVE_LOG" >&2
echo "👁 watch:    tail -f $(printf %q "$LIVE_LOG")" >&2
echo "👁 latest:   tail -f $(printf %q "$LIVE_DIR/LATEST.log")" >&2

# ---------- runtime: traps, watchdog, caffeinate, run_once, land-loop ----------
RC_DIR=$(mktemp -d)
RC_FILE="$RC_DIR/rc"
CYCLE=0
LANDED=""
ABORTED=0
WATCHDOG_PID=""
PIPE_PID=""
CHILD_PID=""

live_note() {
  printf '%s\n' "$1" | tee -a "$LIVE_LOG"
}

# Kill this wrapper's own process tree only (subshell → tokenmaxxing supervisor
# → raw grok child, tee, formatter, caffeinate). Never `agent-holders kill`
# here: a steer that replaces us also holds the uuid, and we would kill it.
kill_tree() {
  local sig="$1" pid="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$sig" "$child"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

cleanup_children() {
  local child
  for child in $(pgrep -P $$ 2>/dev/null || true); do
    kill_tree TERM "$child"
  done
  if [[ -n "$CHILD_PID" ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
  sleep 1
  for child in $(pgrep -P $$ 2>/dev/null || true); do
    kill_tree KILL "$child"
  done
  if [[ -n "$CHILD_PID" ]]; then
    kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
}

on_term() {
  ABORTED=1
  live_note "⛔ ${1}: stopping ${BACKEND} session ${SESSION_ID:-?}${LANDED:+ (landed=$LANDED)}" >&2
  cleanup_children
  exit 143
}
trap 'on_term INT' INT
trap 'on_term TERM' TERM

on_exit() {
  local rc=$?
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  python3 "$ROOT/agent-registry.py" exit --exit-code "$rc" --aborted "$ABORTED" \
    --landed "${LANDED:-}" --cycles "$CYCLE" --child-pid "${CHILD_PID:-}" 2>/dev/null || true
  rm -rf "$RC_DIR"
}
trap on_exit EXIT

dur_to_secs() {
  local d="$1"
  case "$d" in
    *h) echo $(( ${d%h} * 3600 )) ;;
    *m) echo $(( ${d%m} * 60 )) ;;
    *s) echo "${d%s}" ;;
    *) echo "$d" ;;
  esac
}

if [[ -n "$WALL_TIMEOUT" ]]; then
  _secs=$(dur_to_secs "$WALL_TIMEOUT")
  ( sleep "$_secs"; printf '⏰ wall-timeout %s reached\n' "$WALL_TIMEOUT" >> "$LIVE_LOG"; kill -TERM $$ 2>/dev/null ) &
  WATCHDOG_PID=$!
fi

if [[ "$NO_CAFFEINATE" != "1" && "$(uname -s)" == "Darwin" ]] && command -v caffeinate >/dev/null 2>&1; then
  # Laptop idle sleep froze land polls for 48 min on #5697 (auth.sleep.gate_set).
  caffeinate -i -w $$ >/dev/null 2>&1 &
fi

INIT_TIMEOUT="${AGENT_HUMAN_STREAM_INIT_TIMEOUT:-90}"
INIT_HUNG=0

# The formatter prints "📎 session_id=" on the first event. A Grok resume that
# hangs in session_create prints nothing forever (sumelabs/sume#5706 R2); do
# not let that become a silent empty live log.
init_watchdog() {
  local before="$1" deadline=$(( $(date +%s) + INIT_TIMEOUT ))
  while kill -0 "$PIPE_PID" 2>/dev/null; do
    if [[ "$(grep -c '^📎 session_id=' "$LIVE_LOG" 2>/dev/null || echo 0)" -gt "$before" ]]; then
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      INIT_HUNG=1
      live_note "❌ no output from $BACKEND in ${INIT_TIMEOUT}s (session_create hang? resume of an open-turn session?) — killing" >&2
      cleanup_children
      return 0
    fi
    sleep 1
  done
}

run_once() {
  : > "$RC_FILE"
  local before
  before=$(grep -c '^📎 session_id=' "$LIVE_LOG" 2>/dev/null || echo 0)
  ( set +e; "$@" 2> >(tee -a "$LIVE_LOG.stderr" >&2); echo $? > "$RC_FILE" ) \
    | python3 -u "$ROOT/agent-human-stream.py" &
  PIPE_PID=$!
  if [[ -n "$SESSION_ID" && -z "$CHILD_PID" ]]; then
    sleep 1.5
    CHILD_PID=$("$ROOT/agent-holders.sh" list "$SESSION_ID" 2>/dev/null \
      | awk -F'\t' '$3 ~ /grok-[0-9]|\/claude |claude -p/ {print $1; exit}' || true)
    [[ -n "$CHILD_PID" ]] && echo "👁 child_pid: $CHILD_PID" >&2
  fi
  init_watchdog "$before"
  wait "$PIPE_PID" 2>/dev/null || true
  PIPE_PID=""
  if [[ "$INIT_HUNG" -eq 1 ]]; then
    INIT_HUNG=0
    return 5
  fi
  local rc
  rc=$(cat "$RC_FILE" 2>/dev/null || true)
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

registry_session_for_pid() {
  python3 - "$REGISTRY" "$$" <<'PYREG' 2>/dev/null || true
import json, sys
path, pid = sys.argv[1], int(sys.argv[2])
found = ""
try:
    for line in open(path, encoding="utf-8"):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("pid") == pid and rec.get("event") == "session" and rec.get("session_id"):
            found = rec["session_id"]
except OSError:
    pass
print(found)
PYREG
}

last_final() {
  awk '/^—— final ——$/ { f = 1; buf = ""; next } f { buf = buf $0 "\n" } END { printf "%s", buf }' "$LIVE_LOG"
}

land_proof() {
  if [[ -n "$UNTIL_LANDED" ]]; then
    git fetch origin main -q 2>/dev/null || true
    git log origin/main --oneline --grep="(#${UNTIL_LANDED})" 2>/dev/null | grep -q . && return 0
  fi
  if [[ -n "$UNTIL_REGEX" ]]; then
    last_final | grep -Eq "$UNTIL_REGEX" && return 0
  fi
  return 1
}

set +e
run_once "${CMD[@]}"
rc=$?
set -e
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID=$(registry_session_for_pid)
  export AGENT_HUMAN_STREAM_SESSION_ID="$SESSION_ID"
fi

if [[ -n "$UNTIL_LANDED$UNTIL_REGEX" ]]; then
  while :; do
    if land_proof; then
      LANDED=yes
      if [[ -n "$UNTIL_LANDED" ]]; then
        live_note "LANDED: yes — origin/main has (#${UNTIL_LANDED}) [land-loop cycles=${CYCLE}]"
      else
        live_note "LANDED: yes — final matched /${UNTIL_REGEX}/ [land-loop cycles=${CYCLE}]"
      fi
      rc=0
      break
    fi
    if [[ "$rc" -ne 0 ]]; then
      LANDED=no
      live_note "LANDED: no — worker exited rc=${rc} before proof [land-loop cycles=${CYCLE}]"
      break
    fi
    if [[ "$CYCLE" -ge "$MAX_CYCLES" ]]; then
      LANDED=no
      live_note "LANDED: no — land-loop bound ${MAX_CYCLES} cycles reached without (#${UNTIL_LANDED:-regex}) proof"
      rc=4
      break
    fi
    if [[ -z "$SESSION_ID" ]]; then
      LANDED=no
      live_note "LANDED: no — no session id to resume"
      rc=4
      break
    fi
    CYCLE=$((CYCLE + 1))
    live_note "↻ land-loop cycle ${CYCLE}/${MAX_CYCLES} — no proof yet; resuming ${SESSION_ID} in ${CYCLE_SLEEP}s"
    sleep "$CYCLE_SLEEP"
    CONT="$RC_DIR/continue-${CYCLE}.md"
    {
      echo "# land-loop continuation (cycle ${CYCLE}/${MAX_CYCLES}) — same session"
      if [[ -n "$UNTIL_LANDED" ]]; then
        echo "PR #${UNTIL_LANDED} is NOT on origin/main yet: \`git log origin/main --oneline --grep='(#${UNTIL_LANDED})'\` is empty."
      else
        echo "Your last final did not match /${UNTIL_REGEX}/."
      fi
      echo "Keep babysitting in this turn: check the merge-queue label, the MQ draft CI, and Graphite merge activity."
      echo "Eject → re-label \`merge-queue\`. Known flake → ≤2 \`gh run rerun --failed\`, then minimal CI unblock."
      echo "Do NOT call monitor / scheduler tools. Block with run_terminal_command (≤10 min slices, sleep between polls)."
      if [[ -n "$UNTIL_LANDED" ]]; then
        echo "When the grep hits, reply \`LANDED: yes\` + the main line. Otherwise end with one status line; this wrapper will re-prompt you."
      else
        echo "When done, reply with a final matching /${UNTIL_REGEX}/. Otherwise end with one status line; this wrapper will re-prompt you."
      fi
    } > "$CONT"
    set +e
    run_once "${CMD_BASE[@]}" --prompt-file "$CONT" --resume "$SESSION_ID"
    rc=$?
    set -e
  done
fi

exit "$rc"
