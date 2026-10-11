#!/usr/bin/env bash
# Offline tests for the completion-report tail (docs/SLACK-REPORT.md):
# agent-human-stream appends it once, the opt-outs and markers hold, resume
# gets the steer line, sume-bg-launch --print-prompt shows the final prompt,
# and cstack-slack-post refuses bad text. Fake backends and a fake ego-browser;
# nothing reaches Slack.
set -euo pipefail
unset SUME_WORKER_SESSION SUME_BG_REMOTE_JOB SUME_BG_ALLOW_NESTED AGENT_HUMAN_STREAM_PID AGENT_HUMAN_STREAM_NAME AGENT_HUMAN_STREAM_LIVE_LOG CSTACK_SLACK_REPORT AGENT_HUMAN_STREAM_MODEL AGENT_HUMAN_STREAM_BACKEND

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$ROOT/agent-human-stream.sh"
LAUNCH="$ROOT/sume-bg-launch.sh"
POST="$ROOT/cstack-slack-post.sh"
TAIL="$ROOT/../references/slack-report-tail.md"
TAIL_MARK='<!-- slack-report:tail v1 -->'
STEER_MARK='[slack-report] Steer turn'

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export AGENT_HUMAN_STREAM_REGISTRY="$T/reg.jsonl" AGENT_HUMAN_STREAM_LIVE_DIR="$T/live"
export TOKENMAXXING_REQUIRE_SUPERVISOR=0

# Fake backends: dump the prompt argument (the one carrying the preamble).
for b in claude grok codex; do
  cat >"$T/$b" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
body = next((a for a in sys.argv[1:] if a.startswith("[sume worker session]")), "")
Path(os.environ["PROMPT_OUT"]).write_text(body)
print(json.dumps({"type": "result", "session_id": "00000000-0000-0000-0000-000000000000", "result": "ok"}))
print(json.dumps({"type": "thread.started", "thread_id": "00000000-0000-0000-0000-000000000000"}))
EOF
  chmod +x "$T/$b"
done
export PATH="$T:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
count() { grep -cF -- "$1" "$2" || true; }

printf 'Fix the thing (#42).\n' >"$T/p.md"

# 1) tail file: one source, both sections, the desk rules.
grep -qF "$TAIL_MARK" "$TAIL" || fail "tail marker missing in $TAIL"
grep -qF '<!-- slack-report:steer v1 -->' "$TAIL" || fail "steer marker missing"
for want in C0A9L7AU5HS '600 characters' 'SLACK_TEXT:' 'session limit' 'secrets' 'LANDED: yes|no' 'cstack-slack-post' '{{JOB}}' '{{LANE}}'; do
  grep -qF -- "$want" "$TAIL" || fail "tail lacks: $want"
done
pass "tail file carries the format and rules"

# 2) fresh launch, --prompt-file and inline: tail appended exactly once, job + lane filled in.
"$WRAP" --print-prompt --backend claude --name demo-job --prompt-file "$T/p.md" --model claude-fable-5-1 >"$T/a.txt" 2>"$T/a.err"
[[ $(count "$TAIL_MARK" "$T/a.txt") -eq 1 ]] || fail "--prompt-file: tail count != 1"
grep -qF 'Fix the thing (#42).' "$T/a.txt" || fail "task text missing"
grep -qF '`Fable : demo-job (#N)`' "$T/a.txt" || fail "lane/job not substituted"
! grep -qF '{{' "$T/a.txt" || fail "placeholder left"
grep -q 'slack-report: tail appended' "$T/a.err" || fail "stderr note missing"
[[ $(count "$STEER_MARK" "$T/a.txt") -eq 0 ]] || fail "fresh launch must not get the steer line"
awk -v m="$TAIL_MARK" 'index($0,"Fix the thing"){t=NR} index($0,m){k=NR} END{exit !(t && k && t<k)}' "$T/a.txt" || fail "tail must follow the task"
"$WRAP" --print-prompt --backend grok --name inline-job "Inline task text" >"$T/b.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/b.txt") -eq 1 ]] || fail "inline: tail count != 1"
grep -qF '`Grok : inline-job (#N)`' "$T/b.txt" || fail "grok lane"
pass "fresh launch appends the tail once (file + inline)"

