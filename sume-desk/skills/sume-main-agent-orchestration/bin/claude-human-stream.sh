#!/usr/bin/env bash
# Human-readable wrapper around `claude -p --output-format stream-json`.
#
# Fresh Opus worker:
#   claude-human-stream "Audit #1708 …"
#   claude-human-stream --name "audit-1708" "Audit #1708 …"
#
# Resume the same Claude session (Cursor-Task-like follow-up):
#   claude-human-stream --resume <uuid> "Follow-up: also check X"
#   CLAUDE_RESUME_SESSION=<uuid> claude-human-stream "Follow-up …"
#
# Continue most recent session in this cwd (weaker than explicit uuid):
#   claude-human-stream --continue "Follow-up …"
#
# Fork (new session id, copy of history) while resuming:
#   claude-human-stream --resume <uuid> --fork-session "Try a different approach"
#
# Extra claude flags still go after the prompt:
#   claude-human-stream "…" --model opus --effort medium
#
# List recent Opus launches recorded by this wrapper:
#   claude-human-stream --sessions
#
# On stream start/end the formatter prints:
#   📎 session_id=<uuid>
# and again just above —— final —— so the main agent can store/resume it.
# Human progress is also teed to state/opus-live/<name>.log (tail -f).
# Optional registry (no secrets): ~/.agents/skills/sume-main-agent-orchestration/state/opus-sessions.jsonl
set -euo pipefail

# Resolve symlinks so PATH installs (e.g. ~/.local/bin/claude-human-stream) still find the .py sibling.
SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"
SKILL_DIR="$(cd "$ROOT/.." && pwd)"
REGISTRY="${CLAUDE_HUMAN_STREAM_REGISTRY:-$SKILL_DIR/state/opus-sessions.jsonl}"
LIVE_DIR="${CLAUDE_HUMAN_STREAM_LIVE_DIR:-$SKILL_DIR/state/opus-live}"

usage() {
  cat <<'EOF'
Human-readable wrapper around `claude -p --output-format stream-json`.

Fresh Opus worker:
  claude-human-stream "Audit #1708 …"
  claude-human-stream --name "audit-1708" "Audit #1708 …"

Resume the same Claude session (Cursor-Task-like follow-up):
  claude-human-stream --resume <uuid> "Follow-up: also check X"
  CLAUDE_RESUME_SESSION=<uuid> claude-human-stream "Follow-up …"

Continue most recent session in this cwd (weaker than explicit uuid):
  claude-human-stream --continue "Follow-up …"

Fork (new session id, copy of history) while resuming:
  claude-human-stream --resume <uuid> --fork-session "Try a different approach"

Extra claude flags still go after the prompt:
  claude-human-stream "…" --model opus --effort medium

List recent Opus launches recorded by this wrapper:
  claude-human-stream --sessions

Watch human progress while a background/resume run is going:
  tail -f ~/.agents/skills/sume-main-agent-orchestration/state/opus-live/LATEST.log
  # or the path printed as: live_log: …

On stream start/end the formatter prints:
  📎 session_id=<uuid>
and again just above —— final —— so the main agent can store/resume it.
Optional registry (no secrets):
  ~/.agents/skills/sume-main-agent-orchestration/state/opus-sessions.jsonl

Environment:
  CLAUDE_RESUME_SESSION=<uuid>   Same as --resume (ignored if --resume is set)
  CLAUDE_HUMAN_STREAM_REGISTRY   Override registry path (default: skill state/)
  CLAUDE_HUMAN_STREAM_LIVE_DIR   Override live log dir (default: state/opus-live/)

Claude facts (claude --help):
  -r/--resume [session-id]   Resume by uuid, or interactive picker without -p
  -c/--continue              Most recent conversation in current directory
  --fork-session             With resume/continue: new session id, keep history
  -n/--name <label>          Display name (/resume picker, terminal title)
  --session-id <uuid>        Force id for a *new* session (not for resume)
  --no-session-persistence   Do not save (cannot resume later; print mode only)
  --bg                       Background agent (manage with `claude agents`)
EOF
}

RESUME="${CLAUDE_RESUME_SESSION:-}"
NAME=""
CONTINUE=0
FORK=0
LIST_SESSIONS=0
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
      echo "error: unknown wrapper option: $1 (wrapper flags before prompt; claude flags after)" >&2
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
  # Newest last; show last 30 lines.
  tail -n 30 "$REGISTRY"
  exit 0
fi

