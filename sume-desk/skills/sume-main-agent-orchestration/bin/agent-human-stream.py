#!/usr/bin/env python3
"""Format Claude Code + Grok Build headless NDJSON into short human lines.

Accepts:

- Claude ``--output-format stream-json`` (type: assistant / user / result)
- Grok ``--output-format streaming-messages-json`` (same Messages wire)
- Grok native ``--output-format streaming-json`` (ACP: text / thought /
  tool_call / tool_call_update / end)

Surfaces a resume id once when first seen and again just above
``—— final ——``:

  📎 session_id=<uuid>

Human-visible progress is teed to AGENT_HUMAN_STREAM_LIVE_LOG (or the
legacy CLAUDE_HUMAN_STREAM_LIVE_LOG).
"""
from __future__ import annotations

import json
import os
import sys
import time

_live_fp = None


def env(*keys: str, default: str = "") -> str:
    for key in keys:
        val = os.environ.get(key)
        if val is not None and str(val).strip():
            return str(val)
    return default


def live_emit(line: str) -> None:
    """Write one human line to stdout and the optional live log."""
    print(line, flush=True)
    global _live_fp
    path = env("AGENT_HUMAN_STREAM_LIVE_LOG", "CLAUDE_HUMAN_STREAM_LIVE_LOG")
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


def _short(value, n: int = 160) -> str:
    return str(value or "").replace("\n", " ")[:n]


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
            parts.append(_tool_line(c.get("name") or "tool", c.get("input") or {}))
        elif t == "thinking":
            th = _short(c.get("thinking") or "", 80)
            if th:
                parts.append(f"(thinking) {th}")
        elif t == "server_tool_use":
            parts.append(_tool_line(c.get("name") or "server_tool", c.get("input") or {}))
    return "\n".join(p for p in parts if p)


def _tool_line(name: str, inp) -> str:
    if not isinstance(inp, dict):
        inp = {}
    key = (name or "tool").strip()
    low = key.lower()
    if low in {"bash", "run_terminal_cmd", "shell"}:
        cmd = _short(inp.get("command") or inp.get("cmd") or "")
        return f"$ {cmd}" if cmd else key
    path = inp.get("path") or inp.get("file") or inp.get("file_path")
    if path:
        return f"{key} {path}"
    return f"{key} {_short(inp, 120)}"


def extract_session_id(ev: dict) -> str | None:
    for key in ("session_id", "sessionId"):
        sid = ev.get(key)
        if isinstance(sid, str) and sid.strip():
            return sid.strip()
    data = ev.get("data")
    if isinstance(data, dict):
        for key in ("session_id", "sessionId"):
            sid = data.get(key)
            if isinstance(sid, str) and sid.strip():
                return sid.strip()
    return None


def backend_name() -> str:
    return (env("AGENT_HUMAN_STREAM_BACKEND", "CLAUDE_HUMAN_STREAM_BACKEND") or "claude").strip().lower()


def append_registry(event: str, session_id: str | None) -> None:
    path = env("AGENT_HUMAN_STREAM_REGISTRY", "CLAUDE_HUMAN_STREAM_REGISTRY")
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": event,
            "backend": backend_name(),
            "session_id": session_id,
            "cwd": env("AGENT_HUMAN_STREAM_CWD", "CLAUDE_HUMAN_STREAM_CWD") or os.getcwd(),
            "name": env("AGENT_HUMAN_STREAM_NAME", "CLAUDE_HUMAN_STREAM_NAME") or None,
            "prompt_head": env("AGENT_HUMAN_STREAM_PROMPT_HEAD", "CLAUDE_HUMAN_STREAM_PROMPT_HEAD")
            or None,
            "pid": int(env("AGENT_HUMAN_STREAM_PID", "CLAUDE_HUMAN_STREAM_PID") or "0") or None,
            "resume_from": env("AGENT_HUMAN_STREAM_RESUME_FROM", "CLAUDE_HUMAN_STREAM_RESUME_FROM")
            or None,
            "live_log": env("AGENT_HUMAN_STREAM_LIVE_LOG", "CLAUDE_HUMAN_STREAM_LIVE_LOG") or None,
            "model": env("AGENT_HUMAN_STREAM_MODEL", "CLAUDE_HUMAN_STREAM_MODEL") or None,
            "effort": env("AGENT_HUMAN_STREAM_EFFORT", "CLAUDE_HUMAN_STREAM_EFFORT") or None,
        }
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def print_session_id(session_id: str, *, again: bool = False) -> None:
    name = env("AGENT_HUMAN_STREAM_NAME", "CLAUDE_HUMAN_STREAM_NAME").strip()
    backend = backend_name()
    extra = f"  name={name}" if name else ""
    live_emit(f"📎 session_id={session_id}  backend={backend}{extra}")
    if again:
        live_emit(f'(resume) agent-human-stream --backend {backend} --resume {session_id} "…"')
        if backend == "claude":
            live_emit(f'(resume) claude-human-stream --resume {session_id} "…"')


