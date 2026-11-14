#!/usr/bin/env bash
# Mac Mini side of `sume-bg-launch --host mini` (cstack#10).
# The laptop calls this over ssh as a CONTROL PLANE only:
#
#   sume-bg-remote prep   --job <id>                 # mkdir job dir, reachability probe
#   sume-bg-remote start  --job <id> --backend … --name … [--cwd …] \
#                         [--resume <uuid>] [--fork-session] [--no-slack-report] [--same-thread] \
#                         [--priority P] [--now] [--fable-downgrade] [-- backend flags…]
#   sume-bg-remote attach --job <id>                 # stream worker.log until the job ends
#   sume-bg-remote status --job <id>                 # alive=yes|no state=… (pid + recorded start time)
#   sume-bg-remote kill   --job <id>                 # TERM then KILL the job's process group (exit 6 on a reused pid)
#   sume-bg-remote jobs                              # one status line per job
#   sume-bg-remote start-queued --job <id>           # governor: start a queued job now
#   sume-bg-remote quota [--json]                    # tokenmaxxing pool: Fable / weekly per account
#   sume-bg-remote overview [--json]                 # governor: load, running/paused/queued jobs, quota
#   sume-bg-remote governor <cmd> [args]             # pause|resume|start|pin|unpin <job>, mode observe|enforce|off, swap <email>
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
  sed -n '2,16p' "$SOURCE" | sed 's/^# \{0,1\}//'
}

PY=${SUME_BG_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}
GOVERNOR="$ROOT/sume-bg-governor.py"
QUOTA="$ROOT/cstack-quota.py"

governor_on() {
  [[ "${SUME_BG_GOVERNOR:-1}" != "0" && -f "$GOVERNOR" ]]
}

json_field() {
  "$PY" -c 'import json,sys
try:
    print(json.loads(sys.stdin.read() or "{}").get(sys.argv[1], ""))
except ValueError:
    print("")' "$1"
}

model_flag() {
  local want="$1" i=0 n=${#EXTRA[@]}
  while [[ $i -lt $n ]]; do
    case "${EXTRA[$i]}" in
      "$want") [[ $((i + 1)) -lt $n ]] && { printf '%s' "${EXTRA[$((i + 1))]}"; return 0; } ;;
      "$want"=*) printf '%s' "${EXTRA[$i]#*=}"; return 0 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

set_model_flags() {
  local model="$1" effort="$2" out=() i=0 n=${#EXTRA[@]}
  while [[ $i -lt $n ]]; do
    case "${EXTRA[$i]}" in
      --model|--effort) i=$((i + 2)); continue ;;
      --model=*|--effort=*) i=$((i + 1)); continue ;;
    esac
    out+=("${EXTRA[$i]}")
    i=$((i + 1))
  done
  out+=(--model "$model")
  [[ -n "$effort" ]] && out+=(--effort "$effort")
  EXTRA=("${out[@]}")
}

model_info() {
  "$PY" "$QUOTA" model-info --model "$(model_flag --model)" --effort "$(model_flag --effort)" 2>/dev/null || echo '{}'
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
  if [[ -z "$pid" && -f "$dir/queued" ]]; then echo queued; return; fi
  [[ -n "$pid" ]] || { echo lost; return; }
  kill -0 "$pid" 2>/dev/null || { echo lost; return; }
  want=$(cat "$dir/pid_start" 2>/dev/null || true)
  if [[ -n "$want" ]]; then
    now=$(proc_start "$pid")
    if [[ "$now" == "$want" ]]; then
      if [[ -f "$dir/governor-paused" ]]; then echo paused; else echo running; fi
      return
    fi
    echo pid-reused
    return
  fi
  case "$(proc_cmd "$pid")" in
    *"--job $id"*) echo running ;;
    *) echo pid-reused ;;
  esac
}

job_alive() {
  case "$(pid_state "$1")" in running|paused) return 0 ;; esac
  return 1
}

