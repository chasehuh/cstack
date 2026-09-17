#!/usr/bin/env python3
"""Offline fixtures for agent-human-stream.py (Claude + Grok + Codex NDJSON)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FMT = ROOT / "agent-human-stream.py"

CLAUDE_STREAM = [
    {
        "type": "system",
        "subtype": "init",
        "session_id": "11111111-1111-1111-1111-111111111111",
        "model": "opus",
        "cwd": "/tmp/demo",
    },
    {
        "type": "assistant",
        "session_id": "11111111-1111-1111-1111-111111111111",
        "message": {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Checking the repo."},
                {
                    "type": "tool_use",
                    "name": "Bash",
                    "input": {"command": "git status"},
                },
            ],
        },
    },
    {
        "type": "user",
        "session_id": "11111111-1111-1111-1111-111111111111",
        "message": {
            "role": "user",
            "content": [{"type": "tool_result", "content": "clean"}],
        },
    },
    {
        "type": "result",
        "session_id": "11111111-1111-1111-1111-111111111111",
        "result": "Claude done.",
    },
]

GROK_MESSAGES = [
    {
        "type": "system",
        "subtype": "init",
        "session_id": "22222222-2222-2222-2222-222222222222",
        "model": "grok-4.6",
        "cwd": "/tmp/demo",
    },
    {
        "type": "assistant",
        "session_id": "22222222-2222-2222-2222-222222222222",
        "message": {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Reading the file."},
                {
                    "type": "tool_use",
                    "name": "read_file",
                    "input": {"path": "src/main.rs"},
                },
            ],
        },
    },
    {
        "type": "result",
        "session_id": "22222222-2222-2222-2222-222222222222",
        "result": "Grok messages done.",
    },
]

GROK_ACP = [
    {"type": "thought", "data": "Looking around."},
    {
        "type": "tool_call",
        "toolCallId": "call_1",
        "toolName": "run_terminal_cmd",
        "status": "in_progress",
        "rawInput": {"command": "ls"},
        "sessionId": "33333333-3333-3333-3333-333333333333",
    },
    {
        "type": "tool_call_update",
        "toolCallId": "call_1",
        "status": "completed",
        "rawOutput": {"lines": 3},
    },
    {"type": "text", "data": "Here is the listing."},
    {
        "type": "end",
        "sessionId": "33333333-3333-3333-3333-333333333333",
        "result": "ACP done.",
        "stopReason": "end_turn",
    },
]

# Shapes from a live `codex exec --json` probe (codex-cli 0.135): thread.started
# carries thread_id (the resume id); items arrive as item.started/completed.
CODEX_STREAM = [
    {"type": "thread.started", "thread_id": "44444444-4444-7444-8444-444444444444"},
    {"type": "turn.started"},
    {
        "type": "item.completed",
        "item": {"id": "item_0", "type": "reasoning", "text": "Need to look at the tree first."},
    },
    {
        "type": "item.started",
        "item": {
            "id": "item_1",
            "type": "command_execution",
            "command": "/bin/zsh -lc 'git status --short'",
            "status": "in_progress",
        },
    },
    {
        "type": "item.completed",
        "item": {
            "id": "item_1",
            "type": "command_execution",
            "command": "/bin/zsh -lc 'git status --short'",
            "aggregated_output": " M README.md\n",
            "exit_status": 0,
            "status": "completed",
        },
    },
    {
        "type": "item.completed",
        "item": {
            "id": "item_2",
            "type": "file_change",
            "changes": [{"path": "README.md", "kind": "update"}],
            "status": "completed",
        },
    },
    {
        "type": "item.completed",
        "item": {"id": "item_3", "type": "agent_message", "text": "Codex done."},
    },
    {
        "type": "turn.completed",
        "usage": {"input_tokens": 20216, "cached_input_tokens": 10624, "output_tokens": 17},
    },
]

CODEX_FAILED = [
    {"type": "thread.started", "thread_id": "55555555-5555-7555-8555-555555555555"},
    {"type": "turn.started"},
    {"type": "turn.failed", "error": {"message": "usage limit reached"}},
]


def run_stream(events: list[dict], backend: str) -> str:
    payload = "".join(json.dumps(ev) + "\n" for ev in events)
    env = os.environ.copy()
    env["AGENT_HUMAN_STREAM_BACKEND"] = backend
    env["AGENT_HUMAN_STREAM_NAME"] = "self-test"
    env.pop("AGENT_HUMAN_STREAM_LIVE_LOG", None)
    env.pop("CLAUDE_HUMAN_STREAM_LIVE_LOG", None)
    env.pop("AGENT_HUMAN_STREAM_REGISTRY", None)
    env.pop("CLAUDE_HUMAN_STREAM_REGISTRY", None)
    with tempfile.TemporaryDirectory() as tmp:
        env["AGENT_HUMAN_STREAM_LIVE_LOG"] = str(Path(tmp) / "live.log")
        proc = subprocess.run(
            [sys.executable, "-u", str(FMT)],
            input=payload,
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
    if proc.returncode != 0:
        raise SystemExit(f"formatter failed ({backend}): {proc.stderr}")
    return proc.stdout


def require(haystack: str, needle: str) -> None:
    if needle not in haystack:
        raise SystemExit(f"missing {needle!r} in:\n{haystack}")


def test_fork_launchers() -> None:
    parent = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    child = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("AGENT_", "CLAUDE_", "GROK_", "SUME_")):
                env.pop(key)
        env.update(PATH=f"{tmp}:{env['PATH']}", TOKENMAXXING_REQUIRE_SUPERVISOR="0",
                   AGENT_HUMAN_STREAM_REGISTRY=str(base / "registry.jsonl"),
                   AGENT_HUMAN_STREAM_LIVE_DIR=str(base / "live"),
                   ARGV_FILE=str(base / "argv.json"))
        stub = f"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['ARGV_FILE']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('FAIL_FORK'):
    sys.stderr.write('error: --fork-session unavailable\\n')
    sys.exit(2)
if Path(sys.argv[0]).name == 'codex':
    print(json.dumps({{'type': 'thread.started', 'thread_id': '{child}'}}))
else:
    print(json.dumps({{'type': 'system', 'subtype': 'init', 'session_id': '{child}'}}))
"""
        for backend in ("codex", "claude", "grok"):
            binary = base / backend
            binary.write_text(stub)
            binary.chmod(0o755)
        prompt = base / "prompt.md"
        prompt.write_text("Fork fixture prompt")
        wrapper = str(ROOT / "agent-human-stream.sh")
        for backend in ("codex", "claude", "grok"):
            args = [wrapper, "--backend", backend, "--resume", parent,
                    "--name", "fork-test", "--prompt-file", str(prompt),
                    "--effort", "low", "--fork-session"]
            proc = subprocess.run(args, env=env, text=True, capture_output=True)
            assert proc.returncode == 0, proc.stderr
            argv = json.loads((base / "argv.json").read_text())
            assert parent in argv, argv
            # The wrapper prepends the worker preamble (sume#7839); the task text stays last.
            assert any(a.startswith("[sume worker session]") and a.endswith("\n\nFork fixture prompt")
                       for a in argv), argv
            if backend == "codex":
                assert argv[:2] == ["exec", "fork"], argv
                assert "resume" not in argv and "--resume" not in argv, argv
                assert "--json" in argv and "--skip-git-repo-check" in argv, argv
                assert 'model_reasoning_effort="low"' in argv, argv
            else:
                assert "--fork-session" in argv and "--resume" in argv, argv
            require(proc.stdout, f"session_id={child}")
            records = [json.loads(line) for line in (base / "registry.jsonl").read_text().splitlines()]
            assert any(r.get("session_id") == child and r.get("resume_from") == parent
                       and r.get("backend") == backend for r in records), records
            assert all(r.get("session_id") != parent for r in records), records
            require(proc.stderr, "fork-aaaaaaaa")
            invalid = subprocess.run([wrapper, "--backend", backend, "--fork-session", "prompt"],
                                     env=env, text=True, capture_output=True)
            assert invalid.returncode == 2, invalid.stderr
            require(invalid.stderr, "requires --resume")
        failed = subprocess.run(args, env={**env, "FAIL_FORK": "1"}, text=True, capture_output=True)
        assert failed.returncode == 2, failed.stderr
        require(failed.stderr, "--fork-session unavailable")
        invalid = subprocess.run([wrapper, "--backend", "codex", "--continue", "--fork-session", "prompt"],
                                 env=env, text=True, capture_output=True)
        assert invalid.returncode == 2, invalid.stderr
        require(invalid.stderr, "requires --resume")

        # A matching live parent must survive fork, but still be stopped by steer.
        parent_proc = subprocess.Popen(["sleep", "60"])
        try:
            pgrep = base / "pgrep"
            pgrep.write_text(f"#!/bin/sh\necho '{parent_proc.pid} agent-human-stream --resume {parent}'\n")
            pgrep.chmod(0o755)
            env["SUME_BG_LAUNCH_WRAPPER"] = str(base / "codex")
            launch = [str(ROOT / "sume-bg-launch.sh"), "--backend", "codex", "--name", "child",
                      "--resume", parent, "--prompt-file", str(prompt)]
            for flags in (["--fork-session"], ["--", "--fork-session"]):
                fork = subprocess.run(launch + flags, env=env, capture_output=True, text=True)
                assert fork.returncode == 0, fork.stderr
                assert parent_proc.poll() is None, "fork killed parent"
                assert "--fork-session" in json.loads((base / "argv.json").read_text())
            steer = subprocess.run(launch, env=env, capture_output=True, text=True)
            assert steer.returncode == 0, steer.stderr
            assert parent_proc.wait(timeout=2) != 0, "steer did not stop parent"
        finally:
            if parent_proc.poll() is None:
                parent_proc.terminate()
                parent_proc.wait()


