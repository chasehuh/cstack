#!/usr/bin/env bash
# Cursor background-worker launcher. Reads the prompt from a file (no $(cat)
# race) and, on --resume without --fork-session, stops older wrappers holding that session.
#
#   sume-bg-launch --backend grok --name job-slug --resume <uuid> \
#     --prompt-file /tmp/sume-grok-prompts/job.md -- --effort high
#   sume-bg-launch --backend codex --name job-slug \
#     --prompt-file /tmp/sume-codex-prompts/job.md -- --model gpt-5.5
#
# Worker host (cstack#10):
#   --host local   run the wrapper here (default when CSTACK_WORKER_HOST unset)
#   --host mini    scp the prompt to the Mac Mini, start the wrapper DETACHED
#                  there (sume-bg-remote), then attach: stream its log into
#                  the local replica ~/.cstack/state/opus-live/<job>.log.
#                  SSH is control plane only; laptop sleep / SSH drop does
#                  not kill the Mini job. Fails closed if the Mini is not
#                  reachable (never a silent local fallback).
#   Control plane: --attach <job> | --status <job> | --kill <job> | --jobs
#   Docs: docs/MINI-WORKER-HOST.md
#
# Shell: description = "Grok : <job-slug> (#N)" (or "Codex : …"), block_until_ms = 0.
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
FORK=0
PROMPT_FILE=""
EXTRA=()
HOST="${CSTACK_WORKER_HOST:-local}"
HOST_SET=0
CWD=""
ACTION="launch"
ACTION_JOB=""

# Local replica of the Mini's state (one writer per file: the Mini writes its
# own ~/.cstack/state; the laptop attach writes ONLY these replica files).
CSTACK_STATE="${CSTACK_STATE:-$HOME/.cstack/state}"
REGISTRY="${AGENT_HUMAN_STREAM_REGISTRY:-${CLAUDE_HUMAN_STREAM_REGISTRY:-$CSTACK_STATE/opus-sessions.jsonl}}"
LIVE_DIR="${AGENT_HUMAN_STREAM_LIVE_DIR:-${CLAUDE_HUMAN_STREAM_LIVE_DIR:-$CSTACK_STATE/opus-live}}"

# Mini host SoT: Tailscale name (ssh alias ok), never only .local Bonjour.
MINI_SSH="${CSTACK_MINI_SSH:-}"
MINI_REMOTE_BIN="${CSTACK_MINI_REMOTE_BIN:-.local/bin/sume-bg-remote}"
MINI_CONNECT_TIMEOUT="${CSTACK_MINI_CONNECT_TIMEOUT:-10}"
SSH_BIN="${SUME_BG_SSH:-ssh}"
SCP_BIN="${SUME_BG_SCP:-scp}"

usage() {
  cat <<'EOF'
sume-bg-launch --backend grok|claude|codex --name <slug> --prompt-file <path> \
  [--host local|mini] [--cwd <remote dir>] \
  [--resume <uuid> [--fork-session]] -- [backend flags…]

Mini control plane (--host mini):
  sume-bg-launch --host mini --attach <job>     # re-attach; rewrites the local replica log
  sume-bg-launch --host mini --status <job>     # alive = Mini process, not the replica file
  sume-bg-launch --host mini --kill <job>       # kill the detached worker on the Mini
  sume-bg-launch --host mini --jobs             # list Mini jobs

Env: CSTACK_WORKER_HOST=mini|local (default local), CSTACK_MINI_SSH=<user@tailscale-name>
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
    --fork-session)
      FORK=1
      shift
      ;;
    --prompt-file)
      PROMPT_FILE=$2
      shift 2
      ;;
    --host)
      HOST=$2
      HOST_SET=1
      shift 2
      ;;
    --host=*)
      HOST=${1#--host=}
      HOST_SET=1
      shift
      ;;
    --cwd)
      CWD=$2
      shift 2
      ;;
    --attach|--status|--kill)
      ACTION=${1#--}
      ACTION_JOB=${2:-}
      if [[ -z "$ACTION_JOB" ]]; then
        echo "error: $1 requires a <job> id (see --jobs)" >&2
        exit 2
      fi
      shift 2
      ;;
    --jobs)
      ACTION=jobs
      shift
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

