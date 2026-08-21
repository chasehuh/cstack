#!/usr/bin/env python3
"""Format Claude Code stream-json NDJSON into short human-readable lines.

Also surfaces Claude session ids for resume:

  📎 session_id=<uuid>

Printed once when first seen (usually system/init) and again just above
—— final —— so the main agent can capture it from a finished terminal log.

Human-visible progress is teed to a live log (see CLAUDE_HUMAN_STREAM_LIVE_LOG)
so resume/background runs can be watched with ``tail -f`` without polling from
the main agent.

Stream-json events use snake_case ``session_id``; on-disk
``~/.claude/projects/<slug>/*.jsonl`` uses camelCase ``sessionId``.
"""
from __future__ import annotations

import json
import os
import sys
import time

_live_fp = None


def live_emit(line: str) -> None:
    """Write one human line to stdout and the optional live log."""
    print(line, flush=True)
    global _live_fp
    path = os.environ.get("CLAUDE_HUMAN_STREAM_LIVE_LOG")
    if not path:
        return
    try:
        if _live_fp is None:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            _live_fp = open(path, "a", encoding="utf-8")
        _live_fp.write(line + "\n")
        _live_fp.flush()
    except OSError:
        pass


def text_bits(content) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for c in content:
        if not isinstance(c, dict):
            continue
        t = c.get("type")
        if t == "text":
            parts.append(c.get("text") or "")
        elif t == "tool_use":
            name = c.get("name") or "tool"
            inp = c.get("input") or {}
            if name == "Bash":
                cmd = str(inp.get("command") or "")[:160].replace("\n", " ")
                parts.append(f"$ {cmd}")
            else:
                summary = str(inp)[:120].replace("\n", " ")
                parts.append(f"{name} {summary}")
        elif t == "thinking":
            th = (c.get("thinking") or "")[:80].replace("\n", " ")
            if th:
                parts.append(f"(thinking) {th}")
    return "\n".join(p for p in parts if p)


def extract_session_id(ev: dict) -> str | None:
    sid = ev.get("session_id") or ev.get("sessionId")
    if isinstance(sid, str) and sid.strip():
        return sid.strip()
    return None


def append_registry(event: str, session_id: str | None) -> None:
    path = os.environ.get("CLAUDE_HUMAN_STREAM_REGISTRY")
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": event,
            "session_id": session_id,
            "cwd": os.environ.get("CLAUDE_HUMAN_STREAM_CWD") or os.getcwd(),
            "name": os.environ.get("CLAUDE_HUMAN_STREAM_NAME") or None,
            "prompt_head": os.environ.get("CLAUDE_HUMAN_STREAM_PROMPT_HEAD") or None,
            "pid": int(os.environ["CLAUDE_HUMAN_STREAM_PID"])
            if os.environ.get("CLAUDE_HUMAN_STREAM_PID")
            else None,
            "resume_from": os.environ.get("CLAUDE_HUMAN_STREAM_RESUME_FROM") or None,
            "live_log": os.environ.get("CLAUDE_HUMAN_STREAM_LIVE_LOG") or None,
        }
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        # Registry is best-effort; never break the human stream.
        pass


def print_session_id(session_id: str, *, again: bool = False) -> None:
    name = (os.environ.get("CLAUDE_HUMAN_STREAM_NAME") or "").strip()
    if name:
        live_emit(f"📎 session_id={session_id}  name={name}")
    else:
        live_emit(f"📎 session_id={session_id}")
    if again:
        live_emit(f'(resume) claude-human-stream --resume {session_id} "…"')


def main() -> None:
    final = None
    session_id: str | None = None
    announced = False
    global _live_fp

    live_path = (os.environ.get("CLAUDE_HUMAN_STREAM_LIVE_LOG") or "").strip()
    name = (os.environ.get("CLAUDE_HUMAN_STREAM_NAME") or "").strip()
    resume_from = (os.environ.get("CLAUDE_HUMAN_STREAM_RESUME_FROM") or "").strip()
    if live_path or name or resume_from:
        live_emit("—— opus live ——")
        if name:
            live_emit(f"name: {name}")
        if resume_from:
            live_emit(f"resume_from: {resume_from}")
        if live_path:
            live_emit(f"live_log: {live_path}")
            live_emit(f"watch: tail -f {live_path!r}")

    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                live_emit(f"… {line[:200]}")
                continue

            sid = extract_session_id(ev) if isinstance(ev, dict) else None
            if sid and not session_id:
                session_id = sid
                print_session_id(session_id)
                announced = True
                append_registry("session", session_id)
            elif sid and session_id and sid != session_id:
                # Fork or unexpected id change — surface it.
                session_id = sid
                print_session_id(session_id)
                append_registry("session", session_id)

            typ = ev.get("type") if isinstance(ev, dict) else None
            if typ == "assistant":
                msg = ev.get("message") or {}
                bit = text_bits(msg.get("content"))
                if bit:
                    for row in bit.splitlines():
                        live_emit(f"🤖 {row}")
            elif typ == "user":
                msg = ev.get("message") or {}
                content = msg.get("content")
                if isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_result":
                            out = str(c.get("content") or "")[:200].replace("\n", " ")
                            live_emit(f"📎 tool → {out}")
            elif typ == "result":
                final = ev.get("result")
                if final is None and isinstance(ev.get("content"), str):
                    final = ev.get("content")
                # result events always carry session_id in current Claude CLI.
                if sid:
                    session_id = sid

        live_emit("")
        if session_id:
            if not announced:
                print_session_id(session_id)
            else:
                print_session_id(session_id, again=True)
            append_registry("end", session_id)
        live_emit("—— final ——")
        live_emit(final if final is not None else "(no result field)")
    finally:
        if _live_fp is not None:
            try:
                _live_fp.close()
            except OSError:
                pass
            _live_fp = None


if __name__ == "__main__":
    main()