def test_codex_file_drain() -> None:
    """A fat writer must see a regular stdout file, preserve rc, and drain EOF."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        stub = base / "codex"
        stub.write_text(r'''#!/usr/bin/env python3
import json, os, stat, sys, time
assert stat.S_ISREG(os.fstat(1).st_mode), "Codex stdout is still a pipe"
assert sys.stdin.read() == "", "Codex stdin must be closed"
# Split a JSON event and a UTF-8 character across separate writes.
payload = json.dumps({"type": "item.completed", "item": {
    "type": "agent_message", "text": "Partial café."}}, ensure_ascii=False).encode()
cut = payload.index("é".encode()) + 1
os.write(1, payload[:cut])
time.sleep(0.15)
os.write(1, payload[cut:] + b"\n")
# Put the resume id after the fat output to exercise scraping discarded chunks.
os.write(1, b'{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"')
for _ in range(24):
    os.write(1, b"x" * (256 * 1024))
os.write(1, b'"},"thread_id":"66666666-6666-7666-8666-666666666666"}\n')
# Final event deliberately has no trailing newline and follows the skipped line.
os.write(1, json.dumps({"type": "item.completed", "item": {
    "type": "agent_message", "text": "Drain done."}}).encode())
sys.exit(int(os.environ["STUB_RC"]))
''')
        stub.chmod(0o755)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("AGENT_", "CLAUDE_", "GROK_", "SUME_")):
                env.pop(key)
        env.update(PATH=f"{tmp}:{env['PATH']}", TOKENMAXXING_REQUIRE_SUPERVISOR="0",
                   AGENT_HUMAN_STREAM_REGISTRY=str(base / "registry.jsonl"),
                   AGENT_HUMAN_STREAM_LIVE_DIR=str(base / "live"))
        for rc in (0, 101):
            env["STUB_RC"] = str(rc)
            proc = subprocess.run(
                ["bash", str(ROOT / "agent-human-stream.sh"), "--backend", "codex",
                 "--name", f"drain-{rc}", "fixture", "--effort", "mid"],
                env=env, capture_output=True, text=True, timeout=15)
            assert proc.returncode == rc, (proc.returncode, proc.stderr)
            require(proc.stdout, "Partial café.")
            require(proc.stdout, "session parse only")
            require(proc.stdout, "session_id=66666666-6666-7666-8666-666666666666")
            require(proc.stdout, "—— final ——\nDrain done.")
            assert len(proc.stdout) < 5000, "fat output leaked into human log"
        assert len(list((base / "live").glob("*.codex.jsonl"))) == 2


def test_worker_preamble_and_nested_guard() -> None:
    """Every launch gets the worker preamble; a launch from inside a worker exits 5 (sume#7839)."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("AGENT_", "CLAUDE_", "GROK_", "SUME_")):
                env.pop(key)
        env.update(PATH=f"{tmp}:{env['PATH']}", TOKENMAXXING_REQUIRE_SUPERVISOR="0",
                   AGENT_HUMAN_STREAM_REGISTRY=str(base / "registry.jsonl"),
                   AGENT_HUMAN_STREAM_LIVE_DIR=str(base / "live"),
                   ARGV_FILE=str(base / "argv.json"))
        stub = base / "codex"
        stub.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['ARGV_FILE']).write_text(json.dumps(sys.argv[1:]))
