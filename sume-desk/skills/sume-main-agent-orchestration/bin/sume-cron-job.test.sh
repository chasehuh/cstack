#!/usr/bin/env bash
# Offline tests for sume-cron-job (Mini cron → sume-bg-remote start).
# Real sume-bg-remote against a temp HOME; the launcher is a fake that
# records argv and sleeps, so no claude/grok/codex runs.
set -euo pipefail
unset SUME_WORKER_SESSION SUME_BG_REMOTE_JOB SUME_BG_ALLOW_NESTED AGENT_HUMAN_STREAM_PID AGENT_HUMAN_STREAM_NAME

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON="$ROOT/sume-cron-job.sh"

T=$(mktemp -d)
cleanup() {
  local d
  for d in "$T"/home/.cstack/state/remote-jobs/*/; do
    [[ -d "$d" ]] && "$ROOT/sume-bg-remote.sh" kill --job "$(basename "$d")" >/dev/null 2>&1 || true
  done
  sleep 1
  rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT
export HOME="$T/home" SHELL=/bin/sh SUME_BG_REMOTE_LOGIN_PATH=0
mkdir -p "$HOME/.cstack/cron"
cat >"$T/fake-launch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HOME/launch-argv.txt"
printf '%s\n' "$SHELL" >"$HOME/launch-shell.txt"
sleep "${FAKE_LAUNCH_SLEEP:-0}"
EOF
chmod +x "$T/fake-launch.sh"
export SUME_BG_LAUNCH_BIN="$T/fake-launch.sh"
JOBS="$HOME/.cstack/state/remote-jobs"
LOG="$HOME/.cstack/state/cron/demo.log"

pass=0
ok() { echo "ok - $*"; pass=$((pass + 1)); }
die() { echo "FAIL - $*" >&2; exit 1; }

# 1) no prompt → exit 2, nothing started
set +e; "$CRON" --name demo >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 2 ]] || die "missing prompt rc=$rc"
[[ ! -d "$JOBS" ]] || [[ -z "$(ls "$JOBS")" ]] || die "job dir created without prompt"
ok "missing prompt refused"

# 2) credential in prompt → exit 2
printf 'token ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123" >"$HOME/.cstack/cron/demo.md"
set +e; "$CRON" --name demo >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 2 ]] || die "secret prompt rc=$rc"
ok "credential-looking prompt refused"

# 3) inside a worker session → exit 5
echo "Do the demo." >"$HOME/.cstack/cron/demo.md"
set +e; SUME_WORKER_SESSION=x "$CRON" --name demo >/dev/null 2>&1; rc=$?; set -e
[[ $rc -eq 5 ]] || die "nested rc=$rc"
ok "nested fire refused"

# 4) first fire starts a detached job with Opus defaults + login shell
FAKE_LAUNCH_SLEEP=30 "$CRON" --name demo >/dev/null
JOB=$(ls "$JOBS" | grep -E '^[0-9]{8}T[0-9]{6}Z-demo$' | head -1)
[[ -n "$JOB" ]] || die "no job dir"
cmp -s "$HOME/.cstack/cron/demo.md" "$JOBS/$JOB/prompt.md" || die "prompt not staged"
for _ in $(seq 1 50); do [[ -s "$HOME/launch-argv.txt" ]] && break; sleep 0.1; done
tr '\n' ' ' <"$HOME/launch-argv.txt" | grep -q -- "--host local --backend claude --name demo --prompt-file $JOBS/$JOB/prompt.md -- --model claude-opus-5-5 --effort medium" \
  || die "launcher argv: $(tr '\n' ' ' <"$HOME/launch-argv.txt")"
[[ "$(cat "$HOME/launch-shell.txt")" != "/bin/sh" ]] || die "SHELL stayed /bin/sh"
"$ROOT/sume-bg-remote.sh" status --job "$JOB" | grep -q ' alive=yes ' || die "job not alive"
grep -q "started: " "$LOG" || die "no started line"
ok "fire starts one detached Opus job"

# 5) second fire while alive → skip, no new job
sleep 1
"$CRON" --name demo >/dev/null
[[ $(ls "$JOBS" | grep -cE -- '-demo$') -eq 1 ]] || die "second job started"
grep -q "skip: job $JOB still alive" "$LOG" || die "no skip line"
ok "overlapping fire skipped"

# 6) held lock → skip
mkdir "$JOBS/.cron-other.lock"
echo "x" >"$HOME/.cstack/cron/other.md"
"$CRON" --name other >/dev/null
[[ -z "$(ls "$JOBS" | grep -E -- '-other$' || true)" ]] || die "started under a held lock"
ok "held lock skipped"

# 7) after the job exits, the next fire starts a fresh one
"$ROOT/sume-bg-remote.sh" kill --job "$JOB" >/dev/null
sleep 1
"$CRON" --name demo >/dev/null
[[ $(ls "$JOBS" | grep -cE -- '-demo$') -eq 2 ]] || die "no fresh job after exit"
ok "fresh fire after exit"

echo "sume-cron-job: $pass passed"
