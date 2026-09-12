#!/usr/bin/env bash
# Offline tests for sume-bg-launch host routing (cstack#10).
# No live Mini: `ssh` / `scp` are fakes that run sume-bg-remote against a
# temp HOME standing in for the Mini. No grok/claude/codex either — the
# wrapper is a fake that prints the same 📎 / —— final —— lines.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH="$ROOT/sume-bg-launch.sh"
REMOTE="$ROOT/sume-bg-remote.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LAPTOP="$T/laptop"
MINI="$T/mini"
mkdir -p "$LAPTOP/state" "$MINI/.local/bin" "$T/bin"
ln -sfn "$REMOTE" "$MINI/.local/bin/sume-bg-remote"

SID="deadbeef-0000-4000-8000-0000000cafe1"
SID_LOCAL="deadbeef-0000-4000-8000-0000000loc01"

# Fake backend wrapper (stands in for agent-human-stream on either host).
cat >"$T/bin/fake-wrapper.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"\${FAKE_WRAPPER_ARGV:-\$HOME/wrapper-argv.txt}"
echo "live_log: \$HOME/.cstack/state/opus-live/remote-live.log"
echo "📎 session_id=$SID  backend=grok  name=\$4"
echo "🔧 Bash git status"
if [[ -n "\${FAKE_WRAPPER_SLEEP:-}" ]]; then sleep "\$FAKE_WRAPPER_SLEEP"; fi
echo "📎 session_id=$SID  backend=grok"
echo "—— final ——"
echo "fake done"
EOF
chmod +x "$T/bin/fake-wrapper.sh"

# Fake ssh: `ssh -o … <host> -- <remote-bin> <quoted args…>` → run on "the Mini".
# Records every remote command line so tests can assert no prompt text leaked.
cat >"$T/bin/fake-ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) HOST=$1; shift ;;
  esac
done
CMDLINE="$*"
printf '%s\n' "$CMDLINE" >>"$FAKE_SSH_LOG"
cd "$MINI_HOME"
exec env -u AGENT_HUMAN_STREAM_REGISTRY -u AGENT_HUMAN_STREAM_LIVE_DIR \
  -u CSTACK_WORKER_HOST -u CSTACK_STATE -u CSTACK_MINI_SSH \
  HOME="$MINI_HOME" SUME_BG_REMOTE_LOGIN_PATH=0 bash -c "$CMDLINE"
EOF
chmod +x "$T/bin/fake-ssh"

cat >"$T/bin/fake-ssh-down" <<'EOF'
#!/usr/bin/env bash
echo "ssh: connect to host mini port 22: Operation timed out" >&2
exit 255
EOF
chmod +x "$T/bin/fake-ssh-down"

cat >"$T/bin/fake-scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) shift ;;
    -o) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
