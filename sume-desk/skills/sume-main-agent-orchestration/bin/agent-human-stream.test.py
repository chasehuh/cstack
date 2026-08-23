#!/usr/bin/env python3
"""Offline fixtures for agent-human-stream.py (Claude + Grok NDJSON)."""
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


def main() -> None:
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

    print("agent-human-stream self-test: ok (claude + grok messages + grok acp)")


if __name__ == "__main__":
    main()
