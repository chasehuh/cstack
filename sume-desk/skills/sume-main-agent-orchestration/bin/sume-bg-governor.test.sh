#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
unset SUME_WORKER_SESSION SUME_BG_REMOTE_JOB SUME_BG_ALLOW_NESTED AGENT_HUMAN_STREAM_PID AGENT_HUMAN_STREAM_NAME AGENT_HUMAN_STREAM_LIVE_LOG
unset GOV_MODE GOV_FAKE_LOAD GOV_FAKE_NOW GOV_FAKE_SSH_MS GOV_FAKE_MEMFREE GOV_FAKE_SWAP_MB GOV_FAKE_VM_PRESSURE GOV_FAKE_VMSTAT SUME_BG_FABLE_DOWNGRADE
unset GOV_HIGH_LOAD5 GOV_LOW_LOAD5 GOV_START_LOAD5 GOV_LOW_HOLD_MIN GOV_COOLDOWN_S GOV_MAX_PAUSE_MIN GOV_HEAVY_CPU GOV_HIGH_HOLD_S GOV_MAX_PAUSED GOV_MIN_RUNNING GOV_SWAPOUT_MBPS_HIGH GOV_MEM_FREE_LOW GOV_SSH_SLOW_MS

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="$ROOT/sume-bg-remote.sh"
GOV="$ROOT/sume-bg-governor.py"
QUOTA="$ROOT/cstack-quota.py"
PY=$(command -v python3)

T=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill -CONT -- "-$p" 2>/dev/null || true; kill -KILL -- "-$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

export HOME="$T/home"
export CSTACK_STATE="$T/state"
export SUME_BG_REMOTE_JOBS_DIR="$CSTACK_STATE/remote-jobs"
export CSTACK_TOKENMAXXING_DIR="$HOME/.config/tokenmaxxing"
export SUME_BG_REMOTE_LOGIN_PATH=0
export SUME_BG_ALERT_BATCH_S=0 SUME_BG_KILL_RESUME_DELAY=0 SUME_BG_LIMIT_RESUME_DELAY=0
export GOV_NOTIFY=0
export GOV_FAKE_SSH_MS=5 GOV_FAKE_MEMFREE=80 GOV_FAKE_SWAP_MB=0 GOV_FAKE_VM_PRESSURE=1 GOV_FAKE_VMSTAT="0,0"
mkdir -p "$HOME/.config/tokenmaxxing/bin" "$SUME_BG_REMOTE_JOBS_DIR" "$T/bin"

cat >"$T/bin/fake-slack-post" <<'EOS'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --text-file) cat "$2" >>"$FAKE_SLACK_LOG"; shift 2 ;;
    *) shift ;;
  esac
done
echo "SLACK: fake"
EOS
chmod +x "$T/bin/fake-slack-post"
export SUME_BG_SLACK_POST_BIN="$T/bin/fake-slack-post" FAKE_SLACK_LOG="$T/slack.log"
: >"$FAKE_SLACK_LOG"

cat >"$T/bin/fake-wrapper.sh" <<'EOS'
#!/usr/bin/env bash
name=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[$i]}" == "--name" ]] && name=${args[$((i + 1))]}; done
printf '%s\n' "$@" >"$FAKE_ARGV_DIR/$name-$$.txt"
echo "📎 session_id=${FAKE_SID:-deadbeef-0000-4000-8000-00000000fab1}  backend=claude  name=$name"
if [[ -n "${FAKE_FAIL_ONCE:-}" && -f "$FAKE_FAIL_ONCE" ]]; then
  rm -f "$FAKE_FAIL_ONCE"
  echo "You've reached your Fable limit. Switch to another model, or manage usage credits at https://claude.ai/settings/usage, to continue."
  exit 1
fi
if [[ -n "${FAKE_SLEEP:-}" ]]; then sleep "$FAKE_SLEEP"; fi
echo "—— final ——"
exit 0
EOS
chmod +x "$T/bin/fake-wrapper.sh"
export SUME_BG_LAUNCH_WRAPPER="$T/bin/fake-wrapper.sh" FAKE_ARGV_DIR="$T/argv"
mkdir -p "$FAKE_ARGV_DIR"

cat >"$HOME/.config/tokenmaxxing/bin/tokenmaxxing" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"$CSTACK_TOKENMAXXING_DIR/calls.log"
if [[ "${1:-}" == "switch" && -f "$CSTACK_TOKENMAXXING_DIR/need-gui" && "${FAKE_TM_GUI:-0}" != "1" ]]; then
  echo "tokenmaxxing: the login keychain is not readable from this session" >&2
  exit 1
fi
if [[ "${1:-}" == "switch" && -n "${2:-}" ]]; then
  python3 - "$CSTACK_TOKENMAXXING_DIR/accounts.json" "$2" <<'PY'
import json, sys
p, email = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for a in d["accounts"]:
    if a["email"] == email:
        d["activeAccountUuid"] = a["accountUuid"]
json.dump(d, open(p, "w"))
PY
fi
EOS
chmod +x "$HOME/.config/tokenmaxxing/bin/tokenmaxxing"

NOW_MS=$(( $(date +%s) * 1000 ))
LATER_MS=$(( NOW_MS + 86400000 ))
PAST_MS=$(( NOW_MS - 3600000 ))

