#!/usr/bin/env bash
set -uo pipefail

MODE=$(basename "$0")
JOBS_DIR="${SUME_BG_REMOTE_JOBS_DIR:-${CSTACK_STATE:-$HOME/.cstack/state}/remote-jobs}"
REAL_PGREP=${CSTACK_KILL_GUARD_PGREP:-/usr/bin/pgrep}
REAL_KILLALL=${CSTACK_KILL_GUARD_KILLALL:-/usr/bin/killall}

PROTECTED=()
protected_groups() {
  local d id pid pgid want now
  [[ -d "$JOBS_DIR" ]] || return 0
  for d in "$JOBS_DIR"/*/; do
    d=${d%/}
    id=$(basename "$d")
    [[ "$id" == "${SUME_BG_REMOTE_JOB:-}" ]] && continue
    [[ -f "$d/exit_code" ]] && continue
    pid=$(cat "$d/pid" 2>/dev/null) || continue
    pgid=$(cat "$d/pgid" 2>/dev/null) || continue
    [[ -n "$pid" && -n "$pgid" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    want=$(cat "$d/pid_start" 2>/dev/null || true)
    now=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//;s/ *$//')
    [[ -n "$want" && "$now" == "$want" ]] || continue
    PROTECTED+=("$pgid:$id")
  done
}

job_of_pid() {
  local pid="$1" pg entry
  pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$pg" ]] || return 1
  for entry in "${PROTECTED[@]+"${PROTECTED[@]}"}"; do
    if [[ "${entry%%:*}" == "$pg" ]]; then
      printf '%s' "${entry#*:}"
      return 0
    fi
  done
  return 1
}

is_signal() {
  [[ "$1" =~ ^-[0-9]+$ || "$1" =~ ^-(SIG)?[A-Z][A-Z0-9]+$ ]]
}

signal_and_report() {
  local sig="$1" dry="$2"; shift 2
  local pid job targets=() refused=() line
  protected_groups
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    if job=$(job_of_pid "$pid"); then
      refused+=("$pid($job)")
    else
      targets+=("$pid")
    fi
  done
  if [[ ${#refused[@]} -gt 0 ]]; then
    line="${refused[*]}"
    echo "$MODE: left ${#refused[@]} process(es) of other live cstack jobs alone: ${line}. Stop only what you started: kill <pid>, or a pattern unique to your job (its /tmp path). Stop a job: sume-bg-remote kill --job <id>." >&2
  fi
  [[ ${#targets[@]} -gt 0 ]] || return 1
  if [[ "$dry" == "1" ]]; then
    printf 'kill -%s %s\n' "$sig" "${targets[*]}"
    return 0
  fi
  /bin/kill -"$sig" "${targets[@]}" 2>/dev/null
  return 0
}

run_pkill() {
  local sig=TERM args=() a out rc pids=()
  if [[ $# -gt 0 ]] && is_signal "$1"; then
    sig=${1#-}
    sig=${sig#SIG}
    shift
  fi
  for a in "$@"; do
    [[ "$a" == "-I" ]] && continue
    args+=("$a")
  done
  out=$("$REAL_PGREP" "${args[@]+"${args[@]}"}")
  rc=$?
  [[ $rc -le 1 ]] || return "$rc"
  [[ $rc -eq 0 ]] || return 1
  while read -r a _; do
    [[ "$a" =~ ^[0-9]+$ ]] && [[ "$a" != "$$" ]] && pids+=("$a")
  done <<<"$out"
  signal_and_report "$sig" 0 "${pids[@]+"${pids[@]}"}"
}

run_killall() {
  local sig=TERM dry=0 quiet=0 regex=0 user="" names=() a out pids=() pg_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l) exec "$REAL_KILLALL" -l ;;
      -s) dry=1; shift ;;
      -q) quiet=1; shift ;;
      -v|-z) shift ;;
      -m) regex=1; shift ;;
      -u) user=${2:-}; shift 2 ;;
      -c) names+=("${2:-}"); shift 2 ;;
      --) shift; names+=("$@"); break ;;
      -*)
        if is_signal "$1"; then
          sig=${1#-}
          sig=${sig#SIG}
          shift
        else
          echo "$MODE: option $1 is not supported here; use kill <pid>" >&2
          return 2
        fi
        ;;
      *) names+=("$1"); shift ;;
    esac
  done
  [[ ${#names[@]} -gt 0 ]] || { echo "usage: killall [-SIGNAL] [-s] [-m] [-q] [-u user] [-c name] name..." >&2; return 2; }
  [[ -n "$user" ]] && pg_args+=(-u "$user")
  [[ "$regex" == "1" ]] || pg_args+=(-x)
  for a in "${names[@]}"; do
    out=$("$REAL_PGREP" "${pg_args[@]}" -- "$a") || continue
    while read -r a _; do
      [[ "$a" =~ ^[0-9]+$ ]] && [[ "$a" != "$$" ]] && pids+=("$a")
    done <<<"$out"
  done
  if [[ ${#pids[@]} -eq 0 ]]; then
    [[ "$quiet" == "1" ]] || echo "No matching processes belonging to you were found" >&2
    return 1
  fi
  signal_and_report "$sig" "$dry" "${pids[@]}"
}

case "$MODE" in
  killall) run_killall "$@" ;;
  *) run_pkill "$@" ;;
esac
