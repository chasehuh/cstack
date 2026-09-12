#!/usr/bin/env bash
# Mac Mini side of `sume-bg-launch --host mini` (cstack#10).
# The laptop calls this over ssh as a CONTROL PLANE only:
#
#   sume-bg-remote prep   --job <id>                 # mkdir job dir, reachability probe
#   sume-bg-remote start  --job <id> --backend … --name … [--cwd …] \
#                         [--resume <uuid>] [--fork-session] [-- backend flags…]
#   sume-bg-remote attach --job <id>                 # stream worker.log until the job ends
#   sume-bg-remote status --job <id>                 # alive=yes|no (real pid, not a file)
#   sume-bg-remote kill   --job <id>                 # TERM then KILL the job's process group
#   sume-bg-remote jobs                              # one status line per job
#
# `start` returns immediately. The worker runs DETACHED: `nohup` in its own
# process group, wrapped in `caffeinate -i` so the Mini does not idle-sleep
# while a worker is alive. The ssh session (and the laptop) is never the
# process parent, so lid close / sleep / ssh drop do not kill it.
#
# Job dir: ~/.cstack/state/remote-jobs/<id>/{prompt.md,job.env,pid,pgid,worker.log,exit_code}
# The wrapper still writes ~/.cstack/state/opus-live + opus-sessions.jsonl
# here on the Mini; the laptop keeps a read-only replica via attach.
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
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)

usage() {
  sed -n '2,12p' "$SOURCE" | sed 's/^# \{0,1\}//'
}

die() {
  echo "sume-bg-remote: error: $*" >&2
  exit 2
}