if [[ -z "$PROMPT" ]]; then
  echo "error: missing prompt" >&2
  echo "usage: $0 [--resume <uuid>|--continue] [--name <label>] [--fork-session] <prompt> [claude args...]" >&2
  echo "       $0 --sessions" >&2
  exit 2
fi

if [[ -n "$RESUME" && "$CONTINUE" -eq 1 ]]; then
  echo "error: use either --resume <uuid> or --continue, not both" >&2
  exit 2
fi

CLAUDE_ARGS=(-p "$PROMPT" --output-format stream-json --verbose --permission-mode bypassPermissions)

if [[ -n "$RESUME" ]]; then
  CLAUDE_ARGS+=(--resume "$RESUME")
fi
if [[ "$CONTINUE" -eq 1 ]]; then
  CLAUDE_ARGS+=(--continue)
fi
if [[ "$FORK" -eq 1 ]]; then
  CLAUDE_ARGS+=(--fork-session)
fi
if [[ -n "$NAME" ]]; then
  CLAUDE_ARGS+=(--name "$NAME")
fi

# Default effort medium unless the caller already passed --effort.
has_effort=0
for a in "${EXTRA[@]+"${EXTRA[@]}"}"; do
  if [[ "$a" == "--effort" || "$a" == --effort=* ]]; then
    has_effort=1
    break
  fi
done
if [[ "$has_effort" -eq 0 ]]; then
  EXTRA=(--effort medium "${EXTRA[@]+"${EXTRA[@]}"}")
fi

# Passthrough remaining claude flags (after prompt).
CLAUDE_ARGS+=("${EXTRA[@]+"${EXTRA[@]}"}")

PROMPT_HEAD=$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-200)

export CLAUDE_HUMAN_STREAM_PROMPT_HEAD="$PROMPT_HEAD"
export CLAUDE_HUMAN_STREAM_NAME="$NAME"
export CLAUDE_HUMAN_STREAM_REGISTRY="$REGISTRY"
export CLAUDE_HUMAN_STREAM_PID="$$"
export CLAUDE_HUMAN_STREAM_CWD="$PWD"
export CLAUDE_HUMAN_STREAM_RESUME_FROM="${RESUME:-}"
if [[ "$CONTINUE" -eq 1 ]]; then
  export CLAUDE_HUMAN_STREAM_RESUME_FROM="${CLAUDE_HUMAN_STREAM_RESUME_FROM:-continue}"
fi

# Live human log so people (and main agent on request) can watch resume/background runs.
mkdir -p "$LIVE_DIR"
LIVE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LIVE_LABEL="${NAME:-opus}"
LIVE_LABEL=${LIVE_LABEL//[^a-zA-Z0-9._-]/_}
if [[ -n "$RESUME" ]]; then
  LIVE_LABEL="${LIVE_LABEL}-resume-${RESUME:0:8}"
fi
LIVE_LOG="$LIVE_DIR/${LIVE_STAMP}-${LIVE_LABEL}.log"
: >"$LIVE_LOG"
ln -sfn "$LIVE_LOG" "$LIVE_DIR/LATEST.log"
export CLAUDE_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"

# Start stub in registry (session_id filled by the formatter when seen).
mkdir -p "$(dirname "$REGISTRY")"
python3 - <<'PY' || true
import json, os, time
path = os.environ["CLAUDE_HUMAN_STREAM_REGISTRY"]
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "event": "start",
    "session_id": None,
    "cwd": os.environ.get("CLAUDE_HUMAN_STREAM_CWD") or os.getcwd(),
    "name": os.environ.get("CLAUDE_HUMAN_STREAM_NAME") or None,
    "prompt_head": os.environ.get("CLAUDE_HUMAN_STREAM_PROMPT_HEAD") or None,
    "pid": int(os.environ.get("CLAUDE_HUMAN_STREAM_PID") or "0") or None,
    "resume_from": os.environ.get("CLAUDE_HUMAN_STREAM_RESUME_FROM") or None,
    "live_log": os.environ.get("CLAUDE_HUMAN_STREAM_LIVE_LOG") or None,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

echo "👁 live_log: $LIVE_LOG" >&2
echo "👁 watch:    tail -f $(printf %q "$LIVE_LOG")" >&2
echo "👁 latest:   tail -f $(printf %q "$LIVE_DIR/LATEST.log")" >&2

claude "${CLAUDE_ARGS[@]}" | python3 -u "$ROOT/claude-human-stream.py"