write_accounts() {
  local a_fable="$1" a_week="$2" b_fable="$3" b_week="$4" live_fable="$5" with_d="${6:-}"
  cat >"$CSTACK_TOKENMAXXING_DIR/accounts.json" <<EOF
{"version": 1, "activeAccountUuid": "uuid-a", "accounts": [
 {"accountUuid": "uuid-a", "email": "a@example.com", "organizationUuid": "org-a", "needsReauth": false,
  "lastUsage": {"fiveHour": {"usedPercentage": 0, "resetsAt": null}, "sevenDay": {"usedPercentage": $a_week, "resetsAt": $LATER_MS}},
  "lastPerModel": {"Fable": {"usedPercentage": $a_fable, "resetsAt": $LATER_MS}}, "lastPerModelAt": $NOW_MS, "lastUsageAt": $NOW_MS},
 {"accountUuid": "uuid-b", "email": "b@example.com", "organizationUuid": "org-b", "needsReauth": false,
  "lastUsage": {"fiveHour": {"usedPercentage": 0, "resetsAt": null}, "sevenDay": {"usedPercentage": $b_week, "resetsAt": $LATER_MS}},
  "lastPerModel": {"Fable": {"usedPercentage": $b_fable, "resetsAt": $LATER_MS}}, "lastPerModelAt": $NOW_MS, "lastUsageAt": $NOW_MS},
 {"accountUuid": "uuid-c", "email": "c@example.com", "organizationUuid": "org-c", "needsReauth": true,
  "lastUsage": {"fiveHour": {"usedPercentage": 0, "resetsAt": null}, "sevenDay": {"usedPercentage": 0, "resetsAt": $LATER_MS}},
  "lastPerModel": {"Fable": {"usedPercentage": 0, "resetsAt": $LATER_MS}}, "lastPerModelAt": $NOW_MS, "lastUsageAt": $NOW_MS},
 {"accountUuid": "uuid-d", "email": "d@example.com", "organizationUuid": "org-d", "needsReauth": false,
  "lastUsage": {"fiveHour": {"usedPercentage": 0, "resetsAt": null}, "sevenDay": {"usedPercentage": 100, "resetsAt": $PAST_MS}},
  "lastPerModel": {"Fable": {"usedPercentage": 100, "resetsAt": $PAST_MS}}, "lastPerModelAt": $NOW_MS, "lastUsageAt": $NOW_MS}
]}
EOF
  if [[ "$with_d" != "with-d" ]]; then
    python3 - "$CSTACK_TOKENMAXXING_DIR/accounts.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["accounts"] = [a for a in d["accounts"] if a["email"] != "d@example.com"]
json.dump(d, open(p, "w"))
PY
  fi
  printf '{"perModel":{"Fable":{"usedPercentage":%s,"resetsAt":%s}},"org":"org-a","ts":%s,"sampledAt":%s}\n' "$live_fable" "$LATER_MS" "$NOW_MS" "$NOW_MS" >"$CSTACK_TOKENMAXXING_DIR/model-usage.json"
  printf '{"fiveHour":{"usedPercentage":0,"resetsAt":null},"sevenDay":{"usedPercentage":%s,"resetsAt":%s},"org":"org-a","ts":%s,"model":null}\n' "$a_week" "$LATER_MS" "$NOW_MS" >"$CSTACK_TOKENMAXXING_DIR/usage.json"
  : >"$CSTACK_TOKENMAXXING_DIR/calls.log"
}

plan() { "$PY" "$QUOTA" fable-plan | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["action"])'; }

write_accounts 10 20 50 60 99 with-d
OUT=$("$PY" "$QUOTA" status --json)
"$PY" - "$OUT" <<'PY' || fail "quota status json wrong: $OUT"
import json, sys
d = json.loads(sys.argv[1])
acc = {a["email"]: a for a in d["accounts"]}
assert acc["a@example.com"]["fable"] == 99 and acc["a@example.com"]["source"] == "live", acc["a@example.com"]
assert acc["d@example.com"]["fable"] == 0 and acc["d@example.com"]["week"] == 0, acc["d@example.com"]
assert acc["c@example.com"]["fable_headroom"] == 0 and not acc["c@example.com"]["fable_ok"]
assert d["pool"]["usable"] == 3 and d["pool"]["fable_ok_accounts"] == 2, d["pool"]
assert abs(d["pool"]["fable_headroom_pct"] - (1 + 40 + 100) / 3.0) < 0.2, d["pool"]
PY
"$PY" "$QUOTA" status | grep -q "Fable headroom 47% of pool" || fail "quota text: $("$PY" "$QUOTA" status)"
pass "quota reader: live active, rollover, re-auth excluded"

write_accounts 10 20 50 60 10
[[ "$(plan)" == "fable" ]] || fail "active with headroom must stay on Fable"
write_accounts 99 50 10 20 99
[[ "$(plan)" == "swap" ]] || fail "another account with Fable headroom must be a swap"
write_accounts 99 50 99 20 99
[[ "$(plan)" == "opus" ]] || fail "no Fable headroom anywhere must fall back to Opus: $("$PY" "$QUOTA" fable-plan)"
write_accounts 99 99 99 99 99
[[ "$(plan)" == "wait" ]] || fail "every account out of weekly quota must wait"
pass "fable-plan: fable, swap, opus, wait"

write_accounts 99 50 99 20 99
set +e
MSG=$("$PY" "$QUOTA" launch-check --model "Fable max" --running-fable 3); RC=$?
set -e
[[ $RC -eq 10 && "$MSG" == quota:* ]] || fail "low Fable headroom must warn (rc=$RC): $MSG"
"$PY" "$QUOTA" launch-check --model claude-opus-5-5 >/dev/null || fail "Opus launches are never quota-gated"
write_accounts 10 20 10 20 10
"$PY" "$QUOTA" launch-check --model fable >/dev/null || fail "plenty of Fable must not warn"
pass "launch check warns only for Fable with low headroom"

start_job() {
  local job="$1" name="$2"; shift 2
  mkdir -p "$SUME_BG_REMOTE_JOBS_DIR/$job"
  echo "Work on $name." >"$SUME_BG_REMOTE_JOBS_DIR/$job/prompt.md"
  "$REMOTE" start --job "$job" --backend claude --name "$name" --cwd "$T" "$@"
}