SRC=${ARGS[0]}
DST=${ARGS[1]#*:}
cp "$SRC" "$DST"
EOF
chmod +x "$T/bin/fake-scp"

export FAKE_SSH_LOG="$T/ssh.log"
export MINI_HOME="$MINI"
export SUME_BG_LAUNCH_WRAPPER="$T/bin/fake-wrapper.sh"
export AGENT_HUMAN_STREAM_REGISTRY="$LAPTOP/state/opus-sessions.jsonl"
export AGENT_HUMAN_STREAM_LIVE_DIR="$LAPTOP/state/opus-live"
export SUME_BG_SSH="$T/bin/fake-ssh"
export SUME_BG_SCP="$T/bin/fake-scp"
export CSTACK_MINI_SSH="chase@mini.tailnet.ts.net"
export CSTACK_MINI_CWD="$MINI"
unset CSTACK_WORKER_HOST

PROMPT="$T/prompt.md"
cat >"$PROMPT" <<'EOF'
# Fable : worker-host-mini (#10)
Work in English. SENTINEL_PROMPT_BODY_7f3a must never appear on an ssh command line.
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# 1) --host local regression: fake wrapper receives the same argv as before.
FAKE_WRAPPER_ARGV="$T/local-argv.txt" \
  "$LAUNCH" --host local --backend grok --name local-job --prompt-file "$PROMPT" -- --effort high >"$T/local-out.txt" 2>"$T/local-err.txt"
grep -qx -- '--prompt-file' "$T/local-argv.txt" || fail "local argv missing --prompt-file"
grep -qx -- "$PROMPT" "$T/local-argv.txt" || fail "local argv missing prompt path"
grep -qx -- 'local-job' "$T/local-argv.txt" || fail "local argv missing --name value"
grep -qx -- 'high' "$T/local-argv.txt" || fail "local argv missing extra --effort high"
grep -q '📎 session_id=' "$T/local-out.txt" || fail "local run printed no session_id"
[[ ! -f "$FAKE_SSH_LOG" ]] || fail "--host local must not touch ssh"
pass "--host local regression"

# 2) default host = local when CSTACK_WORKER_HOST is unset; env picks mini.
set +e
CSTACK_WORKER_HOST=mini CSTACK_MINI_SSH= "$LAUNCH" --backend grok --name x --prompt-file "$PROMPT" >/dev/null 2>"$T/err2.txt"
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "CSTACK_WORKER_HOST=mini without CSTACK_MINI_SSH should exit 2 (got $rc)"
grep -q 'CSTACK_MINI_SSH' "$T/err2.txt" || fail "missing CSTACK_MINI_SSH hint"
set +e
"$LAUNCH" --host bogus --backend grok --name x --prompt-file "$PROMPT" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "--host bogus should exit 2 (got $rc)"
pass "host env / validation"

# 3) fail closed: Mini unreachable → no local run, exit 3.
set +e
SUME_BG_SSH="$T/bin/fake-ssh-down" FAKE_WRAPPER_ARGV="$T/should-not-exist.txt" \
  "$LAUNCH" --host mini --backend grok --name down-job --prompt-file "$PROMPT" >/dev/null 2>"$T/err3.txt"
rc=$?
set -e
[[ $rc -eq 3 ]] || fail "unreachable Mini should exit 3 (got $rc): $(cat "$T/err3.txt")"
grep -q 'refusing to run locally' "$T/err3.txt" || fail "fail-closed message missing"
[[ ! -f "$T/should-not-exist.txt" ]] || fail "unreachable Mini must not fall back to a local run"
pass "fail closed when Mini unreachable"

# 4) secret guard on the prompt file.
printf 'issue https://github.com/chasehuh/cstack/issues/10\ntoken ghp_%s\n' "$(printf 'a%.0s' $(seq 1 30))" >"$T/leaky.md"
set +e
"$LAUNCH" --host mini --backend grok --name leaky --prompt-file "$T/leaky.md" >/dev/null 2>"$T/err4.txt"
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "credential in prompt should exit 2 (got $rc)"
grep -q 'credential' "$T/err4.txt" || fail "secret guard message missing"
pass "prompt secret guard"

# 5) --host mini end to end: scp prompt, detached start, attach → local replica.
FAKE_WRAPPER_ARGV="$MINI/remote-argv.txt" \
  "$LAUNCH" --host mini --backend grok --name mini-job --prompt-file "$PROMPT" -- --effort high >"$T/mini-out.txt" 2>"$T/mini-err.txt"
JOB=$(sed -n 's/.*job: \([^ ]*\).*/\1/p' "$T/mini-err.txt" | head -n 1)
[[ -n "$JOB" ]] || fail "no job id in launcher stderr: $(cat "$T/mini-err.txt")"
REPLICA="$AGENT_HUMAN_STREAM_LIVE_DIR/$JOB.log"
[[ -f "$REPLICA" ]] || fail "replica live log missing: $REPLICA"
grep -q "📎 session_id=$SID" "$REPLICA" || fail "replica lacks session_id"
grep -q '—— final ——' "$REPLICA" || fail "replica lacks final block"
grep -q 'fake done' "$REPLICA" || fail "replica lacks final text"
[[ "$(readlink "$AGENT_HUMAN_STREAM_LIVE_DIR/LATEST.log")" == "$REPLICA" ]] || fail "LATEST.log not pointing at replica"
grep -q "📎 session_id=$SID" "$T/mini-out.txt" || fail "attach stdout lacks session_id (Cursor smoke would fail)"
# Mini side: prompt staged by scp, wrapper ran there with the remote path, exit code recorded.
cmp -s "$PROMPT" "$MINI/.cstack/state/remote-jobs/$JOB/prompt.md" || fail "prompt not staged on Mini via scp"
grep -qx -- "$MINI/.cstack/state/remote-jobs/$JOB/prompt.md" "$MINI/remote-argv.txt" || fail "Mini wrapper did not get the remote prompt path"
grep -qx -- 'high' "$MINI/remote-argv.txt" || fail "extra backend flags did not reach the Mini wrapper"
grep -qx -- 'mini-job' "$MINI/remote-argv.txt" || fail "--name did not reach the Mini wrapper"
[[ "$(cat "$MINI/.cstack/state/remote-jobs/$JOB/exit_code")" == "0" ]] || fail "Mini exit_code not 0"
# Prompt body never on the ssh command line.
! grep -q 'SENTINEL_PROMPT_BODY_7f3a' "$FAKE_SSH_LOG" || fail "prompt text leaked into ssh argv"
grep -q '^\.local/bin/sume-bg-remote prep ' "$FAKE_SSH_LOG" || fail "prep not sent over ssh"
grep -q '^\.local/bin/sume-bg-remote start ' "$FAKE_SSH_LOG" || fail "start not sent over ssh"
grep -q '^\.local/bin/sume-bg-remote attach ' "$FAKE_SSH_LOG" || fail "attach not sent over ssh"
# Replica registry: host=mini rows for start / session / end.
python3 - "$AGENT_HUMAN_STREAM_REGISTRY" "$JOB" "$SID" "$REPLICA" <<'PY' || fail "replica registry rows wrong"
import json, sys
path, job, sid, replica = sys.argv[1:5]
rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
rows = [r for r in rows if r.get("job") == job]
events = [r["event"] for r in rows]
assert events == ["start", "session", "end"], events
assert all(r["host"] == "mini" for r in rows), rows
assert rows[1]["session_id"] == sid and rows[2]["session_id"] == sid, rows
assert rows[2]["exit_code"] == 0, rows[2]
assert all(r["live_log"] == replica for r in rows), rows
assert rows[0]["remote_pid"], rows[0]
assert rows[1]["remote_live_log"], rows[1]
assert rows[0]["remote_host"] == "chase@mini.tailnet.ts.net", rows[0]
PY
pass "--host mini launch → replica log + registry"

# 6) --resume is same-host only.
set +e
"$LAUNCH" --host local --backend grok --name mini-job --resume "$SID" --prompt-file "$PROMPT" >/dev/null 2>"$T/err6.txt"
rc=$?
set -e
[[ $rc -eq 4 ]] || fail "local resume of a Mini session should exit 4 (got $rc)"
grep -q "lives on host mini" "$T/err6.txt" || fail "resume error must print the host: $(cat "$T/err6.txt")"
printf '{"event":"session","backend":"grok","session_id":"%s","cwd":"/tmp/x","name":"loc"}\n' "$SID_LOCAL" >>"$AGENT_HUMAN_STREAM_REGISTRY"
set +e
"$LAUNCH" --host mini --backend grok --name loc --resume "$SID_LOCAL" --prompt-file "$PROMPT" >/dev/null 2>"$T/err6b.txt"
rc=$?
set -e
[[ $rc -eq 4 ]] || fail "Mini resume of a local session should exit 4 (got $rc)"
grep -q "lives on host local" "$T/err6b.txt" || fail "resume error must print host local"
# Same-host Mini resume works and reuses the recorded remote cwd.
FAKE_WRAPPER_ARGV="$MINI/remote-argv-resume.txt" \
  "$LAUNCH" --host mini --backend grok --name mini-job --resume "$SID" --prompt-file "$PROMPT" >"$T/mini-out2.txt" 2>"$T/mini-err2.txt"
grep -qx -- "$SID" "$MINI/remote-argv-resume.txt" || fail "Mini wrapper did not get --resume uuid"
JOB2=$(sed -n 's/.*job: \([^ ]*\).*/\1/p' "$T/mini-err2.txt" | head -n 1)
[[ "$JOB2" == *"-resume-deadbeef" ]] || fail "resume job id should carry -resume-<uuid8>: $JOB2"
grep -q "CWD=$MINI" "$MINI/.cstack/state/remote-jobs/$JOB2/job.env" || fail "resume did not reuse recorded cwd"
pass "--resume same-host routing"

# 7) detach: the Mini job survives the laptop attach dying; status/attach/kill control plane.
FAKE_WRAPPER_ARGV="$MINI/remote-argv-long.txt" FAKE_WRAPPER_SLEEP=6 \
  "$LAUNCH" --host mini --backend grok --name long-job --prompt-file "$PROMPT" >"$T/long-out.txt" 2>"$T/long-err.txt" &
LPID=$!
for _ in $(seq 1 50); do
  JOB3=$(sed -n 's/.*job: \([^ ]*\).*/\1/p' "$T/long-err.txt" 2>/dev/null | head -n 1)
  [[ -n "$JOB3" && -f "$MINI/.cstack/state/remote-jobs/$JOB3/pid" ]] && break
  sleep 0.2
done
[[ -n "${JOB3:-}" ]] || fail "long job never started"
sleep 0.5
kill -TERM "$LPID" 2>/dev/null || true
pkill -TERM -f "sume-bg-remote attach --job $JOB3" 2>/dev/null || true
wait "$LPID" 2>/dev/null || true
STATUS=$("$LAUNCH" --host mini --status "$JOB3")
[[ "$STATUS" == *"alive=yes"* ]] || fail "job should survive laptop attach death: $STATUS"
"$LAUNCH" --host mini --jobs | grep -q "job=$JOB3 alive=yes" || fail "--jobs missing live job"
# Re-attach streams to completion and rewrites the replica.
"$LAUNCH" --host mini --attach "$JOB3" >"$T/reattach-out.txt" 2>"$T/reattach-err.txt"
grep -q '—— final ——' "$AGENT_HUMAN_STREAM_LIVE_DIR/$JOB3.log" || fail "re-attached replica lacks final"
grep -q "📎 session_id=$SID" "$T/reattach-out.txt" || fail "re-attach stdout lacks session_id"
STATUS=$("$LAUNCH" --host mini --status "$JOB3")
[[ "$STATUS" == *"alive=no"* && "$STATUS" == *"exit_code=0"* ]] || fail "job should be finished: $STATUS"
pass "detached job survives attach loss; --status/--jobs/--attach"

# 8) --kill stops a running Mini job (process group), status flips to alive=no.
FAKE_WRAPPER_ARGV="$MINI/remote-argv-kill.txt" FAKE_WRAPPER_SLEEP=30 \
  "$LAUNCH" --host mini --backend grok --name kill-job --prompt-file "$PROMPT" >"$T/kill-out.txt" 2>"$T/kill-err.txt" &
LPID=$!
for _ in $(seq 1 50); do
  JOB4=$(sed -n 's/.*job: \([^ ]*\).*/\1/p' "$T/kill-err.txt" 2>/dev/null | head -n 1)
  [[ -n "$JOB4" && -f "$MINI/.cstack/state/remote-jobs/$JOB4/pid" ]] && break
  sleep 0.2
done
[[ -n "${JOB4:-}" ]] || fail "kill job never started"
sleep 0.5
OUT=$("$LAUNCH" --host mini --kill "$JOB4")
[[ "$OUT" == *"killed job $JOB4"* ]] || fail "kill output: $OUT"
wait "$LPID" 2>/dev/null || true
STATUS=$("$LAUNCH" --host mini --status "$JOB4")
[[ "$STATUS" == *"alive=no"* ]] || fail "killed job still alive: $STATUS"
! pgrep -f "FAKE_WRAPPER_SLEEP.*$JOB4" >/dev/null 2>&1 || fail "wrapper process leaked after kill"
pass "--kill"

# 9) control-plane actions require --host mini.
set +e
"$LAUNCH" --status whatever >/dev/null 2>"$T/err9.txt"
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "--status without --host mini should exit 2"
pass "control plane needs --host mini"

echo "sume-bg-launch host tests: all ok"