HOST=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')
case "$HOST" in
  local|mini) ;;
  *)
    echo "error: --host must be local or mini (got: $HOST; CSTACK_WORKER_HOST=${CSTACK_WORKER_HOST:-})" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Registry helpers (host routing for --resume)
# ---------------------------------------------------------------------------

# Prints "<host>\t<job>\t<cwd>" for the newest registry row of a session.
# Rows without a host field are local (pre-cstack#10 launches).
session_route() {
  local sid="$1"
  [[ -n "$sid" && -f "$REGISTRY" ]] || return 0
  python3 - "$REGISTRY" "$sid" <<'PY'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
found = None
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
            if rec.get("session_id") == sid:
                found = rec
except OSError:
    pass
if found is not None:
    print("\t".join([
        str(found.get("host") or "local"),
        str(found.get("job") or ""),
        str(found.get("cwd") or ""),
    ]))
PY
}

replica_registry_append() {
  # $1 event, $2 session_id (may be empty), $3 remote_pid, $4 remote_cwd, $5 exit_code
  mkdir -p "$(dirname "$REGISTRY")"
  REPLICA_EVENT="$1" REPLICA_SID="${2:-}" REPLICA_PID="${3:-}" REPLICA_CWD="${4:-}" \
  REPLICA_RC="${5:-}" REPLICA_BACKEND="$BACKEND" REPLICA_NAME="$NAME" REPLICA_JOB="$JOB" \
  REPLICA_HOST_SSH="$MINI_SSH" REPLICA_LIVE_LOG="$LIVE_LOG" REPLICA_REMOTE_LOG="${REMOTE_LIVE_LOG:-}" \
  REPLICA_RESUME="${RESUME:-}" REPLICA_REGISTRY="$REGISTRY" \
  python3 - <<'PY' || true
import json, os, time
env = os.environ.get
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "event": env("REPLICA_EVENT"),
    "backend": env("REPLICA_BACKEND") or None,
    "session_id": env("REPLICA_SID") or None,
    "host": "mini",
    "remote_host": env("REPLICA_HOST_SSH") or None,
    "job": env("REPLICA_JOB") or None,
    "cwd": env("REPLICA_CWD") or None,
    "name": env("REPLICA_NAME") or None,
    "pid": None,
    "remote_pid": int(env("REPLICA_PID") or "0") or None,
    "resume_from": env("REPLICA_RESUME") or None,
    "live_log": env("REPLICA_LIVE_LOG") or None,
    "remote_live_log": env("REPLICA_REMOTE_LOG") or None,
    "exit_code": int(env("REPLICA_RC")) if (env("REPLICA_RC") or "").lstrip("-").isdigit() else None,
}
with open(env("REPLICA_REGISTRY"), "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
}

# ---------------------------------------------------------------------------
# Mini control plane
# ---------------------------------------------------------------------------

mini_require_config() {
  if [[ -z "$MINI_SSH" ]]; then
    echo "error: --host mini needs CSTACK_MINI_SSH=<user@tailscale-name> (docs/MINI-WORKER-HOST.md)" >&2
    exit 2
  fi
}

# ssh wrapper: BatchMode (no password prompt), bounded connect, keepalive so a
# dead link is noticed. Remote command args are shell-quoted for the Mini's
# login shell. Never put prompt text or tokens here.
mini_ssh() {
  local q=() a
  for a in "$@"; do
    q+=("$(printf '%q' "$a")")
  done
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$MINI_CONNECT_TIMEOUT" \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    "$MINI_SSH" -- "$MINI_REMOTE_BIN" "${q[@]}"
}

mini_fail_closed() {
  echo "error: Mini ($MINI_SSH) unreachable or sume-bg-remote missing there — refusing to run locally." >&2
  echo "       Check: tailscale status; ssh $MINI_SSH true; ~/.cstack/src/install.sh on the Mini." >&2
  echo "       Escape hatch (on purpose): --host local" >&2
  exit 3
}

