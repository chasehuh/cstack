#!/usr/bin/env bash
# Cursor background-worker launcher. Reads the prompt from a file (no $(cat)
# race) and, on --resume, stops every process still holding that session
# (wrapper, tokenmaxxing supervisor, raw grok/claude child) before relaunching.
#
#   sume-bg-launch --backend grok --name job-slug --resume <uuid> \
#     --prompt-file /tmp/sume-grok-prompts/job.md -- --effort high
#
# Shell: description = "Grok : <job-slug> (#N)", block_until_ms = 0.
# After spawn: read the terminal once for 📎 session_id= or exit_code.
set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"

BACKEND="grok"
NAME=""
RESUME=""
PROMPT_FILE=""
EXTRA=()

usage() {
  cat <<'EOF'
sume-bg-launch --backend grok|claude --name <slug> --prompt-file <path> \
  [--resume <uuid>] -- [backend flags…]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --backend)
      BACKEND=$2
      shift 2
      ;;
    --name)
      NAME=$2
      shift 2
      ;;
    --resume)
      RESUME=$2
      shift 2
      ;;
    --prompt-file)
      PROMPT_FILE=$2
      shift 2
      ;;
    --)
      shift
      EXTRA=("$@")
      break
      ;;
    *)
      echo "error: unknown option $1 (backend flags go after --)" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "error: --name is required" >&2
  exit 2
fi
if [[ -z "$PROMPT_FILE" ]]; then
  echo "error: --prompt-file is required" >&2
  exit 2
fi
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "error: --prompt-file not found: $PROMPT_FILE" >&2
  exit 2
fi
if [[ ! -s "$PROMPT_FILE" ]]; then
  echo "error: --prompt-file is empty: $PROMPT_FILE" >&2
  exit 2
fi

# Steer: one live holder per session. agent-holders keys on the
# `--resume <uuid>` / `--session-id <uuid>` argv tokens, kills the whole
# process group (wrapper + tokenmaxxing supervisor + raw grok/claude child)
# and waits for release. gt merge / gt submit processes are never touched.
# Refuse to launch a second concurrent resume: that is the empty-live-log
# hang (sumelabs/sume#5706 R1-R3).
if [[ -n "$RESUME" ]]; then
  if ! "$ROOT/agent-holders.sh" kill "$RESUME"; then
    echo "error: session $RESUME is still held by a live process; not launching a second resume" >&2
    exit 3
  fi
fi

WRAPPER="${SUME_BG_LAUNCH_WRAPPER:-$(command -v agent-human-stream)}"
if [[ -z "$WRAPPER" ]]; then
  echo "error: agent-human-stream not on PATH" >&2
  exit 127
fi

CMD=("$WRAPPER" --backend "$BACKEND" --name "$NAME" --prompt-file "$PROMPT_FILE")
if [[ -n "$RESUME" ]]; then
  CMD+=(--resume "$RESUME")
fi
if [[ ${#EXTRA[@]} -gt 0 ]]; then
  CMD+=("${EXTRA[@]}")
fi

echo "launch: ${CMD[*]}" >&2
exec "${CMD[@]}"