status_line() {
  local dir="$1" id pid rc alive state
  id=$(basename "$dir")
  pid=$(cat "$dir/pid" 2>/dev/null || echo -)
  rc=$(cat "$dir/exit_code" 2>/dev/null || echo -)
  state=$(pid_state "$dir")
  if [[ "$state" == "running" || "$state" == "paused" ]]; then alive=yes; else alive=no; fi
  printf 'job=%s alive=%s state=%s pid=%s exit_code=%s host=%s\n' "$id" "$alive" "$state" "$pid" "$rc" "$HOSTNAME_SHORT"
}

kill_job() {
  local dir="$1" id state pid pgid
  id=$(basename "$dir")
  state=$(pid_state "$dir")
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  case "$state" in
    running|paused) ;;
    queued)
      : >"$dir/stopped"
      rm -f "$dir/queued"
      echo 143 >"$dir/exit_code"
      echo "removed queued job $id"
      status_line "$dir"
      return 0
      ;;
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
  if [[ -f "$dir/governor-paused" ]]; then
    if [[ -n "$pgid" ]]; then kill -CONT -- "-$pgid" 2>/dev/null || true; fi
    kill -CONT "$pid" 2>/dev/null || true
    rm -f "$dir/governor-paused"
  fi
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
  if [[ "$rc" -ne 0 ]] && tail -n 40 "$DIR/worker.log" 2>/dev/null | LC_ALL=C grep -Eiq "reached your fable limit"; then
    printf 'usage limit: Fable (rc=%s)' "$rc"
    return 0
  fi
  if [[ "$rc" -ne 0 ]] && tail -n 40 "$DIR/worker.log" 2>/dev/null | LC_ALL=C grep -Eiq "(hit|reached) your [a-z0-9 -]*limit"; then
    printf 'usage limit (rc=%s)' "$rc"
    return 0
  fi
  return 1
}

fable_resume_plan() {
  local plan action target
  plan=$("$PY" "$QUOTA" fable-plan 2>/dev/null || echo '{}')
  action=$(printf '%s' "$plan" | json_field action)
  if [[ "$action" == "swap" ]]; then
    target=$(printf '%s' "$plan" | json_field target)
    if command -v "${SUME_BG_TOKENMAXXING_BIN:-tokenmaxxing}" >/dev/null 2>&1; then
      run_with_timeout 90 "${SUME_BG_TOKENMAXXING_BIN:-tokenmaxxing}" switch "$target" >>"$DIR/auto-resume.log" 2>&1 || true
    fi
    plan=$("$PY" "$QUOTA" fable-plan 2>/dev/null || echo '{}')
    action=$(printf '%s' "$plan" | json_field action)
    if [[ "$action" == "swap" ]] && governor_on; then
      "$PY" "$GOVERNOR" swap "$target" --wait "${SUME_BG_SWAP_WAIT_S:-90}" >>"$DIR/auto-resume.log" 2>&1 || true
      plan=$("$PY" "$QUOTA" fable-plan 2>/dev/null || echo '{}')
      action=$(printf '%s' "$plan" | json_field action)
    fi
    if [[ "$action" == "swap" ]]; then
      plan=$(printf '%s' "$plan" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); d["action"]="opus"; d["reason"]="the swap to "+d.get("target","")+" did not take; "+d.get("reason",""); print(json.dumps(d))')
    elif [[ "$action" == "fable" ]]; then
      plan=$(printf '%s' "$plan" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); d["action"]="swapped"; print(json.dumps(d))')
    fi
  fi
  printf '%s' "$plan"
}

run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $waited -ge $secs ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null; return 124; fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

