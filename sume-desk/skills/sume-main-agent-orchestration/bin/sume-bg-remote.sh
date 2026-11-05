#!/usr/bin/env bash
# Mac Mini side of `sume-bg-launch --host mini` (cstack#10).
# The laptop calls this over ssh as a CONTROL PLANE only:
#
#   sume-bg-remote prep   --job <id>                 # mkdir job dir, reachability probe
#   sume-bg-remote start  --job <id> --backend … --name … [--cwd …] \
#                         [--resume <uuid>] [--fork-session] [--no-slack-report] [--same-thread] \
#                         [-- backend flags…]
#   sume-bg-remote attach --job <id>                 # stream worker.log until the job ends
#   sume-bg-remote status --job <id>                 # alive=yes|no state=… (pid + recorded start time)
#   sume-bg-remote kill   --job <id>                 # TERM then KILL the job's process group (exit 6 on a reused pid)
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

proc_start() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

proc_cmd() {
  ps -o command= -p "$1" 2>/dev/null || true
}

pid_state() {
  local dir="$1" id pid want now
  id=$(basename "$dir")
  [[ -f "$dir/exit_code" ]] && { echo exited; return; }
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  [[ -n "$pid" ]] || { echo lost; return; }
  kill -0 "$pid" 2>/dev/null || { echo lost; return; }
  want=$(cat "$dir/pid_start" 2>/dev/null || true)
  if [[ -n "$want" ]]; then
    now=$(proc_start "$pid")
    [[ "$now" == "$want" ]] && { echo running; return; }
    echo pid-reused
    return
  fi
  case "$(proc_cmd "$pid")" in
    *"--job $id"*) echo running ;;
    *) echo pid-reused ;;
  esac
}

job_alive() {
  [[ "$(pid_state "$1")" == "running" ]]
}

status_line() {
  local dir="$1" id pid rc alive state
  id=$(basename "$dir")
  pid=$(cat "$dir/pid" 2>/dev/null || echo -)
  rc=$(cat "$dir/exit_code" 2>/dev/null || echo -)
  state=$(pid_state "$dir")
  if [[ "$state" == "running" ]]; then alive=yes; else alive=no; fi
  printf 'job=%s alive=%s state=%s pid=%s exit_code=%s host=%s\n' "$id" "$alive" "$state" "$pid" "$rc" "$HOSTNAME_SHORT"
}

kill_job() {
  local dir="$1" id state pid pgid
  id=$(basename "$dir")
  state=$(pid_state "$dir")
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  case "$state" in
    running) ;;
    pid-reused)
      echo "sume-bg-remote: refusing to kill job $id: pid $pid now belongs to another process: $(proc_cmd "$pid" | cut -c1-160)" >&2
      status_line "$dir"
      return 6
      ;;
    *)
      echo "job $id is not running"
      status_line "$dir"
      return 0
      ;;
  esac
  pgid=$(cat "$dir/pgid" 2>/dev/null || true)
  : >"$dir/stopped"
  if [[ -n "$pgid" ]]; then kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  else kill -TERM "$pid" 2>/dev/null || true; fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    job_alive "$dir" || break
    sleep 0.5
  done
  if job_alive "$dir"; then
    if [[ -n "$pgid" ]]; then kill -KILL -- "-$pgid" 2>/dev/null || true; fi
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  [[ -f "$dir/exit_code" ]] || echo 143 >"$dir/exit_code"
  echo "killed job $id"
  status_line "$dir"
}