# 3) opt-outs: flag, env, prompt marker. Already-tailed prompt is not doubled.
"$WRAP" --print-prompt --name x --no-slack-report --prompt-file "$T/p.md" >"$T/c.txt" 2>"$T/c.err"
[[ $(count 'slack-report:' "$T/c.txt") -eq 0 ]] || fail "--no-slack-report still appended"
grep -q 'slack-report: off' "$T/c.err" || fail "off note missing"
CSTACK_SLACK_REPORT=0 "$WRAP" --print-prompt --name x --prompt-file "$T/p.md" >"$T/d.txt" 2>/dev/null
[[ $(count 'slack-report:' "$T/d.txt") -eq 0 ]] || fail "CSTACK_SLACK_REPORT=0 still appended"
printf 'Research only. <!-- slack-report:off -->\n' >"$T/off.md"
"$WRAP" --print-prompt --name x --prompt-file "$T/off.md" >"$T/e.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/e.txt") -eq 0 ]] || fail "off marker ignored"
cp "$T/a.txt" "$T/tailed.md"
"$WRAP" --print-prompt --name demo-job --prompt-file "$T/tailed.md" >"$T/f.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/f.txt") -eq 1 ]] || fail "tail duplicated on an already-tailed prompt"
pass "opt-outs (flag, env, marker) and idempotence"

# 4) resume = steer line only; fork = full tail; continue = steer.
"$WRAP" --print-prompt --resume deadbeef --name demo-job --prompt-file "$T/p.md" >"$T/g.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/g.txt") -eq 0 ]] || fail "resume got the full tail"
[[ $(count "$STEER_MARK on job \"demo-job\"" "$T/g.txt") -eq 1 ]] || fail "resume lacks the steer line"
"$WRAP" --print-prompt --resume deadbeef --fork-session --name fork-job --prompt-file "$T/p.md" >"$T/h.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/h.txt") -eq 1 ]] || fail "fork must get the full tail"
[[ $(count "$STEER_MARK" "$T/h.txt") -eq 0 ]] || fail "fork must not get the steer line"
"$WRAP" --print-prompt --continue --name demo-job --prompt-file "$T/p.md" >"$T/i.txt" 2>/dev/null
[[ $(count "$STEER_MARK" "$T/i.txt") -eq 1 ]] || fail "--continue lacks the steer line"
CSTACK_SLACK_REPORT=0 "$WRAP" --print-prompt --resume deadbeef --name demo-job --prompt-file "$T/p.md" >"$T/j.txt" 2>/dev/null
[[ $(count 'slack-report' "$T/j.txt") -eq 0 ]] || fail "opt-out must also drop the steer line"
pass "resume steer / fork tail / continue steer"

# 5) real launches reach every backend with the tail (not just the dry run).
for b in claude grok codex; do
  PROMPT_OUT="$T/argv-$b.txt" "$WRAP" --backend "$b" --name "run-$b" --prompt-file "$T/p.md" --effort low >/dev/null 2>&1 \
    || fail "$b launch failed"
  [[ $(count "$TAIL_MARK" "$T/argv-$b.txt") -eq 1 ]] || fail "$b prompt lacks the tail"
done
PROMPT_OUT="$T/argv-off.txt" "$WRAP" --backend claude --name run-off --no-slack-report --prompt-file "$T/p.md" --effort low >/dev/null 2>&1
[[ $(count 'slack-report' "$T/argv-off.txt") -eq 0 ]] || fail "launch --no-slack-report still appended"
pass "claude/grok/codex launches carry the tail; flag drops it"

# 6) sume-bg-launch --print-prompt: real wrapper, works inside a worker, launches nothing.
: >"$T/reg.jsonl"
SUME_WORKER_SESSION=outer SUME_BG_LAUNCH_WRAPPER="$WRAP" \
  "$LAUNCH" --print-prompt --backend claude --name dry-job --prompt-file "$T/p.md" -- --model opus >"$T/k.txt" 2>"$T/k.err" \
  || fail "sume-bg-launch --print-prompt failed: $(cat "$T/k.err")"