# Streams the Mini worker log into the local replica live log and stdout.
# Appends replica registry rows on 📎 session_id= and at the end.
# One writer: this process is the only thing that touches the replica file.
mini_attach() {
  mkdir -p "$LIVE_DIR"
  : >"$LIVE_LOG"
  ln -sfn "$LIVE_LOG" "$LIVE_DIR/LATEST.log"
  echo "host: mini ($MINI_SSH)  job: $JOB" >&2
  echo "👁 live_log: $LIVE_LOG  (replica of the Mini; liveness = --status $JOB)" >&2
  echo "👁 watch:    tail -f $(printf %q "$LIVE_LOG")" >&2
  echo "👁 latest:   tail -f $(printf %q "$LIVE_DIR/LATEST.log")" >&2
  echo "👁 re-attach: sume-bg-launch --host mini --attach $JOB" >&2

  local session_id="" line rc=0 remote_pid="${REMOTE_PID:-}" remote_cwd="${REMOTE_CWD:-}"
  REMOTE_LIVE_LOG=""
  set +e
  mini_ssh attach --job "$JOB" | while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    printf '%s\n' "$line" >>"$LIVE_LOG"
    case "$line" in
      "sume-bg-remote: "*)
        # header from the Mini: job=… pid=… cwd=… host=…
        remote_pid=$(printf '%s' "$line" | sed -n 's/.* pid=\([0-9][0-9]*\).*/\1/p')
        remote_cwd=$(printf '%s' "$line" | sed -n 's/.* cwd=\(.*\)$/\1/p')
        ;;
      "live_log: "*|*"👁 live_log: "*)
        REMOTE_LIVE_LOG=${line#*live_log: }
        ;;
      *"📎 session_id="*)
        local sid
        sid=$(printf '%s' "$line" | sed -n 's/.*📎 session_id=\([^ ]*\).*/\1/p')
        if [[ -n "$sid" && "$sid" != "$session_id" ]]; then
          session_id=$sid
          replica_registry_append session "$sid" "$remote_pid" "$remote_cwd" ""
        fi
        ;;
    esac
  done
  rc=${PIPESTATUS[0]}
  set -e
  # The subshell loop cannot export; recover the session id from the replica.
  session_id=$(sed -n 's/.*📎 session_id=\([^ ]*\).*/\1/p' "$LIVE_LOG" | tail -n 1)
  REMOTE_LIVE_LOG=$(sed -n 's/^.*live_log: \(.*\)$/\1/p' "$LIVE_LOG" | head -n 1)
  if [[ "$rc" -eq 255 ]]; then
    echo "attach lost (ssh exit 255). The Mini job keeps running." >&2
    echo "  sume-bg-launch --host mini --status $JOB" >&2
    echo "  sume-bg-launch --host mini --attach $JOB" >&2
    replica_registry_append attach-lost "$session_id" "$remote_pid" "$remote_cwd" ""
    exit 255
  fi
  replica_registry_append end "$session_id" "$remote_pid" "$remote_cwd" "$rc"
  echo "host: mini job $JOB exited rc=$rc (replica: $LIVE_LOG)" >&2
  exit "$rc"
}

if [[ "$ACTION" != "launch" ]]; then
  if [[ "$HOST" != "mini" ]]; then
    echo "error: --$ACTION is a Mini control-plane action; add --host mini" >&2
    exit 2
  fi
  mini_require_config
  case "$ACTION" in
    jobs)
      mini_ssh jobs || mini_fail_closed
      ;;
    status|kill)
      mini_ssh "$ACTION" --job "$ACTION_JOB"
      ;;
    attach)
      JOB="$ACTION_JOB"
      LIVE_LOG="$LIVE_DIR/${JOB}.log"
      # Registry rows for this job carry backend/name; best effort.
      _row=$(python3 - "$REGISTRY" "$JOB" <<'PY' 2>/dev/null || true
import json, sys
path, job = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("job") == job:
                print("\t".join([str(rec.get("backend") or ""), str(rec.get("name") or ""),
                                 str(rec.get("cwd") or ""), str(rec.get("remote_pid") or "")]))
except OSError:
    pass
PY
)
      _row=$(printf '%s\n' "$_row" | tail -n 1)
      if [[ -n "$_row" ]]; then
        BACKEND=$(printf '%s' "$_row" | cut -f1)
        NAME=$(printf '%s' "$_row" | cut -f2)
        REMOTE_CWD=$(printf '%s' "$_row" | cut -f3)
        REMOTE_PID=$(printf '%s' "$_row" | cut -f4)
      fi
      BACKEND=${BACKEND:-grok}
      mini_attach
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Launch (shared validation)
# ---------------------------------------------------------------------------