wait_for() {
  local what="$1" i
  for i in $(seq 1 150); do
    if eval "$what"; then return 0; fi
    sleep 0.2
  done
  return 1
}

write_accounts 99 50 99 20 99
: >"$FAKE_SLACK_LOG"
export FAKE_FAIL_ONCE="$T/fail-once"; : >"$FAKE_FAIL_ONCE"
export FAKE_SID="deadbeef-0000-4000-8000-00000000fab1"
start_job 20260101T000000Z-fq1 fq1 -- --model fable --effort max >/dev/null
wait_for 'ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq1-resume-deadbeef >/dev/null 2>&1 && grep -q "fq1" "$FAKE_SLACK_LOG"' || fail "Fable limit death must auto-resume and alert: $(cat "$SUME_BG_REMOTE_JOBS_DIR/20260101T000000Z-fq1/worker.log")"
R=$(ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq1-resume-deadbeef | head -n 1)
grep -q '^MODEL=claude-opus-5-5' "$R/job.env" || fail "resume must run on Opus 5.5: $(cat "$R/job.env")"
grep -q '^MODEL_FALLBACK=' "$R/job.env" || fail "job.env must record the fallback"
grep -qx 'max' "$R/extra.args" && grep -qx 'claude-opus-5-5' "$R/extra.args" || fail "resume flags must keep effort max: $(cat "$R/extra.args")"
grep -q 'MODEL FALLBACK' "$R/prompt.md" || fail "AUTO-RESUME prompt must explain the fallback"
grep -q "^RESUME=$FAKE_SID" "$R/job.env" || fail "fallback must resume the same session"
grep -q 'Opus 5.5 max' "$FAKE_SLACK_LOG" || fail "alert must name the fallback: $(cat "$FAKE_SLACK_LOG")"
wait_for '[[ -f "$R/exit_code" ]]' || fail "resumed job never finished"
pass "Fable limit → same session on Opus 5.5 at the same effort, noted in prompt, job.env and Slack"

write_accounts 99 50 10 20 99
: >"$FAKE_SLACK_LOG"; : >"$FAKE_FAIL_ONCE"
export FAKE_SID="deadbeef-0000-4000-8000-00000000fab2"
start_job 20260101T000100Z-fq2 fq2 -- --model fable --effort xhigh >/dev/null
wait_for 'ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq2-resume-deadbeef >/dev/null 2>&1 && grep -q "fq2" "$FAKE_SLACK_LOG"' || fail "swap case must auto-resume"
R=$(ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq2-resume-deadbeef | head -n 1)
grep -q 'switch b@example.com' "$CSTACK_TOKENMAXXING_DIR/calls.log" || fail "auto-resume must ask tokenmaxxing to switch to the account with Fable headroom: $(cat "$CSTACK_TOKENMAXXING_DIR/calls.log")"
grep -qx 'fable' "$R/extra.args" && ! grep -q '^MODEL_FALLBACK=' "$R/job.env" || fail "after a swap the worker stays on Fable: $(cat "$R/extra.args")"
grep -q '계정 전환' "$FAKE_SLACK_LOG" || fail "alert must say the account was switched: $(cat "$FAKE_SLACK_LOG")"
wait_for '[[ -f "$R/exit_code" ]]' || fail "swap resume never finished"
pass "Fable limit with headroom elsewhere → tokenmaxxing switch, stays on Fable"

write_accounts 99 50 10 20 99
: >"$CSTACK_TOKENMAXXING_DIR/need-gui"
: >"$FAKE_SLACK_LOG"; : >"$FAKE_FAIL_ONCE"
GOV_DIR="$CSTACK_STATE/governor" GOV_INTERVAL_S=1 GOV_FAKE_LOAD="5,5,5" FAKE_TM_GUI=1 perl -e 'setpgrp(0, 0); exec @ARGV' "$PY" "$GOV" daemon >"$T/swapd.out" 2>&1 &
SWAPD=$!
PIDS+=("$SWAPD")
wait_for '[[ -s "$CSTACK_STATE/governor/daemon.pid" ]]' || fail "swap daemon must start"
export FAKE_SID="deadbeef-0000-4000-8000-00000000fab5"
start_job 20260101T000150Z-fq5 fq5 -- --model fable --effort max >/dev/null
wait_for 'ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq5-resume-deadbeef >/dev/null 2>&1 && grep -q "fq5" "$FAKE_SLACK_LOG"' || fail "keychain-less swap case must auto-resume: $(cat "$SUME_BG_REMOTE_JOBS_DIR/20260101T000150Z-fq5/auto-resume.log" 2>/dev/null)"
R=$(ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq5-resume-deadbeef | head -n 1)
grep -q 'SWAP b@example.com rc=0' "$CSTACK_STATE/governor/log" || fail "the daemon must run the switch: $(cat "$CSTACK_STATE/governor/log")"
grep -qx 'fable' "$R/extra.args" && ! grep -q '^MODEL_FALLBACK=' "$R/job.env" || fail "a daemon swap keeps the worker on Fable: $(cat "$R/extra.args")"
grep -q '계정 전환' "$FAKE_SLACK_LOG" || fail "alert must say the account was switched: $(cat "$FAKE_SLACK_LOG")"
wait_for '[[ -f "$R/exit_code" ]]' || fail "daemon-swap resume never finished"
kill -TERM "$SWAPD" 2>/dev/null || true
wait_for '! kill -0 "$SWAPD" 2>/dev/null' || fail "swap daemon must stop on TERM"
rm -f "$CSTACK_TOKENMAXXING_DIR/need-gui" "$CSTACK_STATE/governor/daemon.pid"
pass "Fable limit over SSH (no keychain) → governor daemon runs tokenmaxxing switch, stays on Fable"

