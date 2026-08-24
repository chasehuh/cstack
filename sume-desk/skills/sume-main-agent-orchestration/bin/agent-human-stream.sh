#!/usr/bin/env bash
# Human-readable wrapper for Claude Code and Grok Build headless streams.
#
#   agent-human-stream "Audit #1708 …"
#   agent-human-stream --backend grok --name land-4414 "Watch MQ …"
#   agent-human-stream --resume <uuid> "Follow-up …"
#   claude-human-stream "…"          # alias: --backend claude
#
# Extra backend flags go after the prompt:
#   agent-human-stream "…" --model opus
#   agent-human-stream --backend grok "…" --model grok-4.6 --effort high
set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"
SKILL_DIR="$(cd "$ROOT/.." && pwd)"
REGISTRY="${AGENT_HUMAN_STREAM_REGISTRY:-${CLAUDE_HUMAN_STREAM_REGISTRY:-$SKILL_DIR/state/opus-sessions.jsonl}}"
LIVE_DIR="${AGENT_HUMAN_STREAM_LIVE_DIR:-${CLAUDE_HUMAN_STREAM_LIVE_DIR:-$SKILL_DIR/state/opus-live}}"

usage() {
  cat <<'EOF'
Human-readable wrapper around Claude Code and Grok Build headless NDJSON.

  agent-human-stream [--backend claude|grok|auto] [--name <slug>] <prompt> [backend flags…]
  agent-human-stream --claude "…"                 # same as --backend claude
  agent-human-stream --grok "…"                   # same as --backend grok
  agent-human-stream --resume <uuid> "Follow-up"
  agent-human-stream --sessions
  agent-human-stream --self-test

Auto backend (default):
  --backend grok / --grok / AGENT_HUMAN_STREAM_BACKEND=grok
  --model grok*  → grok
  --model opus|fable|sonnet|haiku|claude* → claude
  --resume <uuid> uses the last backend recorded for that session
  otherwise → claude (Opus/Fable path unchanged)

Claude (tokenmaxxing `claude` on this desk):
  claude -p … --output-format stream-json --verbose --permission-mode bypassPermissions
  Default --effort when omitted (code lane): opus → medium, fable → high,
  grok → xhigh. Research must pass --effort (grok mid / opus+fable low).

Grok Build (`grok` on PATH):
  grok -p … --output-format streaming-messages-json --permission-mode bypassPermissions --always-approve
  Native ACP streaming-json is also accepted by the formatter if you pass
  --output-format streaming-json after the prompt.

Resume:
  --resume <uuid>   | AGENT_RESUME_SESSION / CLAUDE_RESUME_SESSION / GROK_RESUME_SESSION
  --continue        most recent session in this cwd
  --fork-session    new session id, copy history

Watch:
  tail -f ~/.agents/skills/sume-main-agent-orchestration/state/opus-live/LATEST.log

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
EXTRA=()

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
  exec python3 "$ROOT/agent-human-stream.test.py"
fi

if [[ -z "$PROMPT" ]]; then
  echo "error: missing prompt" >&2
  echo "usage: $0 [--backend claude|grok|auto] [--resume <uuid>|--continue] [--name <label>] <prompt> [backend args...]" >&2
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

_effort="$_passed_effort"
if [[ "$BACKEND" == "claude" && "$_has_effort" -eq 0 ]]; then
  _model_lc=$(printf '%s' "${_resolved_model:-opus}" | tr '[:upper:]' '[:lower:]')
  case "$_model_lc" in
    fable|fable*|claude-fable*)
      _effort="${CLAUDE_HUMAN_STREAM_EFFORT_FABLE:-${AGENT_HUMAN_STREAM_EFFORT_FABLE:-high}}"
      ;;
    *)
      _effort="${CLAUDE_HUMAN_STREAM_EFFORT_OPUS:-${AGENT_HUMAN_STREAM_EFFORT_OPUS:-medium}}"
      ;;
  esac
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for model=${_resolved_model:-opus}; override with --effort)" >&2
elif [[ "$BACKEND" == "grok" && "$_has_effort" -eq 0 ]]; then
  _effort="${AGENT_HUMAN_STREAM_EFFORT_GROK:-xhigh}"
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for grok code lane; research → --effort mid)" >&2
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
    esac
    _filtered+=("$_a")
    _i=$((_i + 1))
  done
  EXTRA=("${_filtered[@]+"${_filtered[@]}"}")