grep -q '^\[sume worker session\] You are the WORKER for job "dry-job"' "$T/k.txt" || fail "dry run lacks preamble"
[[ $(count "$TAIL_MARK" "$T/k.txt") -eq 1 ]] || fail "dry run lacks the tail"
[[ ! -s "$T/reg.jsonl" ]] || fail "--print-prompt wrote a registry row (it launched)"
SUME_BG_LAUNCH_WRAPPER="$WRAP" "$LAUNCH" --print-prompt --backend claude --name dry-job --no-slack-report --prompt-file "$T/p.md" >"$T/l.txt" 2>/dev/null
[[ $(count 'slack-report' "$T/l.txt") -eq 0 ]] || fail "launcher --no-slack-report not passed"
CSTACK_SLACK_REPORT=0 SUME_BG_LAUNCH_WRAPPER="$WRAP" "$LAUNCH" --print-prompt --backend claude --name dry-job --prompt-file "$T/p.md" >"$T/m.txt" 2>/dev/null
[[ $(count 'slack-report' "$T/m.txt") -eq 0 ]] || fail "launcher CSTACK_SLACK_REPORT=0 not honored"
"$LAUNCH" --help | grep -q -- '--no-slack-report' || fail "--help lacks --no-slack-report"
pass "sume-bg-launch --print-prompt and opt-outs"

# 7) sume-bg-launch passes --no-slack-report to the wrapper before --prompt-file.
cat >"$T/fake-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGV"
EOF
chmod +x "$T/fake-wrapper.sh"
FAKE_ARGV="$T/w1.txt" SUME_BG_LAUNCH_WRAPPER="$T/fake-wrapper.sh" "$LAUNCH" --host local --backend grok --name w --no-slack-report --prompt-file "$T/p.md" >/dev/null 2>&1
grep -qx -- '--no-slack-report' "$T/w1.txt" || fail "wrapper argv lacks --no-slack-report"
FAKE_ARGV="$T/w2.txt" SUME_BG_LAUNCH_WRAPPER="$T/fake-wrapper.sh" "$LAUNCH" --host local --backend grok --name w --prompt-file "$T/p.md" >/dev/null 2>&1
! grep -qx -- '--no-slack-report' "$T/w2.txt" || fail "default launch must not opt out"
pass "launcher forwards the opt-out"

# 8) cstack-slack-post: refuses long / secret text, reports ego results.
python3 -c 'print("가" * 601)' >"$T/long.txt"
set +e
"$POST" --job demo-job --text-file "$T/long.txt" >"$T/n.out" 2>&1; rc=$?
set -e
[[ $rc -eq 2 ]] && grep -q '601 characters' "$T/n.out" || fail "601-char text not refused (rc=$rc)"
printf 'token xoxb-123456789012-abcdef\n' >"$T/secret.txt"
set +e
"$POST" --job demo-job --text-file "$T/secret.txt" >/dev/null 2>&1; rc=$?
set -e
[[ $rc -eq 2 ]] || fail "secret text not refused (rc=$rc)"
printf '*테스트* ok\n' >"$T/ok.txt"
cat >"$T/fake-ego" <<'EOF'
#!/usr/bin/env bash
cat >"$FAKE_EGO_SCRIPT"
echo "noise line"
echo "CSTACK_SLACK_RESULT ${FAKE_EGO_RESULT}"
EOF
chmod +x "$T/fake-ego"
out=$(CSTACK_SLACK_EGO="$T/fake-ego" FAKE_EGO_SCRIPT="$T/script.mjs" \
  FAKE_EGO_RESULT='{"ok":true,"created":false,"link":"https://example.slack.com/p1"}' \
  "$POST" --job demo-job --issue 42 --text-file "$T/ok.txt")
[[ "$out" == "SLACK: https://example.slack.com/p1" ]] || fail "success line: $out"
grep -qF '"job": "demo-job"' "$T/script.mjs" || fail "page script lacks the job"
grep -qF '"issue": "42"' "$T/script.mjs" || fail "page script lacks the issue"
grep -qF '테스트' "$T/script.mjs" || fail "page script lacks the Korean text"
set +e
out=$(CSTACK_SLACK_EGO="$T/fake-ego" FAKE_EGO_SCRIPT="$T/script2.mjs" \
  FAKE_EGO_RESULT='{"ok":false,"error":"Slack web client is signed in as bob, not chase"}' \
  "$POST" --job demo-job --text-file "$T/ok.txt"); rc=$?
set -e
[[ $rc -eq 1 && "$out" == "SLACK: not posted — Slack web client is signed in as bob, not chase" ]] || fail "failure line: $out (rc=$rc)"
pass "cstack-slack-post guards and result lines"

echo "slack-report tests: all ok"