write_accounts 99 99 99 99 99
: >"$FAKE_SLACK_LOG"; : >"$FAKE_FAIL_ONCE"
export FAKE_SID="deadbeef-0000-4000-8000-00000000fab3"
start_job 20260101T000200Z-fq3 fq3 -- --model fable >/dev/null
wait_for 'grep -q "fq3" "$FAKE_SLACK_LOG"' || fail "weekly exhaustion must alert"
! ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-fq3-resume-* >/dev/null 2>&1 || fail "weekly exhaustion must not resume"
grep -q '주간 한도 소진' "$FAKE_SLACK_LOG" || fail "alert must say every account is out: $(cat "$FAKE_SLACK_LOG")"
unset FAKE_FAIL_ONCE
pass "all accounts out of weekly quota → no resume loop, explained alert"

write_accounts 99 50 99 20 99
export FAKE_SID="deadbeef-0000-4000-8000-00000000fab4"
OUT=$(start_job 20260101T000300Z-dg1 dg1 --fable-downgrade -- --model "Fable max")
[[ "$OUT" == *"model downgraded"* ]] || fail "downgrade must be announced: $OUT"
grep -q '^MODEL=claude-opus-5-5' "$SUME_BG_REMOTE_JOBS_DIR/20260101T000300Z-dg1/job.env" && grep -q '^MODEL_DOWNGRADE=' "$SUME_BG_REMOTE_JOBS_DIR/20260101T000300Z-dg1/job.env" || fail "job.env must record the downgrade"
grep -qx 'max' "$SUME_BG_REMOTE_JOBS_DIR/20260101T000300Z-dg1/extra.args" || fail "downgrade keeps effort max"
OUT=$(start_job 20260101T000400Z-dg2 dg2 -- --model fable)
[[ "$OUT" == *"quota: "* && "$OUT" == *"launching on Fable anyway"* ]] || fail "no flag: warn only: $OUT"
grep -qx 'fable' "$SUME_BG_REMOTE_JOBS_DIR/20260101T000400Z-dg2/extra.args" || fail "no flag must keep Fable"
pass "launch: warn on low Fable headroom, downgrade only with --fable-downgrade (never silent)"

for j in dg1 dg2; do wait_for '[[ -f "$(ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-$j | head -n 1)/exit_code" ]]' || true; done

fake_job() {
  local job="$1" name="$2" started="$3" extra_env="${4:-}" cmd="${5:-sleep 300}"
  local d="$SUME_BG_REMOTE_JOBS_DIR/$job"
  mkdir -p "$d"
  perl -e 'setpgrp(0, 0); exec @ARGV' bash -c "$cmd" &
  local pid=$!
  PIDS+=("$pid")
  sleep 0.2
  echo "$pid" >"$d/pid"; echo "$pid" >"$d/pgid"
  ps -o lstart= -p "$pid" | sed 's/^ *//;s/ *$//' >"$d/pid_start"
  printf 'JOB=%s\nNAME=%s\nSTARTED=%s\n%s\n' "$job" "$name" "$started" "$extra_env" >"$d/job.env"
  echo "📎 session_id=deadbeef-0000-4000-8000-$(printf '%012d' "${#PIDS[@]}")  backend=claude  name=$name" >"$d/worker.log"
}

stopped() { [[ "$(ps -o stat= -p "$(cat "$SUME_BG_REMOTE_JOBS_DIR/$1/pid")" | tr -d ' ')" == T* ]]; }

export GOV_DIR="$T/gov-default"
rm -rf "${SUME_BG_REMOTE_JOBS_DIR:?}"/*
fake_job 20260101T000500Z-busy-feat busy-feat 2026-01-01T00:05:00Z
"$PY" "$GOV" mode enforce >/dev/null
for n in 0 100 200; do GOV_FAKE_NOW=$((1800000000 + n)) GOV_HEAVY_CPU=-1 GOV_FAKE_LOAD="60,55,50" GOV_FAKE_SWAP_MB=12000 "$PY" "$GOV" once >/dev/null; done
stopped 20260101T000500Z-busy-feat && fail "default: high load and swap with sshd up must not pause"
for n in 300 400; do GOV_FAKE_NOW=$((1800000000 + n)) GOV_HEAVY_CPU=-1 GOV_FAKE_LOAD="60,55,50" GOV_FAKE_SSH_MS=down "$PY" "$GOV" once >/dev/null; done
stopped 20260101T000500Z-busy-feat || fail "default: sshd down for 100 s must pause"
"$PY" "$GOV" status | grep -q "load never pauses" || fail "default status must say load never pauses"
"$PY" "$GOV" resume 20260101T000500Z-busy-feat >/dev/null
pass "default policy: only sshd (or memory) pressure pauses; load and swap alone never do"

export GOV_DIR="$T/gov"
export GOV_HEAVY_CPU=-1 GOV_HIGH_LOAD5=22 GOV_LOW_LOAD5=12 GOV_COOLDOWN_S=60 GOV_LOW_HOLD_MIN=5 GOV_MAX_PAUSE_MIN=30
tick() { local at="$1" load="$2"; shift 2; env GOV_FAKE_NOW="$at" GOV_FAKE_LOAD="$load" "$@" "$PY" "$GOV" once >/dev/null; }
reset_gov() {
  for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill -CONT -- "-$p" 2>/dev/null || true; kill -KILL -- "-$p" 2>/dev/null || true; done
  PIDS=()
  rm -rf "${SUME_BG_REMOTE_JOBS_DIR:?}"/* "${GOV_DIR:?}"
  mkdir -p "$SUME_BG_REMOTE_JOBS_DIR"
  "$PY" "$GOV" mode "$1" >/dev/null
}
paused_count() { local n=0 j; for j in "$SUME_BG_REMOTE_JOBS_DIR"/*/; do [[ -f "$j/governor-paused" ]] && n=$((n + 1)); done; echo "$n"; }
T0=1800000000