def _acp_tool_line(ev: dict) -> str:
    name = ev.get("toolName") or ev.get("title") or "tool"
    inp = ev.get("rawInput") if isinstance(ev.get("rawInput"), dict) else {}
    status = ev.get("status") or ""
    line = _tool_line(str(name), inp)
    return f"{line} ({status})" if status and status != "in_progress" else line


def format_event(ev: dict) -> tuple[list[str], str | None]:
    """Return (human lines, final-result-if-terminal)."""
    typ = ev.get("type")
    lines: list[str] = []
    final: str | None = None

    if typ == "assistant":
        msg = ev.get("message") or {}
        bit = text_bits(msg.get("content"))
        if bit:
            lines.extend(f"🤖 {row}" for row in bit.splitlines() if row)
    elif typ == "user":
        msg = ev.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    out = _short(c.get("content") or "", 200)
                    lines.append(f"📎 tool → {out}")
    elif typ == "result":
        final = ev.get("result")
        if final is None and isinstance(ev.get("content"), str):
            final = ev.get("content")
        if ev.get("is_error") or ev.get("subtype") in {
            "error_during_execution",
            "error_max_turns",
            "error_max_structured_output_retries",
        }:
            err = ev.get("errors") or ev.get("message") or final
            lines.append(f"❌ { _short(err, 240)}")
    elif typ == "system":
        subtype = ev.get("subtype") or ""
        if subtype == "init":
            model = ev.get("model") or ""
            cwd = ev.get("cwd") or ""
            bits = [b for b in (f"model={model}" if model else "", f"cwd={cwd}" if cwd else "") if b]
            lines.append("init " + " ".join(bits) if bits else "init")
        elif subtype == "compact_boundary":
            lines.append("compact")
    elif typ == "text":
        data = ev.get("data")
        if isinstance(data, str) and data.strip():
            for row in data.splitlines():
                if row:
                    lines.append(f"🤖 {row}")
            final = data
    elif typ == "thought":
        th = _short(ev.get("data") or "", 80)
        if th:
            lines.append(f"(thinking) {th}")
    elif typ == "tool_call":
        lines.append(f"🔧 {_acp_tool_line(ev)}")
    elif typ == "tool_call_update":
        status = ev.get("status") or "update"
        out = ev.get("rawOutput")
        summary = _short(out, 200) if out not in (None, "", [], {}) else ""
        if summary:
            lines.append(f"📎 tool → {summary}")
        elif status and status != "in_progress":
            lines.append(f"📎 tool {status}")
    elif typ == "end":
        final = ev.get("result")
        if final is None and isinstance(ev.get("data"), str):
            final = ev.get("data")
    elif typ == "error":
        lines.append(f"❌ {_short(ev.get('message') or ev, 240)}")
        final = ev.get("message")
    elif typ == "plan":
        entries = ev.get("entries") or ev.get("data")
        if entries:
            lines.append(f"📋 {_short(entries, 160)}")
    elif typ in {"usage", "available_commands", "stream_event"}:
        pass
    return lines, final


def main() -> None:
    final = None
    session_id: str | None = None
    announced = False
    last_text = None
    global _live_fp

    live_path = env("AGENT_HUMAN_STREAM_LIVE_LOG", "CLAUDE_HUMAN_STREAM_LIVE_LOG").strip()
    name = env("AGENT_HUMAN_STREAM_NAME", "CLAUDE_HUMAN_STREAM_NAME").strip()
    resume_from = env("AGENT_HUMAN_STREAM_RESUME_FROM", "CLAUDE_HUMAN_STREAM_RESUME_FROM").strip()
    backend = backend_name()
    if live_path or name or resume_from or backend:
        live_emit("—— agent live ——")
        live_emit(f"backend: {backend}")
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
            if not isinstance(ev, dict):
                live_emit(f"… {_short(ev, 200)}")
                continue

            sid = extract_session_id(ev)
            if sid and not session_id:
                session_id = sid
                print_session_id(session_id)
                announced = True
                append_registry("session", session_id)
            elif sid and session_id and sid != session_id:
                session_id = sid
                print_session_id(session_id)
                append_registry("session", session_id)

            rows, maybe_final = format_event(ev)
            for row in rows:
                live_emit(row)
            if ev.get("type") == "text" and isinstance(ev.get("data"), str):
                last_text = ev.get("data")
            if maybe_final is not None and ev.get("type") in {"result", "end", "error"}:
                final = maybe_final

        if final is None:
            final = last_text

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
