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
TAIL_MARK='<!-- slack-report:tail v3 -->'
STEER_MARK='[slack-report] New instruction'
SAME_MARK='[slack-report] Same ask, continued'

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export AGENT_HUMAN_STREAM_REGISTRY="$T/reg.jsonl" AGENT_HUMAN_STREAM_LIVE_DIR="$T/live"
export TOKENMAXXING_REQUIRE_SUPERVISOR=0

# Fake backends: dump the prompt (argv for grok, stdin for claude and codex).
for b in claude grok codex; do
  cat >"$T/$b" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
body = next((a for a in sys.argv[1:] if a.startswith("[sume worker session]")), "")
if not body and Path(sys.argv[0]).name != "grok":
    body = sys.stdin.read()
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
grep -qF '<!-- slack-report:steer v3 -->' "$TAIL" || fail "steer marker missing"
grep -qF '<!-- slack-report:same-thread v3 -->' "$TAIL" || fail "same-thread marker missing"
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
[[ $(count "$SAME_MARK" "$T/a.txt") -eq 0 ]] || fail "fresh launch must not get the same-thread line"
grep -qF 'new top-level message' "$T/a.txt" || fail "fresh tail must say new top-level message"
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
[[ $(count "$SAME_MARK" "$T/g.txt") -eq 0 ]] || fail "default resume must not get the same-thread line"
grep -qF 'new top-level message' "$T/g.txt" || fail "resume steer must say new top-level message"
! grep -qF -- '--same-thread' "$T/g.txt" || fail "default resume must not tell the worker to use --same-thread"
"$WRAP" --print-prompt --resume deadbeef --fork-session --name fork-job --prompt-file "$T/p.md" >"$T/h.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/h.txt") -eq 1 ]] || fail "fork must get the full tail"
[[ $(count "$STEER_MARK" "$T/h.txt") -eq 0 ]] || fail "fork must not get the steer line"
"$WRAP" --print-prompt --continue --name demo-job --prompt-file "$T/p.md" >"$T/i.txt" 2>/dev/null
[[ $(count "$STEER_MARK" "$T/i.txt") -eq 1 ]] || fail "--continue lacks the steer line"
CSTACK_SLACK_REPORT=0 "$WRAP" --print-prompt --resume deadbeef --name demo-job --prompt-file "$T/p.md" >"$T/j.txt" 2>/dev/null
[[ $(count 'slack-report' "$T/j.txt") -eq 0 ]] || fail "opt-out must also drop the steer line"
pass "resume steer / fork tail / continue steer"

# 4b) --same-thread (flag or prompt marker) on a resume = reply in the job's thread; a fork ignores it.
"$WRAP" --print-prompt --resume deadbeef --same-thread --name demo-job --prompt-file "$T/p.md" >"$T/st1.txt" 2>"$T/st1.err"
[[ $(count "$SAME_MARK on job \"demo-job\"" "$T/st1.txt") -eq 1 ]] || fail "--same-thread resume lacks the same-thread line"
[[ $(count "$STEER_MARK" "$T/st1.txt") -eq 0 ]] || fail "--same-thread resume must not get the new-thread steer line"
grep -qF -- 'cstack-slack-post --job demo-job --text-file <file> --same-thread' "$T/st1.txt" || fail "same-thread line must name --same-thread"
grep -q 'slack-report: same-thread steer appended' "$T/st1.err" || fail "same-thread stderr note missing"
printf 'Poke: keep going. <!-- slack-report:same-thread -->\n' >"$T/poke.md"
"$WRAP" --print-prompt --resume deadbeef --name demo-job --prompt-file "$T/poke.md" >"$T/st2.txt" 2>/dev/null
[[ $(count "$SAME_MARK" "$T/st2.txt") -eq 1 ]] || fail "prompt marker must pick the same-thread line"
"$WRAP" --print-prompt --resume deadbeef --fork-session --same-thread --name fork-job --prompt-file "$T/p.md" >"$T/st3.txt" 2>/dev/null
[[ $(count "$TAIL_MARK" "$T/st3.txt") -eq 1 && $(count "$SAME_MARK" "$T/st3.txt") -eq 0 ]] || fail "a fork is a new job: full tail, no same-thread line"
pass "--same-thread flag / marker on a resume; fork ignores it"

