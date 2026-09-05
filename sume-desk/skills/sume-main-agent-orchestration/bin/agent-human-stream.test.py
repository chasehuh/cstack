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