session_holders() {
  local uuid="$1" self="$2" d id resumed forked
  [[ -d "$JOBS_DIR" ]] || return 0
  for d in "$JOBS_DIR"/*/; do
    d=${d%/}
    id=$(basename "$d")
    [[ "$id" == "$self" ]] && continue
    job_alive "$d" || continue
    resumed=$(sed -n 's/^RESUME=//p' "$d/job.env" 2>/dev/null | tail -n 1)
    forked=$(sed -n 's/^FORK=//p' "$d/job.env" 2>/dev/null | tail -n 1)
    if { [[ "$resumed" == "$uuid" && "$forked" != "1" ]]; } \
      || grep -Eq "^📎 session_id=${uuid}( |\$)" "$d/worker.log" 2>/dev/null; then
      printf '%s\n' "$d"
    fi
  done
}

stop_session_holders() {
  local uuid="$1" self="$2" d
  while read -r d; do
    [[ -n "$d" ]] || continue
    echo "steer: stopping older job $(basename "$d") (same session $uuid)"
    kill_job "$d" >/dev/null || true
  done < <(session_holders "$uuid" "$self")
}

death_reason() {
  local rc="$1" sig
  [[ -f "$DIR/stopped" ]] && return 1
  if [[ "$rc" -gt 128 && "$rc" -lt 160 ]]; then
    sig=$(kill -l $((rc - 128)) 2>/dev/null || echo $((rc - 128)))
    printf 'SIG%s (rc=%s)' "${sig#SIG}" "$rc"
    return 0
  fi
  if [[ "$rc" -ne 0 ]] && tail -n 40 "$DIR/worker.log" 2>/dev/null | grep -Eiq "hit your [a-z0-9 -]*limit"; then
    printf 'usage limit (rc=%s)' "$rc"
    return 0
  fi
  return 1
}

auto_resume() {
  local reason="$1" sid="$2" depth max delay new ndir args
  depth=$(sed -n 's/^AUTO_RESUME_DEPTH=//p' "$DIR/job.env" 2>/dev/null | tail -n 1)
  depth=${depth:-0}
  case "$reason" in
    usage*) max=3; delay=${SUME_BG_LIMIT_RESUME_DELAY:-120} ;;
    *) max=2; delay=${SUME_BG_KILL_RESUME_DELAY:-5} ;;
  esac
  [[ -n "$sid" && "$depth" -lt "$max" ]] || return 1
  sleep "$delay"
  [[ -z "$(session_holders "$sid" "$JOB")" ]] || return 1
  while :; do
    new="$(date -u +%Y%m%dT%H%M%SZ)-${NAME}-resume-${sid:0:8}"
    ndir=$(job_dir "$new")
    mkdir "$ndir" 2>/dev/null && break
    sleep 1
  done
  {
    printf 'AUTO-RESUME: your previous run of this job (Mini job %s) ended on its own at %s: %s. ' "$JOB" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason"
    printf 'Neither Chase nor the main agent stopped it. Continue the same task from where you left off. '
    printf 'First check what already happened (git branch, PRs, merge queue, Slack posts) so nothing runs twice. '
    printf 'Background commands and watchers from before are gone; restart only the ones you still need.\n'
  } >"$ndir/prompt.md"
  args=(start --job "$new" --backend "$BACKEND" --name "$NAME" --cwd "$CWD" --resume "$sid")
  if [[ "$SLACK_REPORT" == "0" ]]; then args+=(--no-slack-report); fi
  if [[ "$SAME_THREAD" == "1" ]]; then args+=(--same-thread); fi
  if [[ ${#EXTRA[@]} -gt 0 ]]; then args+=(-- "${EXTRA[@]}"); fi
  env -u SUME_BG_REMOTE_JOB -u SUME_WORKER_SESSION -u AGENT_HUMAN_STREAM_PID -u AGENT_HUMAN_STREAM_NAME \
    -u AGENT_HUMAN_STREAM_LIVE_LOG SUME_BG_AUTO_RESUME_OF="$JOB" SUME_BG_AUTO_RESUME_DEPTH=$((depth + 1)) \
    "$SOURCE" "${args[@]}" >/dev/null 2>&1 || return 1
  printf '%s' "$new"
}

alert_deaths() {
  local spool="$CSTACK_STATE/job-alerts" files f n text title post
  mkdir -p "$spool"
  if ! mkdir "$spool/.lock" 2>/dev/null; then
    [[ -n "$(find "$spool/.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]] || return 0
    rm -rf "$spool/.lock"
    mkdir "$spool/.lock" 2>/dev/null || return 0
  fi
  sleep "${SUME_BG_ALERT_BATCH_S:-20}"
  post=${SUME_BG_SLACK_POST_BIN:-$ROOT/cstack-slack-post.sh}
  while :; do
    files=()
    for f in "$spool"/*.line; do [[ -e "$f" ]] && files+=("$f"); done
    [[ ${#files[@]} -gt 0 ]] || break
    n=${#files[@]}
    title="Mini 워커 비정상 종료 ${n}건"
    text="*${title}* ($(TZ=Asia/Seoul date '+%m/%d %H:%M KST'))"
    for f in "${files[@]}"; do
      cat "$f" >>"$spool/log"
      if [[ $(( ${#text} + $(wc -m <"$f") )) -lt 540 ]]; then
        text+=$'\n'"$(cat "$f")"
      else
        text+=$'\n'"…전체 목록: ~/.cstack/state/job-alerts/log"
        break
      fi
    done
    rm -f "${files[@]}"
    printf '%s\n' "$text" >"$spool/.lock/text.md"
    "$post" --job launcher-watch --title "$title" --text-file "$spool/.lock/text.md" >>"$spool/post.log" 2>&1 || true
  done
  rm -rf "$spool/.lock"
}

after_exit() {
  local rc="$1" reason sid new line
  reason=$(death_reason "$rc") || return 0
  sid=$(sed -n 's/^📎 session_id=\([0-9a-fA-F-]\{36\}\).*/\1/p' "$DIR/worker.log" 2>/dev/null | tail -n 1)
  [[ -n "$sid" && -n "$(session_holders "$sid" "$JOB")" ]] && return 0
  printf 'sume-bg-remote: job=%s ended unexpectedly: %s\n' "$JOB" "$reason"
  if new=$(auto_resume "$reason" "$sid"); then
    printf 'sume-bg-remote: auto-resumed as job=%s\n' "$new"
    line="• \`${NAME}\` ${reason} → 자동 재개 \`${new}\`"
  elif [[ -n "$sid" ]]; then
    line="• \`${NAME}\` ${reason} → 재개 필요: \`--resume ${sid}\`"
  else
    line="• \`${NAME}\` ${reason} → 세션 id 없음, 재시작 필요 (\`${JOB}\`)"
  fi
  mkdir -p "$CSTACK_STATE/job-alerts"
  printf '%s\n' "$line" >"$CSTACK_STATE/job-alerts/$JOB.line"
  alert_deaths
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
BACKEND="claude"
NAME=""
CWD=""
RESUME=""
FORK=0
SLACK_REPORT=1
SAME_THREAD=0
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB=$2; shift 2 ;;
    --backend) BACKEND=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --fork-session) FORK=1; shift ;;
    --no-slack-report) SLACK_REPORT=0; shift ;;
    --same-thread) SAME_THREAD=1; shift ;;
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
    if [[ -n "$RESUME" && "$FORK" -eq 0 ]]; then
      stop_session_holders "$RESUME" "$JOB"
    fi
    {
      printf 'JOB=%q\nBACKEND=%q\nNAME=%q\nCWD=%q\nRESUME=%q\nFORK=%q\nSLACK_REPORT=%q\nSAME_THREAD=%q\n' \
        "$JOB" "$BACKEND" "$NAME" "$CWD" "$RESUME" "$FORK" "$SLACK_REPORT" "$SAME_THREAD"
      printf 'STARTED=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [[ -n "${SUME_BG_AUTO_RESUME_OF:-}" ]]; then
        printf 'AUTO_RESUME_OF=%q\nAUTO_RESUME_DEPTH=%q\n' "$SUME_BG_AUTO_RESUME_OF" "${SUME_BG_AUTO_RESUME_DEPTH:-1}"
      fi
    } >"$DIR/job.env"
    RUN_ARGS=(run --job "$JOB" --backend "$BACKEND" --name "$NAME" --cwd "$CWD")
    if [[ -n "$RESUME" ]]; then RUN_ARGS+=(--resume "$RESUME"); fi
    if [[ "$FORK" -eq 1 ]]; then RUN_ARGS+=(--fork-session); fi
    if [[ "$SLACK_REPORT" == "0" ]]; then RUN_ARGS+=(--no-slack-report); fi
    if [[ "$SAME_THREAD" == "1" ]]; then RUN_ARGS+=(--same-thread); fi
    if [[ ${#EXTRA[@]} -gt 0 ]]; then RUN_ARGS+=(-- "${EXTRA[@]}"); fi
    # Own process group (set -m) so ssh/sshd HUP never reaches it and
    # `kill` can take the whole tree down at once.
    set -m
    nohup "$SOURCE" "${RUN_ARGS[@]}" >"$DIR/worker.log" 2>&1 </dev/null &
    PID=$!
    set +m
    disown "$PID" 2>/dev/null || true
    echo "$PID" >"$DIR/pid"
    proc_start "$PID" >"$DIR/pid_start"
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
    # Mini: Claude Code keychain is locked over ssh (exit 36). File store.
    export CLAUDE_SECURESTORAGE_CONFIG_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-$HOME/.claude}"
    # Job marker for the worker's tool shells: the launcher/wrapper refuse a
    # nested launch inside this job and name it in the error (sume#7839).
    export SUME_BG_REMOTE_JOB="$JOB"
    LAUNCH=$(launcher_bin)
    printf 'sume-bg-remote: job=%s host=%s pid=%s cwd=%s\n' "$JOB" "$HOSTNAME_SHORT" "$$" "$CWD"
    ARGS=(--host local --backend "$BACKEND" --name "$NAME" --prompt-file "$DIR/prompt.md")
    if [[ -n "$RESUME" ]]; then ARGS+=(--resume "$RESUME"); fi
    if [[ "$FORK" -eq 1 ]]; then ARGS+=(--fork-session); fi
    if [[ "$SLACK_REPORT" == "0" ]]; then ARGS+=(--no-slack-report); fi
    if [[ "$SAME_THREAD" == "1" ]]; then ARGS+=(--same-thread); fi
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
    # Close the ego task spaces this job left open (success or failure), and
    # sweep agent spaces of dead jobs older than 1 h (sume#12962). Best
    # effort: it never changes RC. CSTACK_EGO_REAP=0 turns it off.
    if [[ "${CSTACK_EGO_REAP:-1}" != "0" ]] && command -v node >/dev/null 2>&1; then
      node "$ROOT/cstack-ego-reap.mjs" --job-dir "$DIR" --sweep --apply >>"$DIR/ego-reap.log" 2>&1 || true
    fi
    after_exit "$RC" || true
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
    kill_job "$DIR"
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