case "$BACKEND" in
  grok|claude|codex|auto) ;;
  *)
    echo "error: --backend must be grok, claude, codex, or auto (got: $BACKEND)" >&2
    exit 2
    ;;
esac
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

# Fork is a wrapper operation even when supplied with backend flags.
_filtered=()
for _arg in "${EXTRA[@]+"${EXTRA[@]}"}"; do
  if [[ "$_arg" == "--fork-session" ]]; then
    FORK=1
  else
    _filtered+=("$_arg")
  fi
done
EXTRA=("${_filtered[@]+"${_filtered[@]}"}")

if [[ "$FORK" -eq 1 && -z "$RESUME" ]]; then
  echo "error: --fork-session requires --resume <uuid>" >&2
  exit 2
fi

# --resume is always same-host as the session (cstack#10).
ROUTE_HOST=""
ROUTE_JOB=""
ROUTE_CWD=""
if [[ -n "$RESUME" ]]; then
  _route=$(session_route "$RESUME")
  if [[ -n "$_route" ]]; then
    ROUTE_HOST=$(printf '%s' "$_route" | cut -f1)
    ROUTE_JOB=$(printf '%s' "$_route" | cut -f2)
    ROUTE_CWD=$(printf '%s' "$_route" | cut -f3)
    if [[ "$ROUTE_HOST" != "$HOST" ]]; then
      echo "error: session ${RESUME} lives on host ${ROUTE_HOST}${ROUTE_JOB:+ (job ${ROUTE_JOB})}; you asked --host ${HOST}." >&2
      echo "       --resume is same-host only. Re-run with --host ${ROUTE_HOST}." >&2
      exit 4
    fi
  fi
fi

if [[ -n "$CWD" && "$HOST" == "local" ]]; then
  cd "$CWD"
fi

# ---------------------------------------------------------------------------
# --host mini: scp prompt → detached start → attach (replica)
# ---------------------------------------------------------------------------