# 4c) a DM request never replaces the channel report: tail and both steer lines carry the rule,
#     and a prompt that asks for "DM only" still gets the tail.
for f in "$T/a.txt" "$T/g.txt" "$T/st1.txt"; do
  grep -qF 'still post' "$f" || fail "DM rule missing in $(basename "$f")"
done
grep -qF 'DM only' "$T/a.txt" || fail "tail must name the DM-only case"
grep -qF 'Amounts' "$T/a.txt" || fail "tail must allow amounts in the channel"
printf 'Send the refund total to Chase by DM only, not in the channel.\n' >"$T/dm.md"
"$WRAP" --print-prompt --name dm-job --prompt-file "$T/dm.md" >"$T/dm.txt" 2>"$T/dm.err"
[[ $(count "$TAIL_MARK" "$T/dm.txt") -eq 1 ]] || fail "a DM-only prompt must still get the tail"
grep -q 'slack-report: tail appended' "$T/dm.err" || fail "DM-only prompt turned the report off"
"$WRAP" --print-prompt --resume deadbeef --name dm-job --prompt-file "$T/dm.md" >"$T/dm2.txt" 2>/dev/null
[[ $(count "$STEER_MARK" "$T/dm2.txt") -eq 1 ]] || fail "a DM-only steer must still get the steer line"
pass "DM is extra delivery; the channel report stays"

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
grep -qF 'use ego-browser (Ego Lite) only; never launch or drive Chrome yourself' "$T/k.txt" || fail "worker preamble lacks the ego-browser-only rule"
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
FAKE_ARGV="$T/w3.txt" SUME_BG_LAUNCH_WRAPPER="$T/fake-wrapper.sh" "$LAUNCH" --host local --backend claude --name w --resume deadbeef-0000-4000-8000-000000000001 --same-thread --prompt-file "$T/p.md" >/dev/null 2>&1
grep -qx -- '--same-thread' "$T/w3.txt" || fail "wrapper argv lacks --same-thread"
! grep -qx -- '--same-thread' "$T/w2.txt" || fail "default launch must not pass --same-thread"
SUME_BG_LAUNCH_WRAPPER="$WRAP" "$LAUNCH" --print-prompt --backend claude --name dry-job --resume deadbeef --same-thread --prompt-file "$T/p.md" >"$T/n2.txt" 2>/dev/null
[[ $(count "$SAME_MARK" "$T/n2.txt") -eq 1 ]] || fail "launcher --print-prompt --same-thread lacks the same-thread line"
"$LAUNCH" --help | grep -q -- '--same-thread' || fail "--help lacks --same-thread"
pass "launcher forwards the opt-out and --same-thread"

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
grep -qF '"newThread": true' "$T/script.mjs" || fail "default post must be a new top-level message"
out=$(CSTACK_SLACK_EGO="$T/fake-ego" FAKE_EGO_SCRIPT="$T/script3.mjs" \
  FAKE_EGO_RESULT='{"ok":true,"created":true,"inParent":true,"link":"https://example.slack.com/p3"}' \
  "$POST" --job demo-job --title "데모" --text-file "$T/ok.txt" --new-thread)
[[ "$out" == *"SLACK: https://example.slack.com/p3"* ]] || fail "new-thread success line: $out"
grep -qF '"newThread": true' "$T/script3.mjs" || fail "--new-thread not passed to the page script"
grep -qF 'cfg.newThread' "$T/script3.mjs" || fail "page script has no new-thread branch"
out=$(CSTACK_SLACK_EGO="$T/fake-ego" FAKE_EGO_SCRIPT="$T/script4.mjs" \
  FAKE_EGO_RESULT='{"ok":true,"created":false,"link":"https://example.slack.com/p4"}' \
  "$POST" --job demo-job --text-file "$T/ok.txt" --same-thread)
[[ "$out" == "SLACK: https://example.slack.com/p4" ]] || fail "same-thread success line: $out"
grep -qF '"newThread": false' "$T/script4.mjs" || fail "--same-thread must reply in the job thread"
pass "cstack-slack-post guards and result lines"

echo "slack-report tests: all ok"