reset_gov enforce
for i in 1 2 3 4 5 6 7; do fake_job "20261115T03${i}000Z-worker-$i" "worker-$i" "2026-11-15T03:${i}0:00Z"; done
SWAP=4164
SO=882020
for n in $(seq 0 90); do
  SWAP=$((SWAP + 70)); SO=$((SO + 120))
  tick $((T0 + n * 30)) "$((7 + n % 9)),$((9 + n % 7)),11" GOV_FAKE_SWAP_MB=$SWAP GOV_FAKE_MEMFREE=84 GOV_FAKE_VM_PRESSURE=1 GOV_FAKE_VMSTAT="219576,$SO"
done
for i in 1 2 3 4 5 6 7; do
  W="$SUME_BG_REMOTE_JOBS_DIR/20261115T03${i}000Z-worker-$i"
  kill -0 "$(cat "$W/pid")" 2>/dev/null && ! stopped "20261115T03${i}000Z-worker-$i" && [[ ! -f "$W/governor-stopped" ]] \
    || fail "sticky swap with low load and normal memory pressure must leave worker-$i running: $(grep -E 'PAUSE|CONVERT' "$GOV_DIR/log" | head -n 9)"
done
! grep -qE 'PAUSE|CONVERT|HIGH' "$GOV_DIR/log" || fail "no pressure was real, nothing may be logged as high: $(cat "$GOV_DIR/log")"
"$PY" "$GOV" status | grep -q "never a trigger" || fail "status must show swap used as information only"
pass "11-15 replay: swap used 4.2→10.5 GB, load 7–15, memory free 84 %, pressure normal → nothing paused or stopped"

reset_gov enforce
for i in 1 2 3 4 5; do fake_job "20261115T04${i}000Z-busy-$i" "busy-$i" "2026-11-15T04:${i}0:00Z"; done
tick $T0 "26,25,20"
[[ "$(paused_count)" == "0" ]] || fail "one high sample must not pause"
tick $((T0 + 30)) "8,20,20"
tick $((T0 + 60)) "26,25,20"
tick $((T0 + 120)) "26,25,20"
[[ "$(paused_count)" == "0" ]] || fail "a dip resets the hold; 60 s of high must not pause yet"
tick $((T0 + 160)) "26,25,20"
[[ "$(paused_count)" == "1" ]] || fail "high held 100 s must pause one job: $(cat "$GOV_DIR/log")"
tick $((T0 + 400)) "9,9,9" GOV_FAKE_SSH_MS=down
tick $((T0 + 430)) "9,9,9" GOV_FAKE_SSH_MS=5
[[ "$(paused_count)" == "1" ]] || fail "a one-off sshd miss must not pause another job"
grep -q 'sshd down for' "$GOV_DIR/log" || fail "a one-off sshd miss is only logged: $(cat "$GOV_DIR/log")"
pass "act only on pressure held for 90 s; a dip or a one-off sshd miss resets it"

reset_gov enforce
for i in 1 2 3 4; do fake_job "20261115T05${i}000Z-heavy-$i" "heavy-$i" "2026-11-15T05:${i}0:00Z"; done
for n in 0 4 8 12 16 20; do tick $((T0 + n * 30)) "26,25,20"; done
[[ "$(paused_count)" == "1" ]] || fail "4 running: pause only down to the 3-job floor: $(grep -E 'PAUSE|floor' "$GOV_DIR/log")"
grep -q 'running (floor 3)' "$GOV_DIR/log" || fail "the floor must be logged"
for n in 24 28 32 36 40 44; do tick $((T0 + n * 30)) "26,25,20" GOV_FAKE_SSH_MS=down; done
[[ "$(paused_count)" == "2" ]] || fail "sshd failing lifts the floor but the cap of 2 holds: $(grep -E 'PAUSE|cap' "$GOV_DIR/log")"
grep -q 'held back (cap 2)' "$GOV_DIR/log" || fail "the cap must be logged"
pass "never the whole fleet: at most 2 held back, at least 3 running unless sshd is failing"

reset_gov enforce
for i in 1 2 3 4 5; do fake_job "20261115T06${i}000Z-mem-$i" "mem-$i" "2026-11-15T06:${i}0:00Z"; done
for n in 0 4; do tick $((T0 + n * 30)) "9,9,9" GOV_FAKE_VM_PRESSURE=2 GOV_FAKE_VMSTAT="100,$((1000 + n))"; done
[[ "$(paused_count)" == "0" ]] || fail "warn pressure without swap-out traffic is not struggling"
tick $((T0 + 300)) "9,9,9" GOV_FAKE_VM_PRESSURE=2 GOV_FAKE_VMSTAT="100,2000"
tick $((T0 + 330)) "9,9,9" GOV_FAKE_VM_PRESSURE=2 GOV_FAKE_VMSTAT="100,42000"
tick $((T0 + 360)) "9,9,9" GOV_FAKE_VM_PRESSURE=2 GOV_FAKE_VMSTAT="100,82000"
tick $((T0 + 420)) "9,9,9" GOV_FAKE_VM_PRESSURE=2 GOV_FAKE_VMSTAT="100,162000"
[[ "$(paused_count)" == "1" ]] || fail "warn pressure + sustained swap-out ≥ 16 MB/s must pause one: $(cat "$GOV_DIR/log")"
grep -q 'swapping out' "$GOV_DIR/log" || fail "pause reason must name the swap-out rate"
for n in 30 34 38; do tick $((T0 + n * 30)) "9,9,9" GOV_FAKE_VM_PRESSURE=4 GOV_FAKE_VMSTAT="100,162000"; done
[[ "$(paused_count)" == "2" ]] || fail "sustained critical kernel pressure must pause: $(cat "$GOV_DIR/log")"
pass "memory: kernel pressure critical, or warn + swap-out rate, never swap used"