fi

CMD=()
if [[ "$BACKEND" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "error: claude not on PATH (want tokenmaxxing supervisor on this desk)" >&2
    exit 127
  fi
  CMD=(claude -p "$PROMPT" --output-format stream-json --verbose)
  if [[ "$_has_permission_mode" -eq 0 ]]; then
    CMD+=(--permission-mode bypassPermissions)
  fi
else
  if ! command -v grok >/dev/null 2>&1; then
    echo "error: grok not on PATH. Install Grok Build: curl -fsSL https://x.ai/cli/install.sh | bash" >&2
    exit 127
  fi
  CMD=(grok -p "$PROMPT")
  if [[ "$_has_output_format" -eq 0 ]]; then
    CMD+=(--output-format streaming-messages-json)
  fi
  if [[ "$_has_permission_mode" -eq 0 ]]; then
    CMD+=(--permission-mode bypassPermissions)
  fi
  if [[ "$_has_always_approve" -eq 0 ]]; then
    CMD+=(--always-approve)
  fi
  CMD+=(--no-auto-update)
fi

if [[ -n "$RESUME" ]]; then
  CMD+=(--resume "$RESUME")
fi
if [[ "$CONTINUE" -eq 1 ]]; then
  CMD+=(--continue)
fi
if [[ "$FORK" -eq 1 ]]; then
  CMD+=(--fork-session)
fi
# Claude /resume picker; Grok has no --name display flag — keep it in our logs only.
if [[ -n "$NAME" && "$BACKEND" == "claude" ]]; then
  CMD+=(--name "$NAME")
fi

CMD+=("${EXTRA[@]+"${EXTRA[@]}"}")

PROMPT_HEAD=$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-200)

export AGENT_HUMAN_STREAM_BACKEND="$BACKEND"
export AGENT_HUMAN_STREAM_MODEL="${_resolved_model:-}"
export AGENT_HUMAN_STREAM_EFFORT="${_effort:-}"
export AGENT_HUMAN_STREAM_PROMPT_HEAD="$PROMPT_HEAD"
export AGENT_HUMAN_STREAM_NAME="$NAME"
export AGENT_HUMAN_STREAM_REGISTRY="$REGISTRY"
export AGENT_HUMAN_STREAM_PID="$$"
export AGENT_HUMAN_STREAM_CWD="$PWD"
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
fi
LIVE_LOG="$LIVE_DIR/${LIVE_STAMP}-${LIVE_LABEL}.log"
: >"$LIVE_LOG"
ln -sfn "$LIVE_LOG" "$LIVE_DIR/LATEST.log"
export AGENT_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"
export CLAUDE_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"

mkdir -p "$(dirname "$REGISTRY")"
python3 - <<'PY' || true
import json, os, time
path = os.environ["AGENT_HUMAN_STREAM_REGISTRY"]
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "event": "start",
    "backend": os.environ.get("AGENT_HUMAN_STREAM_BACKEND") or None,
    "session_id": None,
    "cwd": os.environ.get("AGENT_HUMAN_STREAM_CWD") or os.getcwd(),
    "name": os.environ.get("AGENT_HUMAN_STREAM_NAME") or None,
    "prompt_head": os.environ.get("AGENT_HUMAN_STREAM_PROMPT_HEAD") or None,
    "pid": int(os.environ.get("AGENT_HUMAN_STREAM_PID") or "0") or None,
    "resume_from": os.environ.get("AGENT_HUMAN_STREAM_RESUME_FROM") or None,
    "live_log": os.environ.get("AGENT_HUMAN_STREAM_LIVE_LOG") or None,
    "model": os.environ.get("AGENT_HUMAN_STREAM_MODEL") or None,
    "effort": os.environ.get("AGENT_HUMAN_STREAM_EFFORT") or None,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

echo "backend: $BACKEND" >&2
echo "👁 live_log: $LIVE_LOG" >&2
echo "👁 watch:    tail -f $(printf %q "$LIVE_LOG")" >&2
echo "👁 latest:   tail -f $(printf %q "$LIVE_DIR/LATEST.log")" >&2

"${CMD[@]}" | python3 -u "$ROOT/agent-human-stream.py"