auto_resume() {
  local reason="$1" sid="$2" depth max delay new ndir args info fable effort plan action fallback="" note=""
  depth=$(sed -n 's/^AUTO_RESUME_DEPTH=//p' "$DIR/job.env" 2>/dev/null | tail -n 1)
  depth=${depth:-0}
  case "$reason" in
    usage*) max=3; delay=${SUME_BG_LIMIT_RESUME_DELAY:-120} ;;
    *) max=2; delay=${SUME_BG_KILL_RESUME_DELAY:-5} ;;
  esac
  [[ -n "$sid" && "$depth" -lt "$max" ]] || return 1
  sleep "$delay"
  [[ -z "$(session_holders "$sid" "$JOB")" ]] || return 1
  rm -f "$DIR/auto-resume.note"
  if [[ "$reason" == usage* ]]; then
    info=$(model_info)
    fable=$(printf '%s' "$info" | json_field fable)
    effort=$(printf '%s' "$info" | json_field effort)
    if [[ "$fable" == "True" ]]; then
      plan=$(fable_resume_plan)
      action=$(printf '%s' "$plan" | json_field action)
      case "$action" in
        opus)
          set_model_flags "${SUME_BG_FABLE_FALLBACK_MODEL:-claude-opus-5-5}" "${effort:-high}"
          fallback="Fable -> ${SUME_BG_FABLE_FALLBACK_MODEL:-claude-opus-5-5} (effort ${effort:-high}): $(printf '%s' "$plan" | json_field reason)"
          note="Fable 소진 → Opus 5.5 ${effort:-high}로 재개"
          ;;
        wait)
          printf '%s' "every account is out of weekly quota" >"$DIR/auto-resume.note"
          return 1
          ;;
        swapped)
          note="Fable 계정 전환 후 재개"
          ;;
      esac
    fi
  fi
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
    printf 'Background commands and watchers from before are gone; restart only the ones you still need.'
    if [[ -n "$fallback" ]]; then
      printf ' MODEL FALLBACK: no tokenmaxxing account has Fable quota left, so this run continues on %s at the same effort (%s). Keep the same task, standards and done criteria; do not switch back mid-task.' \
        "${SUME_BG_FABLE_FALLBACK_MODEL:-claude-opus-5-5}" "${effort:-high}"
    fi
    printf '\n'
  } >"$ndir/prompt.md"
  args=(start --job "$new" --backend "$BACKEND" --name "$NAME" --cwd "$CWD" --resume "$sid" --now)
  if [[ -n "$PRIORITY" ]]; then args+=(--priority "$PRIORITY"); fi
  if [[ "$SLACK_REPORT" == "0" ]]; then args+=(--no-slack-report); fi
  if [[ "$SAME_THREAD" == "1" ]]; then args+=(--same-thread); fi
  if [[ ${#EXTRA[@]} -gt 0 ]]; then args+=(-- "${EXTRA[@]}"); fi
  env -u SUME_BG_REMOTE_JOB -u SUME_WORKER_SESSION -u AGENT_HUMAN_STREAM_PID -u AGENT_HUMAN_STREAM_NAME \
    -u AGENT_HUMAN_STREAM_LIVE_LOG SUME_BG_AUTO_RESUME_OF="$JOB" SUME_BG_AUTO_RESUME_DEPTH=$((depth + 1)) \
    SUME_BG_MODEL_FALLBACK="$fallback" \
    "$SOURCE" "${args[@]}" >/dev/null 2>&1 || return 1
  [[ -n "$note" ]] && printf '%s' "$note" >"$DIR/auto-resume.note"
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
    if [[ -s "$DIR/auto-resume.note" ]]; then line+=" ($(cat "$DIR/auto-resume.note"))"; fi
  elif [[ -n "$sid" && -s "$DIR/auto-resume.note" ]]; then
    line="• \`${NAME}\` ${reason} → 모든 계정 주간 한도 소진, 재개 안 함: \`--resume ${sid}\`"
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
PRIORITY=""
NOW=0
FABLE_DOWNGRADE=${SUME_BG_FABLE_DOWNGRADE:-0}
JSON=0
EXTRA=()
if [[ "$CMD" == "governor" ]]; then
  exec "$PY" "$GOVERNOR" "$@"
fi
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
    --priority) PRIORITY=$2; shift 2 ;;
    --now) NOW=1; shift ;;
    --fable-downgrade) FABLE_DOWNGRADE=1; shift ;;
    --json) JSON=1; shift ;;
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

  start-queued)
    [[ -n "$JOB" ]] || die "start-queued needs --job"
    DIR=$(job_dir "$JOB")
    [[ -f "$DIR/queued" && ! -f "$DIR/pid" ]] || die "job $JOB is not queued"
    QARGS=(start --job "$JOB" --now)
    for k in BACKEND NAME CWD RESUME PRIORITY; do
      v=$(sed -n "s/^${k}=//p" "$DIR/job.env" | tail -n 1)
      v=$(eval "printf '%s' $v" 2>/dev/null || printf '%s' "$v")
      [[ -n "$v" ]] || continue
      case "$k" in
        BACKEND) QARGS+=(--backend "$v") ;; NAME) QARGS+=(--name "$v") ;; CWD) QARGS+=(--cwd "$v") ;;
        RESUME) QARGS+=(--resume "$v") ;; PRIORITY) QARGS+=(--priority "$v") ;;
      esac
    done
    [[ "$(sed -n 's/^FORK=//p' "$DIR/job.env" | tail -n 1)" == "1" ]] && QARGS+=(--fork-session)
    [[ "$(sed -n 's/^SLACK_REPORT=//p' "$DIR/job.env" | tail -n 1)" == "0" ]] && QARGS+=(--no-slack-report)
    [[ "$(sed -n 's/^SAME_THREAD=//p' "$DIR/job.env" | tail -n 1)" == "1" ]] && QARGS+=(--same-thread)
    QEXTRA=()
    if [[ -f "$DIR/extra.args" ]]; then
      while IFS= read -r a || [[ -n "$a" ]]; do QEXTRA+=("$a"); done <"$DIR/extra.args"
    fi
    QUEUED_AT=$(sed -n 's/^QUEUED_AT=//p' "$DIR/job.env" | tail -n 1)
    rm -f "$DIR/queued"
    if [[ ${#QEXTRA[@]} -gt 0 ]]; then QARGS+=(-- "${QEXTRA[@]}"); fi
    SUME_BG_QUEUED_AT="$QUEUED_AT" exec "$SOURCE" "${QARGS[@]}"
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
    INFO=$(model_info)
    MODEL=$(model_flag --model)
    EFFORT=$(printf '%s' "$INFO" | json_field effort)
    DOWNGRADED=""
    if [[ "$(printf '%s' "$INFO" | json_field fable)" == "True" && "${SUME_BG_QUOTA_CHECK:-1}" != "0" ]]; then
      RUNNING_FABLE=0
      if governor_on; then
        RUNNING_FABLE=$("$PY" "$GOVERNOR" status --json 2>/dev/null | "$PY" -c 'import json,sys
try:
    d=json.load(sys.stdin); print(sum(1 for j in d.get("jobs",[]) if j.get("state") in ("running","paused") and "fable" in (j.get("model") or "").lower()))
except ValueError:
    print(0)' 2>/dev/null || echo 0)
      fi
      set +e
      QMSG=$("$PY" "$QUOTA" launch-check --model "$MODEL" --effort "$EFFORT" --running-fable "${RUNNING_FABLE:-0}" 2>/dev/null)
      QRC=$?
      set -e
      if [[ $QRC -eq 10 ]]; then
        printf 'sume-bg-remote: %s\n' "$QMSG"
        if [[ "$FABLE_DOWNGRADE" == "1" ]]; then
          set_model_flags "${SUME_BG_FABLE_FALLBACK_MODEL:-claude-opus-5-5}" "${EFFORT:-high}"
          DOWNGRADED="$MODEL -> ${SUME_BG_FABLE_FALLBACK_MODEL:-claude-opus-5-5} (effort ${EFFORT:-high}): $QMSG"
          printf 'sume-bg-remote: model downgraded for this launch: %s\n' "$DOWNGRADED"
          MODEL="${SUME_BG_FABLE_FALLBACK_MODEL:-claude-opus-5-5}"
          governor_on && "$PY" "$GOVERNOR" notify "⬇️ \`${NAME}\` Fable 한도 부족 → Opus 5.5 ${EFFORT:-high}로 시작" >/dev/null 2>&1 || true
        else
          printf 'sume-bg-remote: launching on Fable anyway; pass --fable-downgrade (or SUME_BG_FABLE_DOWNGRADE=1) to start on Opus 5.5 at the same effort\n'
        fi
      fi
    fi
    DECISION=start
    QREASON=""
    if governor_on; then
      ADMIT=(admit --name "$NAME" --model "$MODEL" --effort "$EFFORT")
      [[ -n "$PRIORITY" ]] && ADMIT+=(--priority "$PRIORITY")
      [[ -n "$RESUME" ]] && ADMIT+=(--resume "$RESUME")
      [[ "$FORK" -eq 1 ]] && ADMIT+=(--fork)
      [[ "$NOW" -eq 1 ]] && ADMIT+=(--now)
      AOUT=$("$PY" "$GOVERNOR" "${ADMIT[@]}" 2>/dev/null || echo '{}')
      DECISION=$(printf '%s' "$AOUT" | json_field decision)
      QREASON=$(printf '%s' "$AOUT" | json_field reason)
      [[ -n "$PRIORITY" ]] || PRIORITY=$(printf '%s' "$AOUT" | json_field priority)
      DECISION=${DECISION:-start}
    fi
    if [[ "$DECISION" != "queue" && -n "$RESUME" && "$FORK" -eq 0 ]]; then
      stop_session_holders "$RESUME" "$JOB"
    fi
    {
      printf 'JOB=%q\nBACKEND=%q\nNAME=%q\nCWD=%q\nRESUME=%q\nFORK=%q\nSLACK_REPORT=%q\nSAME_THREAD=%q\n' \
        "$JOB" "$BACKEND" "$NAME" "$CWD" "$RESUME" "$FORK" "$SLACK_REPORT" "$SAME_THREAD"
      printf 'STARTED=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'PRIORITY=%q\nMODEL=%q\nEFFORT=%q\n' "$PRIORITY" "$MODEL" "$EFFORT"
      if [[ -n "$DOWNGRADED" ]]; then printf 'MODEL_DOWNGRADE=%q\n' "$DOWNGRADED"; fi
      if [[ -n "${SUME_BG_MODEL_FALLBACK:-}" ]]; then printf 'MODEL_FALLBACK=%q\n' "$SUME_BG_MODEL_FALLBACK"; fi
      if [[ -n "${SUME_BG_GOVERNOR_RESUME_OF:-}" ]]; then printf 'GOVERNOR_RESUME_OF=%q\n' "$SUME_BG_GOVERNOR_RESUME_OF"; fi
      if [[ -n "${SUME_BG_QUEUED_AT:-}" ]]; then printf 'QUEUED_AT=%s\n' "$SUME_BG_QUEUED_AT"; fi
      if [[ "$DECISION" == "queue" ]]; then printf 'QUEUED_AT=%q\nQUEUE_REASON=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$QREASON"; fi
      if [[ -n "${SUME_BG_AUTO_RESUME_OF:-}" ]]; then
        printf 'AUTO_RESUME_OF=%q\nAUTO_RESUME_DEPTH=%q\n' "$SUME_BG_AUTO_RESUME_OF" "${SUME_BG_AUTO_RESUME_DEPTH:-1}"
      fi
    } >"$DIR/job.env"
    : >"$DIR/extra.args"
    for a in "${EXTRA[@]+"${EXTRA[@]}"}"; do printf '%s\n' "$a" >>"$DIR/extra.args"; done
    if [[ "$DECISION" == "queue" ]]; then
      : >"$DIR/queued"
      printf 'sume-bg-remote: queued job=%s host=%s priority=%s reason=%s\n' "$JOB" "$HOSTNAME_SHORT" "$PRIORITY" "$QREASON"
      printf 'sume-bg-remote: the governor starts it when the Mini has capacity (sume-bg-launch --host mini --status); start it now: sume-bg-launch --host mini --governor start %s\n' "$JOB"
      exit 0
    fi
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
    if [[ -f "$DIR/queued" ]]; then
      echo "sume-bg-remote: job $JOB is queued; waiting for the governor to start it"
      while [[ -f "$DIR/queued" && ! -f "$DIR/exit_code" ]]; do sleep 10; done
      for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$DIR/worker.log" || -f "$DIR/exit_code" ]] && break; sleep 1; done
    fi
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

  quota)
    QARGS=(status)
    [[ "$JSON" -eq 1 ]] && QARGS+=(--json)
    exec "$PY" "$QUOTA" "${QARGS[@]}"
    ;;

  overview)
    governor_on || die "governor not installed next to $SOURCE"
    OARGS=(status)
    [[ "$JSON" -eq 1 ]] && OARGS+=(--json)
    exec "$PY" "$GOVERNOR" "${OARGS[@]}"
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