reset_gov observe
fake_job 20260101T010000Z-older-research older-research 2026-01-01T01:00:00Z
fake_job 20260101T020000Z-newer-research newer-research 2026-01-01T02:00:00Z
fake_job 20260101T030000Z-feature-x feature-x 2026-01-01T03:00:00Z
fake_job 20260101T040000Z-release-170 release-170 2026-01-01T04:00:00Z
fake_job 20260101T050000Z-mq-wait mq-wait 2026-01-01T05:00:00Z "PRIORITY=low" "sleep 300; : cstack-gt-wait-merge"
export GOV_HIGH_HOLD_S=0
tick $T0 "26,25,20"
for j in 20260101T010000Z-older-research 20260101T020000Z-newer-research 20260101T030000Z-feature-x; do stopped "$j" && fail "observe mode must not pause $j"; done
grep -q "WOULD PAUSE 20260101T020000Z-newer-research" "$GOV_DIR/log" || fail "observe log must name the newest low-priority job: $(cat "$GOV_DIR/log")"
pass "observe mode: logs WOULD PAUSE, touches nothing"

"$PY" "$GOV" mode enforce >/dev/null
tick $T0 "26,25,20"
stopped 20260101T020000Z-newer-research || fail "enforce must SIGSTOP the newest low-priority job"
stopped 20260101T010000Z-older-research && fail "one pause per cooldown"
[[ -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T020000Z-newer-research/governor-paused" ]] || fail "pause marker missing"
"$REMOTE" status --job 20260101T020000Z-newer-research | grep -q "alive=yes state=paused" || fail "remote status must show paused"
tick $((T0 + 10)) "26,25,20"
stopped 20260101T010000Z-older-research && fail "cooldown must hold the second pause"
tick $((T0 + 70)) "26,25,20"
stopped 20260101T010000Z-older-research || fail "after cooldown the next low-priority job pauses"
tick $((T0 + 140)) "26,25,20"
stopped 20260101T030000Z-feature-x && fail "the cap of 2 held-back jobs must stop a third pause"
tick $((T0 + 210)) "26,25,20" GOV_MAX_PAUSED=9 GOV_MIN_RUNNING=0
stopped 20260101T030000Z-feature-x || fail "with room under the cap the normal-priority job is next"
for n in 280 350 420; do tick $((T0 + n)) "26,25,20" GOV_MAX_PAUSED=9 GOV_MIN_RUNNING=0; done
stopped 20260101T040000Z-release-170 && fail "a release job is never paused"
stopped 20260101T050000Z-mq-wait && fail "a job waiting on the merge queue is never paused"
grep -q "no pausable heavy job" "$GOV_DIR/log" || fail "governor must log when nothing is pausable"
pass "enforce: lowest priority newest first, cooldown, cap, release and merge-queue jobs never paused"

tick $((T0 + 500)) "15,16,18"
stopped 20260101T030000Z-feature-x || fail "between low and high water nothing resumes"
tick $((T0 + 560)) "8,10,14"
stopped 20260101T030000Z-feature-x || fail "low load must hold for the hold time before resuming"
tick $((T0 + 900)) "8,10,14"
stopped 20260101T030000Z-feature-x && fail "after the hold the highest-priority paused job resumes"
stopped 20260101T020000Z-newer-research || fail "only one resume per cooldown"
pass "hysteresis: hold time + cooldown, highest priority resumes first"

"$PY" "$GOV" pin 20260101T030000Z-feature-x >/dev/null
tick $((T0 + 1000)) "26,25,20" GOV_MAX_PAUSED=9 GOV_MIN_RUNNING=0
stopped 20260101T030000Z-feature-x && fail "pinned job paused"
set +e
"$PY" "$GOV" pause 20260101T040000Z-release-170 >/dev/null 2>&1; RC=$?
set -e
[[ $RC -eq 3 ]] || fail "manual pause of a critical job must refuse (rc=$RC)"
"$PY" "$GOV" resume 20260101T010000Z-older-research >/dev/null
stopped 20260101T010000Z-older-research && fail "manual resume must SIGCONT"
"$PY" "$GOV" status | grep -q "pinned (never paused): 20260101T030000Z-feature-x" || fail "status must list pins"
pass "manual pin / pause / resume"

stopped 20260101T020000Z-newer-research || fail "newer-research should still be paused here"
tick $((T0 + 2000)) "15,16,18"
stopped 20260101T020000Z-newer-research && fail "past the max pause with the pressure gone the job must resume, not stop"
[[ -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T020000Z-newer-research/exit_code" ]] && fail "a calm Mini must never stop a paused job"
grep -q 'RESUME 20260101T020000Z-newer-research' "$GOV_DIR/log" || fail "the resume must be logged: $(tail -n 5 "$GOV_DIR/log")"
pass "paused too long but pressure gone → resume, never a stop"
unset GOV_HIGH_HOLD_S

reset_gov off
: >"$FAKE_SLACK_LOG"
export FAKE_SID="deadbeef-0000-4000-8000-00000000c0a1"
FAKE_SLEEP=120 start_job 20260101T060000Z-long-explore long-explore -- --model claude-opus-5-5 --effort high >/dev/null
J=20260101T060000Z-long-explore
wait_for 'grep -q session_id "$SUME_BG_REMOTE_JOBS_DIR/$J/worker.log"' || fail "long job never started"
"$PY" "$GOV" mode enforce >/dev/null
"$PY" "$GOV" pause "$J" >/dev/null
stopped "$J" || fail "manual pause failed"
NOWS=$(date +%s)
tick $((NOWS + 29 * 60)) "26,25,20" GOV_MIN_RUNNING=0
tick $((NOWS + 31 * 60)) "26,25,20" GOV_MIN_RUNNING=0
wait_for '[[ -f "$SUME_BG_REMOTE_JOBS_DIR/$J/exit_code" ]]' || fail "a long pause under sustained pressure must stop the job cleanly: $(tail -n 3 "$GOV_DIR/log")"
[[ -f "$SUME_BG_REMOTE_JOBS_DIR/$J/governor-stopped" && -f "$SUME_BG_REMOTE_JOBS_DIR/$J/stopped" ]] || fail "governor stop markers missing"
sleep 1
! grep -q "long-explore" "$FAKE_SLACK_LOG" || fail "a governor stop must not be reported as an abnormal death: $(cat "$FAKE_SLACK_LOG")"
tick $((NOWS + 32 * 60)) "5,5,5"
tick $((NOWS + 40 * 60)) "5,5,5"
R=$(ls -d "$SUME_BG_REMOTE_JOBS_DIR"/*-long-explore-resume-deadbeef 2>/dev/null | head -n 1)
[[ -n "$R" ]] || fail "governor must relaunch the stopped session: $(tail -n 5 "$GOV_DIR/log")"
grep -q 'PAUSED BY GOVERNOR' "$R/prompt.md" || fail "relaunch prompt must say PAUSED BY GOVERNOR"
grep -q "^RESUME=$FAKE_SID" "$R/job.env" && grep -q "^GOVERNOR_RESUME_OF=$J" "$R/job.env" || fail "relaunch must resume the same session: $(cat "$R/job.env" 2>&1) $(grep -E "RELAUNCH|CONVERT" "$GOV_DIR/log")"
grep -qx 'claude-opus-5-5' "$R/extra.args" || fail "relaunch must keep the backend flags"
wait_for '[[ -f "$R/exit_code" ]]' || true
pass "long pause under sustained pressure → clean stop (no death alert) → PAUSED BY GOVERNOR resume of the same session"

reset_gov enforce
TWIN_SID="deadbeef-0000-4000-8000-00000000e1e1"
TWIN_OLD=20261115T031033Z-sandbox-x-resume-deadbeef
TWIN_NEW=20261115T044235Z-sandbox-x-resume-deadbeef
mkdir -p "$SUME_BG_REMOTE_JOBS_DIR/$TWIN_OLD"
printf 'JOB=%s\nNAME=sandbox-x\nRESUME=%s\nFORK=0\n' "$TWIN_OLD" "$TWIN_SID" >"$SUME_BG_REMOTE_JOBS_DIR/$TWIN_OLD/job.env"
echo 143 >"$SUME_BG_REMOTE_JOBS_DIR/$TWIN_OLD/exit_code"
fake_job "$TWIN_NEW" sandbox-x 2026-11-15T04:42:35Z "RESUME=$TWIN_SID
FORK=0"
"$PY" - "$GOV_DIR/state.json" "$TWIN_SID" "$TWIN_OLD" <<'PY'
import json, sys, calendar, time
p, sid, job = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
at = calendar.timegm(time.strptime("20261115T042748Z", "%Y%m%dT%H%M%SZ"))
d.setdefault("gov_stopped", {})[job] = {
    "at": at, "sid": sid, "name": "sandbox-x", "backend": "claude", "cwd": "/tmp", "priority": "normal",
    "extra": [], "slack_report": "0", "same_thread": "0", "paused_at": at - 1800}
json.dump(d, open(p, "w"))
PY
for n in 0 400; do tick $((1794717000 + n)) "5,5,5"; done
EXTRA_RESUMES=$(ls "$SUME_BG_REMOTE_JOBS_DIR" | grep -e '-sandbox-x-resume-deadbeef' | grep -v -e "$TWIN_OLD" -e "$TWIN_NEW" || true)
[[ -z "$EXTRA_RESUMES" ]] || fail "a session someone already resumed must not be relaunched: $EXTRA_RESUMES"
grep -q "DROP-STOPPED $TWIN_OLD: session deadbeef was already resumed by $TWIN_NEW" "$GOV_DIR/log" || fail "the drop must be logged: $(cat "$GOV_DIR/log")"
stopped "$TWIN_NEW" && fail "the other resume must be left alone"
kill -0 "$(cat "$SUME_BG_REMOTE_JOBS_DIR/$TWIN_NEW/pid")" || fail "the other resume must keep running"
pass "no twins: a stopped session that someone else resumed is dropped, never relaunched over it"

reset_gov enforce
export GOV_MIN_RUNNING=0
export FAKE_SID="deadbeef-0000-4000-8000-00000000a0d1"
OUT=$(GOV_FAKE_LOAD="26,25,20" start_job 20260101T070000Z-queued-feat queued-feat -- --model claude-opus-5-5)
[[ "$OUT" == *"queued job=20260101T070000Z-queued-feat"* ]] || fail "busy Mini must queue: $OUT"
[[ -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T070000Z-queued-feat/queued" && ! -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T070000Z-queued-feat/pid" ]] || fail "queued job must not start"
"$REMOTE" status --job 20260101T070000Z-queued-feat | grep -q "state=queued" || fail "status must show queued"
OUT=$(GOV_FAKE_LOAD="26,25,20" start_job 20260101T070050Z-manual-feat manual-feat -- --model claude-opus-5-5)
[[ "$OUT" == *"queued job=20260101T070050Z-manual-feat"* && "$OUT" == *"--governor start 20260101T070050Z-manual-feat"* ]] || fail "queued output must say how to start it now: $OUT"
GOV_FAKE_LOAD="26,25,20" "$PY" "$GOV" start 20260101T070050Z-manual-feat >/dev/null || fail "manual start of a queued job"
[[ -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T070050Z-manual-feat/pid" && ! -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T070050Z-manual-feat/queued" ]] || fail "manual start must start the queued job"
OUT=$(GOV_FAKE_LOAD="26,25,20" start_job 20260101T070100Z-urgent urgent --now -- --model claude-opus-5-5)
[[ "$OUT" == *"started job=20260101T070100Z-urgent"* ]] || fail "--now must bypass the queue: $OUT"
OUT=$(GOV_FAKE_LOAD="26,25,20" start_job 20260101T070200Z-release-171 release-171 -- --model claude-opus-5-5)
[[ "$OUT" == *"started job="* ]] || fail "a release job is never queued: $OUT"
GOV_FAKE_NOW=$(( $(date +%s) + 3600 )) GOV_FAKE_LOAD="9,9,9" "$PY" "$GOV" once >/dev/null
wait_for '[[ -f "$SUME_BG_REMOTE_JOBS_DIR/20260101T070000Z-queued-feat/pid" ]]' || fail "governor must start the queued job: $(tail -n 3 "$GOV_DIR/log")"
grep -q '^QUEUED_AT=' "$SUME_BG_REMOTE_JOBS_DIR/20260101T070000Z-queued-feat/job.env" || fail "started job keeps QUEUED_AT"
OUT=$(GOV_MIN_RUNNING=9 GOV_FAKE_LOAD="26,25,20" start_job 20260101T070300Z-floor-feat floor-feat -- --model claude-opus-5-5)
[[ "$OUT" == *"started job=20260101T070300Z-floor-feat"* ]] || fail "below the running floor a busy Mini still starts the job: $OUT"
unset GOV_MIN_RUNNING
pass "admission queue: busy → queued, manual start, --now, release and running-floor bypass, governor starts it later"

for j in "$SUME_BG_REMOTE_JOBS_DIR"/*; do wait_for "[[ -f '$j/exit_code' ]]" || true; done
rm -rf "${SUME_BG_REMOTE_JOBS_DIR:?}"/*
fake_job 20260101T080000Z-fable-a fable-a 2026-01-01T08:00:00Z "MODEL=fable
EFFORT=max"
fake_job 20260101T080100Z-fable-b fable-b 2026-01-01T08:01:00Z "MODEL=claude-fable-5-2
EFFORT=xhigh"
write_accounts 85 50 85 20 85
OUT=$(GOV_FAKE_LOAD="5,5,5" start_job 20260101T080200Z-fable-c fable-c -- --model fable --effort max)
[[ "$OUT" == *"queued job=20260101T080200Z-fable-c"* && "$OUT" == *"fable-stagger"* ]] || fail "third heavy Fable job must wait: $OUT"
OUT=$(GOV_FAKE_LOAD="5,5,5" start_job 20260101T080300Z-opus-d opus-d -- --model claude-opus-5-5 --effort max)
[[ "$OUT" == *"started job="* ]] || fail "Opus jobs are not Fable-staggered: $OUT"
pass "Fable stagger queues the third heavy Fable job when headroom is low"

mkdir -p "$SUME_BG_REMOTE_JOBS_DIR/20251030T000000Z-stale-reuse"
echo "$$" >"$SUME_BG_REMOTE_JOBS_DIR/20251030T000000Z-stale-reuse/pid"
printf 'JOB=20251030T000000Z-stale-reuse\nNAME=stale-reuse\n' >"$SUME_BG_REMOTE_JOBS_DIR/20251030T000000Z-stale-reuse/job.env"
"$PY" - "$GOV" <<'PY' || fail "critical-phase matcher"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gov", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
crit = ["git push origin x", "git merge --no-ff x", "git tag v1.2.3", "gh pr merge 1 --squash", "gh stack submit --auto", "cstack-gt-wait-merge 12", "cstack-gate -- pnpm test"]
calm = ["git merge-base HEAD origin/main", "git tag -l", "git status", "git log --oneline", "gh pr view 1"]
bad = [c for c in crit if not g.CRIT_PROC.search(c)] + [c for c in calm if g.CRIT_PROC.search(c)]
sys.exit(1 if bad else 0)
PY
"$PY" "$GOV" status >"$T/status.txt"
grep -q "Mini governor: mode=enforce" "$T/status.txt" && grep -q "queued" "$T/status.txt" && grep -q "quota: Fable headroom" "$T/status.txt" || fail "status output: $(cat "$T/status.txt")"
grep -q "stale-reuse" "$T/status.txt" && fail "a job whose pid was reused (no pid_start, no --job in the command) must not show as running"
pass "status shows mode, load, quota and queued jobs; skips reused pids; git merge-base and tag -l are not critical"

cp "$GOV" "$T/gov-copy.py"
GOV_DIR="$T/gov2" GOV_INTERVAL_S=1 GOV_FAKE_LOAD="5,5,5" perl -e 'setpgrp(0, 0); exec @ARGV' "$PY" "$T/gov-copy.py" daemon >"$T/daemon1.out" 2>&1 &
D1=$!
PIDS+=("$D1")
wait_for '[[ -s "$T/gov2/daemon.pid" ]]' || fail "daemon must write its pid"
OUT=$(GOV_DIR="$T/gov2" "$PY" "$T/gov-copy.py" daemon 2>&1)
[[ "$OUT" == *"another daemon holds"* ]] || fail "a second daemon must exit at once: $OUT"
kill -0 "$D1" 2>/dev/null || fail "the first daemon must keep running"
sleep 1
touch "$T/gov-copy.py"
wait_for '! kill -0 "$D1" 2>/dev/null' || fail "daemon must exit after its code changes"
grep -q "code changed on disk" "$T/gov2/log" || fail "daemon must log why it exited: $(cat "$T/gov2/log")"
pass "daemon: single instance, restarts on a code update"

echo "sume-bg-governor tests: all ok"