Path(os.environ['ENV_FILE']).write_text(json.dumps({k: v for k, v in os.environ.items() if k.startswith(('SUME_', 'AGENT_HUMAN_STREAM_PID'))}))
print(json.dumps({'type': 'thread.started', 'thread_id': 'cccccccc-cccc-7ccc-8ccc-cccccccccccc'}))
""")
        stub.chmod(0o755)
        env["ENV_FILE"] = str(base / "env.json")
        wrapper = str(ROOT / "agent-human-stream.sh")
        prompt = base / "prompt.md"
        prompt.write_text("# Astra : preamble-test (#7839)\nWork in English. `--host mini`. Fresh worker.")
        args = [wrapper, "--backend", "codex", "--name", "preamble-test", "--prompt-file", str(prompt), "--effort", "low"]

        proc = subprocess.run(args, env=env, text=True, capture_output=True)
        assert proc.returncode == 0, proc.stderr
        argv = json.loads((base / "argv.json").read_text())
        body = argv[-1]
        assert body.startswith('[sume worker session] You are the WORKER for job "preamble-test"'), body
        assert "Never run sume-bg-launch" in body, body
        assert body.endswith("\n\n" + prompt.read_text()), body
        seen = json.loads((base / "env.json").read_text())
        assert seen.get("SUME_WORKER_SESSION") == "preamble-test", seen
        assert seen.get("AGENT_HUMAN_STREAM_PID"), seen
        rows = [json.loads(l) for l in (base / "registry.jsonl").read_text().splitlines() if l.strip()]
        assert rows and rows[0]["prompt_head"].startswith("# Astra : preamble-test (#7839)"), rows[0]

        # Opt-out keeps the prompt byte-identical.
        proc = subprocess.run(args, env={**env, "AGENT_HUMAN_STREAM_WORKER_PREAMBLE": "0"},
                              text=True, capture_output=True)
        assert proc.returncode == 0, proc.stderr
        assert json.loads((base / "argv.json").read_text())[-1] == prompt.read_text()

        # Inside a worker session (marker inherited by its tool shells) the launch is refused.
        (base / "argv.json").unlink()
        for marker in ({"SUME_WORKER_SESSION": "outer-job"}, {"AGENT_HUMAN_STREAM_PID": "4242"}):
            proc = subprocess.run(args, env={**env, **marker}, text=True, capture_output=True)
            assert proc.returncode == 5, (proc.returncode, proc.stderr)
            assert "refusing a nested worker launch" in proc.stderr, proc.stderr
            assert not (base / "argv.json").exists(), "nested launch must not start the backend"
        proc = subprocess.run(args, env={**env, "SUME_WORKER_SESSION": "outer-job",
                                         "SUME_BG_REMOTE_JOB": "20260101T000000Z-outer"},
                              text=True, capture_output=True)
        assert proc.returncode == 5 and "Mini job 20260101T000000Z-outer" in proc.stderr, proc.stderr
        # --sessions is a read; the override launches on purpose.
        proc = subprocess.run([wrapper, "--sessions"], env={**env, "SUME_WORKER_SESSION": "outer-job"},
                              text=True, capture_output=True)
        assert proc.returncode == 0, proc.stderr
        proc = subprocess.run(args, env={**env, "SUME_WORKER_SESSION": "outer-job", "SUME_BG_ALLOW_NESTED": "1"},
                              text=True, capture_output=True)
        assert proc.returncode == 0 and "nested launch allowed" in proc.stderr, proc.stderr
        assert (base / "argv.json").exists()


def main() -> None:
    test_codex_file_drain()
    test_fork_launchers()
    test_worker_preamble_and_nested_guard()
    claude = run_stream(CLAUDE_STREAM, "claude")
    require(claude, "📎 session_id=11111111-1111-1111-1111-111111111111")
    require(claude, "backend=claude")
    require(claude, "🤖 Checking the repo.")
    require(claude, "$ git status")
    require(claude, "📎 tool → clean")
    require(claude, "—— final ——")
    require(claude, "Claude done.")
    require(claude, "claude-human-stream --resume")

    grok_msg = run_stream(GROK_MESSAGES, "grok")
    require(grok_msg, "📎 session_id=22222222-2222-2222-2222-222222222222")
    require(grok_msg, "backend=grok")
    require(grok_msg, "read_file src/main.rs")
    require(grok_msg, "Grok messages done.")
    require(grok_msg, "agent-human-stream --backend grok --resume")

    grok_acp = run_stream(GROK_ACP, "grok")
    require(grok_acp, "📎 session_id=33333333-3333-3333-3333-333333333333")
    require(grok_acp, "(thinking) Looking around.")
    require(grok_acp, "$ ls")
    require(grok_acp, "📎 tool → {'lines': 3}")
    require(grok_acp, "ACP done.")

    codex = run_stream(CODEX_STREAM, "codex")
    require(codex, "📎 session_id=44444444-4444-7444-8444-444444444444")
    require(codex, "backend=codex")
    require(codex, "(thinking) Need to look at the tree first.")
    require(codex, "🔧 $ /bin/zsh -lc 'git status --short'")
    require(codex, "📎 tool →  M README.md")
    require(codex, "🔧 update README.md")
    require(codex, "🤖 Codex done.")
    require(codex, "usage: in=20216 cached=10624 out=17")
    require(codex, "—— final ——\nCodex done.")
    require(codex, "agent-human-stream --backend codex --resume 44444444-4444-7444-8444-444444444444")
    if "claude-human-stream --resume" in codex:
        raise SystemExit(f"codex output must not print the claude alias hint:\n{codex}")

    codex_failed = run_stream(CODEX_FAILED, "codex")
    require(codex_failed, "❌ usage limit reached")
    require(codex_failed, "—— final ——\nusage limit reached")

    # Claude + Grok must not change: no codex-only lines leak into them.
    for out in (claude, grok_msg, grok_acp):
        if "usage: in=" in out:
            raise SystemExit(f"codex-only line leaked into claude/grok output:\n{out}")

    print("agent-human-stream self-test: ok (claude + grok messages + grok acp + codex)")


if __name__ == "__main__":
    main()
