#!/usr/bin/env bash
# Start ONE named worker job on this host from cron (Mac Mini, user chasehuh).
# Same detached shape as `sume-bg-launch --host mini`, minus the laptop:
# it stages the prompt and calls `sume-bg-remote start` locally. No second
# agent runner, no ssh, no attach.
#
#   sume-cron-job --name <slug> [--backend claude] [--cwd <dir>] [-- backend flags…]
#
# Prompt:  ~/.cstack/cron/<slug>.md   (fixed path; never in the crontab line)
# Log:     ~/.cstack/state/cron/<slug>.log (one line per fire: started|skip|error)
# Default backend flags (claude): --model claude-opus-5-5 --effort medium
#
# One live job per slug: if a remote-jobs/<stamp>-<slug> job is still alive,
# the fire is skipped (exit 0). Refuses inside a worker session (exit 5).
# Liveness: `sume-bg-remote jobs` here, `sume-bg-launch --host mini --jobs`
# from the laptop. Docs: docs/MINI-CRON.md
set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"

CSTACK_STATE="${CSTACK_STATE:-$HOME/.cstack/state}"
JOBS_DIR="${SUME_BG_REMOTE_JOBS_DIR:-$CSTACK_STATE/remote-jobs}"
CRON_DIR="${SUME_CRON_DIR:-$HOME/.cstack/cron}"
CRON_LOG_DIR="${SUME_CRON_LOG_DIR:-$CSTACK_STATE/cron}"
REMOTE="${SUME_BG_REMOTE_BIN:-$ROOT/sume-bg-remote.sh}"

NAME=""
BACKEND="claude"
CWD="$HOME"
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME=${2:-}; shift 2 ;;
    --backend) BACKEND=${2:-}; shift 2 ;;
    --cwd) CWD=${2:-}; shift 2 ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) sed -n '2,16p' "$SOURCE" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sume-cron-job: error: unknown option $1" >&2; exit 2 ;;
  esac
done

[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "sume-cron-job: error: --name <slug> required ([a-zA-Z0-9._-])" >&2; exit 2; }

mkdir -p "$CRON_LOG_DIR"
LOG="$CRON_LOG_DIR/$NAME.log"
say() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$*" | tee -a "$LOG"; }
fail() { say "error: $2" >&2; exit "$1"; }

# Same guard as sume-bg-launch (sume#7839): a worker never schedules workers.
if [[ -n "${SUME_WORKER_SESSION:-}${AGENT_HUMAN_STREAM_PID:-}${SUME_BG_REMOTE_JOB:-}" && "${SUME_BG_ALLOW_NESTED:-0}" != "1" ]]; then
  fail 5 "refusing: inside a worker session (${SUME_WORKER_SESSION:-${SUME_BG_REMOTE_JOB:-?}}); cron jobs start from crontab only"
fi

PROMPT="$CRON_DIR/$NAME.md"
[[ -s "$PROMPT" ]] || fail 2 "no prompt at $PROMPT"
if grep -Eq 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "$PROMPT"; then
  fail 2 "prompt $PROMPT looks like it contains a credential; refusing"
fi
if [[ ${#EXTRA[@]} -eq 0 && "$BACKEND" == "claude" ]]; then
  EXTRA=(--model claude-opus-5-5 --effort medium)
fi

# cron runs with SHELL=/bin/sh; sume-bg-remote builds the worker PATH from
# `$SHELL -lic`, so hand it the login shell the ssh path would have used.
if [[ "${SHELL:-/bin/sh}" == "/bin/sh" ]]; then
  SHELL=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}' || true)
  export SHELL="${SHELL:-/bin/zsh}"
fi

# Check-and-start under a per-slug lock so overlapping fires cannot both start.
mkdir -p "$JOBS_DIR"
LOCK="$JOBS_DIR/.cron-$NAME.lock"
# A fire takes seconds; a lock older than 10 min is from a killed fire.
find "$LOCK" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null || true
if ! mkdir "$LOCK" 2>/dev/null; then
  say "skip: another fire holds $LOCK"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

for d in "$JOBS_DIR"/*-"$NAME"/; do
  [[ -d "$d" ]] || continue
  id=$(basename "$d")
  [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-${NAME//./\\.}$ ]] || continue
  if "$REMOTE" status --job "$id" 2>/dev/null | grep -q ' alive=yes '; then
    say "skip: job $id still alive"
    exit 0
  fi
done

JOB="$(date -u +%Y%m%dT%H%M%SZ)-$NAME"
"$REMOTE" prep --job "$JOB" >/dev/null
cp "$PROMPT" "$JOBS_DIR/$JOB/prompt.md"
START=(start --job "$JOB" --backend "$BACKEND" --name "$NAME" --cwd "$CWD")
if [[ ${#EXTRA[@]} -gt 0 ]]; then START+=(-- "${EXTRA[@]}"); fi
out=$("$REMOTE" "${START[@]}") || fail 1 "start failed for job $JOB"
say "started: $out"