if [[ "$HOST" == "mini" ]]; then
  mini_require_config

  # Prompt files carry issue URLs and locks only — never credentials.
  if grep -Eq 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "$PROMPT_FILE"; then
    echo "error: --prompt-file looks like it contains a credential; Mini prompts carry issue URLs and locks only." >&2
    exit 2
  fi
  if grep -Eq 'SHOTS:|ego-browser|ego-lite|cua_repl|browser_' "$PROMPT_FILE"; then
    echo "note: Mini ego/dest shots are allowed (Chase 2026-09-13). Stay until dest /api/build SHA includes land, then verify (sumelabs, Auto)." >&2
    echo "      Post one Job issue comment with 2–4 shots + host/workspace/Auto/SHA/pass-fail/thread URL; final SHOTS: <comment URL>. No URL => no DEST: pass." >&2
    echo "      Do not exit while dest builds or because a background dest-watch exists. Prod requires Chase authorization." >&2
    echo "      Recipe: ~/.agents/skills/sume-main-agent-orchestration/references/dest-verify-issue-shots.md" >&2
  fi

  if [[ -z "$CWD" ]]; then
    if [[ -n "$RESUME" ]]; then
      if [[ -n "$ROUTE_CWD" ]]; then
        CWD="$ROUTE_CWD"
      else
        echo "error: --resume on the Mini needs the session's cwd; pass --cwd <remote dir> (not in the local replica registry)." >&2
        exit 4
      fi
    else
      CWD="${CSTACK_MINI_CWD:-}"
    fi
  fi

  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  LABEL=${NAME//[^a-zA-Z0-9._-]/_}
  if [[ -n "$RESUME" ]]; then
    if [[ "$FORK" -eq 1 ]]; then
      LABEL="${LABEL}-fork-${RESUME:0:8}"
    else
      LABEL="${LABEL}-resume-${RESUME:0:8}"
    fi
  fi
  JOB="${STAMP}-${LABEL}"
  LIVE_LOG="$LIVE_DIR/${JOB}.log"

  # 1) reachability + remote job dir (fail closed)
  _prep=$(mini_ssh prep --job "$JOB" 2>&1) || { printf '%s\n' "$_prep" >&2; mini_fail_closed; }
  case "$_prep" in
    *"ok job=$JOB"*) ;;
    *)
      printf '%s\n' "$_prep" >&2
      mini_fail_closed
      ;;
  esac
  REMOTE_JOB_DIR=$(printf '%s\n' "$_prep" | sed -n 's/.* dir=\(.*\)$/\1/p' | tail -n 1)
  if [[ -z "$REMOTE_JOB_DIR" ]]; then
    printf '%s\n' "$_prep" >&2
    mini_fail_closed
  fi

  # 2) prompt goes over scp (never ssh argv)
  if ! "$SCP_BIN" -q -o BatchMode=yes -o ConnectTimeout="$MINI_CONNECT_TIMEOUT" \
      "$PROMPT_FILE" "$MINI_SSH:$REMOTE_JOB_DIR/prompt.md"; then
    echo "error: scp of --prompt-file to $MINI_SSH failed" >&2
    mini_fail_closed
  fi

  # 3) detached start on the Mini (nohup + caffeinate -i; ssh returns at once)
  START_ARGS=(start --job "$JOB" --backend "$BACKEND" --name "$NAME")
  if [[ -n "$CWD" ]]; then
    START_ARGS+=(--cwd "$CWD")
  fi
  if [[ -n "$RESUME" ]]; then
    START_ARGS+=(--resume "$RESUME")
  fi
  if [[ "$FORK" -eq 1 ]]; then
    START_ARGS+=(--fork-session)
  fi
  if [[ ${#EXTRA[@]} -gt 0 ]]; then
    START_ARGS+=(-- "${EXTRA[@]}")
  fi
  _start=$(mini_ssh "${START_ARGS[@]}" 2>&1) || { printf '%s\n' "$_start" >&2; echo "error: remote start failed on $MINI_SSH" >&2; exit 3; }
  printf '%s\n' "$_start" >&2
  REMOTE_PID=$(printf '%s\n' "$_start" | sed -n 's/.* pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)
  REMOTE_CWD=$(printf '%s\n' "$_start" | sed -n 's/.* cwd=\(.*\)$/\1/p' | tail -n 1)
  if [[ -z "$REMOTE_PID" ]]; then
    echo "error: remote start did not report a pid" >&2
    exit 3
  fi
  REMOTE_LIVE_LOG=""
  replica_registry_append start "" "$REMOTE_PID" "$REMOTE_CWD" ""

  # 4) attach = replica writer. Ctrl-C / laptop sleep only ends the attach.
  mini_attach
fi

# ---------------------------------------------------------------------------
# --host local (unchanged behaviour)
# ---------------------------------------------------------------------------

# Steer: one live wrapper per session. Fork leaves the parent running.
if [[ -n "$RESUME" && "$FORK" -eq 0 ]]; then
  _self=$$
  while read -r _pid _rest; do
    [[ -z "${_pid:-}" ]] && continue
    [[ "$_pid" == "$_self" ]] && continue
    case "$_rest" in
      *gt\ merge*|*gt\ submit*) continue ;;
    esac
    echo "steer: stopping pid ${_pid} (same --resume ${RESUME})" >&2
    kill "$_pid" 2>/dev/null || true
  done < <(pgrep -af -- "$RESUME" | awk '/agent-human-stream|\/grok |grok -p|codex exec|claude -p/{print $1, $0}')
  sleep 0.2
fi

WRAPPER="${SUME_BG_LAUNCH_WRAPPER:-$(command -v agent-human-stream || true)}"
if [[ -z "$WRAPPER" && -x "$ROOT/agent-human-stream.sh" ]]; then
  WRAPPER="$ROOT/agent-human-stream.sh"
fi
if [[ -z "$WRAPPER" ]]; then
  echo "error: agent-human-stream not on PATH" >&2
  exit 127
fi

CMD=("$WRAPPER" --backend "$BACKEND" --name "$NAME" --prompt-file "$PROMPT_FILE")
if [[ -n "$RESUME" ]]; then
  CMD+=(--resume "$RESUME")
fi
if [[ "$FORK" -eq 1 ]]; then
  CMD+=(--fork-session)
fi
if [[ ${#EXTRA[@]} -gt 0 ]]; then
  CMD+=("${EXTRA[@]}")
fi

export AGENT_HUMAN_STREAM_HOST=local
echo "launch: ${CMD[*]}" >&2
exec "${CMD[@]}"