job_dir() {
  local id="$1"
  case "$id" in
    ""|*/*|.*) die "bad job id: '$id'" ;;
  esac
  printf '%s/%s' "$JOBS_DIR" "$id"
}

job_alive() {
  # alive = no exit_code yet AND the run pid still exists.
  local dir="$1" pid
  [[ -f "$dir/exit_code" ]] && return 1
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

status_line() {
  local dir="$1" id pid rc alive
  id=$(basename "$dir")
  pid=$(cat "$dir/pid" 2>/dev/null || echo -)
  rc=$(cat "$dir/exit_code" 2>/dev/null || echo -)
  if job_alive "$dir"; then alive=yes; else alive=no; fi
  printf 'job=%s alive=%s pid=%s exit_code=%s host=%s\n' "$id" "$alive" "$pid" "$rc" "$HOSTNAME_SHORT"
}

# PATH as the Mini desk sees it (tokenmaxxing claude/codex first, gh/gt/grok
# from the login shell). ssh non-login shells do not source ~/.zshrc.
desk_path() {
  local login_path=""
  if [[ "${SUME_BG_REMOTE_LOGIN_PATH:-1}" == "1" && -n "${SHELL:-}" && -x "${SHELL:-}" ]]; then
    login_path=$("$SHELL" -lic 'printf "%s" "$PATH"' 2>/dev/null </dev/null || true)
  fi
  printf '%s' "$HOME/.config/tokenmaxxing/bin:$HOME/.local/bin:${login_path:-$PATH}"
}

launcher_bin() {
  if [[ -n "${SUME_BG_LAUNCH_BIN:-}" ]]; then
    printf '%s' "$SUME_BG_LAUNCH_BIN"
  elif [[ -x "$ROOT/sume-bg-launch.sh" ]]; then
    printf '%s' "$ROOT/sume-bg-launch.sh"
  elif [[ -x "$HOME/.local/bin/sume-bg-launch" ]]; then
    printf '%s' "$HOME/.local/bin/sume-bg-launch"
  else
    die "sume-bg-launch not installed on $HOSTNAME_SHORT (run ~/.cstack/src/install.sh)"
  fi
}

CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift

JOB=""
BACKEND="grok"
NAME=""
CWD=""
RESUME=""
FORK=0
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB=$2; shift 2 ;;
    --backend) BACKEND=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --fork-session) FORK=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

case "$CMD" in
  prep)
    [[ -n "$JOB" ]] || die "prep needs --job"
    DIR=$(job_dir "$JOB")
    mkdir -p "$DIR"
    launcher_bin >/dev/null
    printf 'ok job=%s host=%s dir=%s\n' "$JOB" "$HOSTNAME_SHORT" "$DIR"
    ;;

  start)
    [[ -n "$JOB" ]] || die "start needs --job"
    [[ -n "$NAME" ]] || die "start needs --name"
    DIR=$(job_dir "$JOB")
    [[ -s "$DIR/prompt.md" ]] || die "prompt not staged: $DIR/prompt.md (scp it first)"
    [[ ! -f "$DIR/pid" ]] || die "job $JOB already started (pid $(cat "$DIR/pid"))"
    CWD="${CWD:-$HOME}"
    [[ -d "$CWD" ]] || die "cwd not found on $HOSTNAME_SHORT: $CWD"
    launcher_bin >/dev/null
    {
      printf 'JOB=%q\nBACKEND=%q\nNAME=%q\nCWD=%q\nRESUME=%q\nFORK=%q\n' \
        "$JOB" "$BACKEND" "$NAME" "$CWD" "$RESUME" "$FORK"
      printf 'STARTED=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$DIR/job.env"
    RUN_ARGS=(run --job "$JOB" --backend "$BACKEND" --name "$NAME" --cwd "$CWD")
    if [[ -n "$RESUME" ]]; then RUN_ARGS+=(--resume "$RESUME"); fi
    if [[ "$FORK" -eq 1 ]]; then RUN_ARGS+=(--fork-session); fi
    if [[ ${#EXTRA[@]} -gt 0 ]]; then RUN_ARGS+=(-- "${EXTRA[@]}"); fi
    # Own process group (set -m) so ssh/sshd HUP never reaches it and
    # `kill` can take the whole tree down at once.
    set -m
    nohup "$SOURCE" "${RUN_ARGS[@]}" >"$DIR/worker.log" 2>&1 </dev/null &
    PID=$!
    set +m
    disown "$PID" 2>/dev/null || true
    echo "$PID" >"$DIR/pid"
    PGID=$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ' || true)
    echo "${PGID:-$PID}" >"$DIR/pgid"
    printf 'sume-bg-remote: started job=%s host=%s pid=%s cwd=%s\n' "$JOB" "$HOSTNAME_SHORT" "$PID" "$CWD"
    ;;

  run)
    # Internal: the detached process. stdout/stderr → worker.log (set by start).
    [[ -n "$JOB" ]] || die "run needs --job"
    DIR=$(job_dir "$JOB")
    CWD="${CWD:-$HOME}"
    cd "$CWD"
    PATH="$(desk_path)"
    export PATH
    export CSTACK_WORKER_HOST=local
    LAUNCH=$(launcher_bin)
    printf 'sume-bg-remote: job=%s host=%s pid=%s cwd=%s\n' "$JOB" "$HOSTNAME_SHORT" "$$" "$CWD"
    ARGS=(--host local --backend "$BACKEND" --name "$NAME" --prompt-file "$DIR/prompt.md")
    if [[ -n "$RESUME" ]]; then ARGS+=(--resume "$RESUME"); fi
    if [[ "$FORK" -eq 1 ]]; then ARGS+=(--fork-session); fi
    if [[ ${#EXTRA[@]} -gt 0 ]]; then ARGS+=(-- "${EXTRA[@]}"); fi
    set +e
    if command -v caffeinate >/dev/null 2>&1; then
      caffeinate -i "$LAUNCH" "${ARGS[@]}"
    else
      "$LAUNCH" "${ARGS[@]}"
    fi
    RC=$?
    set -e
    echo "$RC" >"$DIR/exit_code"
    printf 'sume-bg-remote: job=%s exited rc=%s\n' "$JOB" "$RC"
    exit "$RC"
    ;;

  attach)
    [[ -n "$JOB" ]] || die "attach needs --job"
    DIR=$(job_dir "$JOB")
    [[ -f "$DIR/worker.log" ]] || die "no worker.log for job $JOB (not started?)"
    if job_alive "$DIR"; then
      tail -n +1 -f "$DIR/worker.log" &
      TP=$!
      while job_alive "$DIR"; do sleep 2; done
      sleep 1
      kill "$TP" 2>/dev/null || true
      wait "$TP" 2>/dev/null || true
    else
      cat "$DIR/worker.log"
    fi
    RC=$(cat "$DIR/exit_code" 2>/dev/null || echo 1)
    exit "$RC"
    ;;

  status)
    [[ -n "$JOB" ]] || die "status needs --job"
    DIR=$(job_dir "$JOB")
    [[ -d "$DIR" ]] || die "unknown job $JOB"
    status_line "$DIR"
    ;;

  kill)
    [[ -n "$JOB" ]] || die "kill needs --job"
    DIR=$(job_dir "$JOB")
    [[ -d "$DIR" ]] || die "unknown job $JOB"
    if ! job_alive "$DIR"; then
      echo "job $JOB is not running"
      status_line "$DIR"
      exit 0
    fi
    PGID=$(cat "$DIR/pgid" 2>/dev/null || true)
    PID=$(cat "$DIR/pid")
    if [[ -n "$PGID" ]]; then kill -TERM -- "-$PGID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
    else kill -TERM "$PID" 2>/dev/null || true; fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      job_alive "$DIR" || break
      sleep 0.5
    done
    if job_alive "$DIR"; then
      if [[ -n "$PGID" ]]; then kill -KILL -- "-$PGID" 2>/dev/null || true; fi
      kill -KILL "$PID" 2>/dev/null || true
      sleep 0.5
    fi
    [[ -f "$DIR/exit_code" ]] || echo 143 >"$DIR/exit_code"
    echo "killed job $JOB"
    status_line "$DIR"
    ;;

  jobs)
    if [[ -d "$JOBS_DIR" ]]; then
      for d in "$JOBS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        status_line "${d%/}"
      done
    fi
    ;;

  *)
    die "unknown command $CMD"
    ;;
esac
