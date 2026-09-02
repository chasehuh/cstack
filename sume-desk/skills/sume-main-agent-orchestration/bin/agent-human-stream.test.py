#!/usr/bin/env python3
"""Offline fixtures for agent-human-stream.py (Claude + Grok NDJSON).

Grok shapes are captured from Grok Build 1.0.11 on 2026-09-02 (sumelabs/sume#5706):
tool results arrive as ``{"type":"Bash","output":[byte,…]}`` blobs, thinking
blocks are present, ``result`` carries usage/cost, and native ACP
``streaming-json`` streams per-token ``thought`` / ``text`` deltas with the
session id only on ``end``.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FMT = ROOT / "agent-human-stream.py"

SID1 = "11111111-1111-1111-1111-111111111111"
SID2 = "01a05e1f-90bb-7561-b9a9-8f5e4f9558c6"
SID3 = "01a05f54-7a11-7eb0-8052-70abb0c35704"

CLAUDE_STREAM = [
    {"type": "system", "subtype": "init", "session_id": SID1, "model": "opus", "cwd": "/tmp/demo"},
    {
        "type": "assistant",
        "session_id": SID1,
        "message": {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Checking the repo."},
                {"type": "tool_use", "name": "Bash", "input": {"command": "git status"}},
            ],
        },
    },
    {
        "type": "user",
        "session_id": SID1,
        "message": {"role": "user", "content": [{"type": "tool_result", "content": "clean"}]},
    },
    {"type": "result", "session_id": SID1, "result": "Claude done."},
]

BASH_BYTES = list(b"=== remote ===\norigin\tgit@github.com:sumelabs/sume-com.git (fetch)\n")

GROK_MESSAGES = [
    {
        "type": "system",
        "subtype": "init",
        "session_id": SID2,
        "apiKeySource": "oauth",
        "model": "grok-4.6",
        "cwd": "/Users/x/sume/sume-com",
        "permissionMode": "bypassPermissions",
        "tools": ["run_terminal_command", "read_file", "grep", "monitor"],
        "mcp_servers": [{"name": "railway", "status": "connected"}, {"name": "linear", "status": "failed"}],
    },
    {
        "type": "assistant",
        "session_id": SID2,
        "message": {
            "role": "assistant",
            "model": "grok-4.6",
            "content": [
                {
                    "type": "thinking",
                    "thinking": "I'm the Grok land babysitter for PR #5697 / issue #5696. I need to check origin/main first, then the MQ label, then draft CI, and only then decide whether to re-label.",
                    "signature": "x",
                },
                {"type": "text", "text": "Checking main first."},
                {"type": "tool_use", "name": "run_terminal_command", "input": {"command": "git remote -v | head -4"}},
                {"type": "tool_use", "name": "read_file", "input": {"target_file": "/Users/x/.agents/skills/sume-gt-mq/SKILL.md", "limit": 150}},
                {"type": "tool_use", "name": "grep", "input": {"pattern": "avatar-videos.idempotency", "glob": "**/*.ts"}},
                {"type": "tool_use", "name": "monitor", "input": {"command": "while true; do gh pr view 5697; sleep 60; done"}},
            ],
        },
    },
    {
        "type": "user",
        "session_id": SID2,
        "message": {
            "role": "user",
            "content": [
                {"type": "tool_result", "content": json.dumps({"type": "Bash", "output": BASH_BYTES, "exit_code": 0})},
                {"type": "tool_result", "content": json.dumps({"type": "ReadFile", "FileContent": {"content": "1→---\nname: sume-gt-mq\n"}})},
                {"type": "tool_result", "content": json.dumps({"type": "GrepSearch", "stdout": list(b"apps/api/vitest.config.ts:3\n")})},
                {"type": "tool_result", "content": json.dumps({"type": "Monitor", "taskId": "01a05e22-5af1", "timeoutMs": 3600000, "persistent": False})},
                {"type": "tool_result", "is_error": True, "content": json.dumps({"type": "ReadFile", "FileNotFound": "Error: /nope does not exist."})},
            ],
        },
    },
    {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "duration_ms": 51965,
        "duration_api_ms": 10224,
        "num_turns": 3,
        "result": "Watching until origin/main has (#5697).",
        "stop_reason": "end_turn",
        "total_cost_usd": 0.0186728,
        "usage": {"input_tokens": 36334, "output_tokens": 222, "cache_read_input_tokens": 71680},
        "session_id": SID2,
    },
]

GROK_ACP = [
    {"type": "available_commands", "tools": ["run_terminal_command"], "commands": ["compact"]},
    {"type": "thought", "data": "The"},
    {"type": "thought", "data": " user"},
    {"type": "thought", "data": " wants"},
    {"type": "thought", "data": " PONG.\n"},
    {"type": "tool_call", "toolCallId": "call_1", "toolName": "run_terminal_command", "status": "in_progress", "rawInput": {"command": "ls"}},
    {"type": "tool_call_update", "toolCallId": "call_1", "status": "completed", "rawOutput": {"type": "Bash", "output": list(b"a.txt\nb.txt\n")}},
    {"type": "text", "data": "P"},
    {"type": "text", "data": "ONG"},
    {"type": "usage", "usage": {"input_tokens": 35564, "output_tokens": 28, "reasoning_tokens": 22}},
    {
        "type": "end",
        "stopReason": "end_turn",
        "sessionId": SID3,
        "requestId": "r1",
        "usage": {"input_tokens": 35564, "output_tokens": 28},
        "num_turns": 1,
        "total_cost_usd": 0.0121312,
    },
]


def run_stream(events: list[dict], backend: str) -> tuple[str, str, str]:
    payload = "".join(json.dumps(ev) + "\n" for ev in events)
    env = os.environ.copy()
    env["AGENT_HUMAN_STREAM_BACKEND"] = backend
    env["AGENT_HUMAN_STREAM_NAME"] = "self-test"
    env["AGENT_HUMAN_STREAM_PID"] = "4242"
    for key in ("AGENT_HUMAN_STREAM_MODEL", "CLAUDE_HUMAN_STREAM_MODEL"):
        env.pop(key, None)
    with tempfile.TemporaryDirectory() as tmp:
        live = Path(tmp) / "live.log"
        reg = Path(tmp) / "reg.jsonl"
        env["AGENT_HUMAN_STREAM_LIVE_LOG"] = str(live)
        env["AGENT_HUMAN_STREAM_REGISTRY"] = str(reg)
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
        final_file = live.with_name(live.name + ".final.md")
        final = final_file.read_text() if final_file.exists() else ""
        registry = reg.read_text() if reg.exists() else ""
    return proc.stdout, final, registry


def require(haystack: str, needle: str) -> None:
    if needle not in haystack:
        raise SystemExit(f"missing {needle!r} in:\n{haystack}")


def forbid(haystack: str, needle: str) -> None:
    if needle in haystack:
        raise SystemExit(f"unexpected {needle!r} in:\n{haystack}")


def main() -> None:
    claude, final, reg = run_stream(CLAUDE_STREAM, "claude")
    require(claude, f"📎 session_id={SID1}")
    require(claude, "backend=claude")
    require(claude, "🤖 Checking the repo.")
    require(claude, "🔧 $ git status")
    require(claude, "📎 tool → clean")
    require(claude, "—— final ——")
    require(claude, "Claude done.")
    require(claude, "claude-human-stream --resume")
    require(final, "Claude done.")
    require(reg, '"model": "opus"')

    grok_msg, final, reg = run_stream(GROK_MESSAGES, "grok")
    require(grok_msg, f"📎 session_id={SID2}")
    require(grok_msg, "backend=grok")
    require(grok_msg, "init model=grok-4.6 cwd=/Users/x/sume/sume-com tools=4 mcp=1/2")
    require(grok_msg, "(thinking) I'm the Grok land babysitter for PR #5697 / issue #5696. I need to check origin/main first, then the MQ label")
    require(grok_msg, "🔧 $ git remote -v | head -4")
    require(grok_msg, "🔧 read_file /Users/x/.agents/skills/sume-gt-mq/SKILL.md")
    require(grok_msg, "🔧 grep /avatar-videos.idempotency/ **/*.ts")
    require(grok_msg, "⏳ monitor (background; ends the -p turn)")
    require(grok_msg, "📎 tool → === remote === origin\tgit@github.com:sumelabs/sume-com.git (fetch)")
    forbid(grok_msg, '"output":[61')
    require(grok_msg, "📎 tool → 1→--- name: sume-gt-mq")
    require(grok_msg, "📎 tool → apps/api/vitest.config.ts:3")
    require(grok_msg, "📎 tool → monitor task 01a05e22-5af1 started")
    require(grok_msg, "❌ tool → not found: Error: /nope does not exist.")
    require(grok_msg, "📊 turns=3 wall=52s api=10s cost=$0.0187 in=36334 out=222 cached=71680 stop=end_turn")
    require(grok_msg, "Watching until origin/main has (#5697).")
    require(grok_msg, "agent-human-stream --backend grok --resume")
    require(final, "Watching until origin/main has (#5697).")
    require(reg, '"model": "grok-4.6"')
    require(reg, '"total_cost_usd": 0.0186728')
    require(reg, '"event": "end"')

    grok_acp, final, reg = run_stream(GROK_ACP, "grok")
    require(grok_acp, f"📎 session_id={SID3}")
    require(grok_acp, "(thinking) The user wants PONG.")
    forbid(grok_acp, "(thinking) The\n")
    require(grok_acp, "🔧 $ ls")
    require(grok_acp, "📎 tool → a.txt b.txt")
    require(grok_acp, "🤖 PONG")
    require(grok_acp, "📊 turns=1 cost=$0.0121 in=35564 out=28 stop=end_turn")
    require(grok_acp, "—— final ——\nPONG")
    require(final, "PONG")

    print("agent-human-stream self-test: ok (claude + grok messages + grok acp)")


if __name__ == "__main__":
    main()
