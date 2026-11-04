#!/usr/bin/env python3
"""Format Claude Code + Grok Build headless NDJSON into short human lines.

Accepts:

- Claude ``--output-format stream-json`` (type: assistant / user / result)
- Grok ``--output-format streaming-messages-json`` (same Messages wire; Grok
  tool results arrive as JSON blobs whose ``output`` is a byte array)
- Grok native ``--output-format streaming-json`` (ACP: per-token ``thought`` /
  ``text`` deltas, ``tool_call`` / ``tool_call_update``, ``usage``, ``end`` —
  the session id only arrives on ``end``)

Surfaces a resume id once when first seen and again just above
``—— final ——``:

  📎 session_id=<uuid>

Human-visible progress is teed to AGENT_HUMAN_STREAM_LIVE_LOG (or the
legacy CLAUDE_HUMAN_STREAM_LIVE_LOG); the final text is also written to
``<live_log>.final.md`` so a caller never has to scrape the log.
"""
from __future__ import annotations

import json
import os
import sys
import time

_live_fp = None
THINK_WIDTH = int(os.environ.get("AGENT_HUMAN_STREAM_THINK_WIDTH") or "160")
TOOL_OUT_WIDTH = int(os.environ.get("AGENT_HUMAN_STREAM_TOOL_WIDTH") or "200")


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


def _bytes_to_text(value) -> str | None:
    """Grok ships command output as a JSON array of byte values."""
    if isinstance(value, list) and value and all(isinstance(b, int) and 0 <= b < 256 for b in value):
        try:
            return bytes(value).decode("utf-8", errors="replace")
        except (ValueError, TypeError):
            return None
    return None


def decode_tool_result(content) -> str:
    """Turn a tool_result payload (Claude text, Grok JSON blob) into plain text."""
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                parts.append(str(c.get("text") or ""))
            elif isinstance(c, str):
                parts.append(c)
        content = "\n".join(parts)
    if not isinstance(content, str):
        content = json.dumps(content, ensure_ascii=False) if content is not None else ""
    text = content.strip()
    if not text.startswith("{"):
        return text
    try:
        blob = json.loads(text)
    except json.JSONDecodeError:
        return text
    if not isinstance(blob, dict):
        return text
    kind = blob.get("type") or ""
    for key in ("output", "stdout", "stderr"):
        decoded = _bytes_to_text(blob.get(key))
        if decoded is not None:
            exit_code = blob.get("exit_code")
            suffix = f" (exit {exit_code})" if isinstance(exit_code, int) and exit_code != 0 else ""
            return f"{decoded.strip()}{suffix}" if decoded.strip() else f"(no {key}){suffix}"
        if isinstance(blob.get(key), str) and blob.get(key):
            return str(blob[key])
    fc = blob.get("FileContent")
    if isinstance(fc, dict) and isinstance(fc.get("content"), str):
        return fc["content"]
    if isinstance(blob.get("FileNotFound"), str):
        return f"not found: {blob['FileNotFound']}"
    todo = blob.get("TodosUpdated")
    if isinstance(todo, dict) and isinstance(todo.get("summary_for_prompt"), str):
        return todo["summary_for_prompt"]
    out = blob.get("output")
    if isinstance(out, dict):
        for key in ("OkayOutput", "ErrorOutput", "content", "text"):
            if isinstance(out.get(key), str):
                return out[key]
    if isinstance(blob.get("content"), str):
        return blob["content"]
    if kind == "Monitor" and blob.get("taskId"):
        return f"monitor task {blob['taskId']} started (timeout {blob.get('timeoutMs')} ms) — the -p turn will end while it waits"
    return text


_SHELL_TOOLS = {"bash", "run_terminal_cmd", "run_terminal_command", "shell"}
_PATH_KEYS = ("path", "file", "file_path", "target_file", "target_directory", "directory")


def _tool_line(name: str, inp) -> str:
    if not isinstance(inp, dict):
        inp = {}
    key = (name or "tool").strip()
    low = key.lower()
    if low in _SHELL_TOOLS:
        cmd = _short(inp.get("command") or inp.get("cmd") or "")
        return f"$ {cmd}" if cmd else key
    if low == "monitor":
        return f"⏳ monitor (background; ends the -p turn) {_short(inp.get('command') or '', 120)}"
    if low in {"get_command_or_subagent_output", "get_task_output"}:
        return f"⏳ wait {_short(inp.get('task_id') or inp.get('id') or inp, 60)}"
    if low in {"spawn_subagent", "task"}:
        return f"🧵 subagent {_short(inp.get('description') or inp.get('prompt') or '', 120)}"
    for pk in _PATH_KEYS:
        if inp.get(pk):
            extra = ""
            if inp.get("pattern"):
                extra = f" /{_short(inp.get('pattern'), 60)}/"
            return f"{key} {inp[pk]}{extra}"
    if inp.get("pattern"):
        return f"{key} /{_short(inp.get('pattern'), 80)}/ {_short(inp.get('glob') or '', 40)}".rstrip()
    if inp.get("query"):
        return f"{key} {_short(inp.get('query'), 120)}"
    return f"{key} {_short(inp, 120)}"


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
            parts.append("🔧 " + _tool_line(c.get("name") or "tool", c.get("input") or {}))
        elif t == "thinking":
            th = _short(c.get("thinking") or "", THINK_WIDTH)
            if th:
                parts.append(f"(thinking) {th}")
        elif t == "server_tool_use":
            parts.append("🔧 " + _tool_line(c.get("name") or "server_tool", c.get("input") or {}))
    return "\n".join(p for p in parts if p)


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


_MODEL_SEEN: str | None = None


def append_registry(event: str, session_id: str | None, extra: dict | None = None) -> None:
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
            "model": env("AGENT_HUMAN_STREAM_MODEL", "CLAUDE_HUMAN_STREAM_MODEL") or _MODEL_SEEN,
            "effort": env("AGENT_HUMAN_STREAM_EFFORT", "CLAUDE_HUMAN_STREAM_EFFORT") or None,
        }
        if extra:
            rec.update(extra)
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


def usage_line(ev: dict) -> str | None:
    usage = ev.get("usage") if isinstance(ev.get("usage"), dict) else {}
    bits = []
    if ev.get("num_turns") is not None:
        bits.append(f"turns={ev.get('num_turns')}")
    if ev.get("duration_ms") is not None:
        bits.append(f"wall={round(ev['duration_ms'] / 1000)}s")
    if ev.get("duration_api_ms") is not None:
        bits.append(f"api={round(ev['duration_api_ms'] / 1000)}s")
    if ev.get("total_cost_usd") is not None:
        bits.append(f"cost=${ev['total_cost_usd']:.4f}")
    if usage.get("input_tokens") is not None:
        bits.append(f"in={usage.get('input_tokens')}")
    if usage.get("output_tokens") is not None:
        bits.append(f"out={usage.get('output_tokens')}")
    if usage.get("cache_read_input_tokens"):
        bits.append(f"cached={usage.get('cache_read_input_tokens')}")
    if ev.get("stop_reason") or ev.get("stopReason"):
        bits.append(f"stop={ev.get('stop_reason') or ev.get('stopReason')}")
    return "📊 " + " ".join(bits) if bits else None


def usage_fields(ev: dict) -> dict:
    usage = ev.get("usage") if isinstance(ev.get("usage"), dict) else {}
    return {
        "num_turns": ev.get("num_turns"),
        "duration_ms": ev.get("duration_ms"),
        "total_cost_usd": ev.get("total_cost_usd"),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "cache_read_input_tokens": usage.get("cache_read_input_tokens"),
        "stop_reason": ev.get("stop_reason") or ev.get("stopReason"),
        "is_error": bool(ev.get("is_error")),
    }


def format_event(ev: dict) -> tuple[list[str], str | None]:
    """Return (human lines, final-result-if-terminal)."""
    global _MODEL_SEEN
    typ = ev.get("type")
    lines: list[str] = []
    final: str | None = None

    if typ == "assistant":
        msg = ev.get("message") or {}
        if isinstance(msg.get("model"), str) and not _MODEL_SEEN:
            _MODEL_SEEN = msg["model"]
        bit = text_bits(msg.get("content"))
        if bit:
            for row in bit.splitlines():
                if not row:
                    continue
                lines.append(row if row.startswith(("🔧", "(thinking)")) else f"🤖 {row}")
    elif typ == "user":
        msg = ev.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    out = _short(decode_tool_result(c.get("content")), TOOL_OUT_WIDTH)
                    marker = "❌ tool" if c.get("is_error") else "📎 tool"
                    lines.append(f"{marker} → {out}")
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
        ul = usage_line(ev)
        if ul:
            lines.append(ul)
    elif typ == "system":
        subtype = ev.get("subtype") or ""
        if subtype == "init":
            model = ev.get("model") or ""
            if isinstance(model, str) and model:
                _MODEL_SEEN = model
            cwd = ev.get("cwd") or ""
            bits = [b for b in (f"model={model}" if model else "", f"cwd={cwd}" if cwd else "") if b]
            tools = ev.get("tools")
            if isinstance(tools, list):
                bits.append(f"tools={len(tools)}")
            mcp = ev.get("mcp_servers")
            if isinstance(mcp, list):
                ok = sum(1 for m in mcp if isinstance(m, dict) and m.get("status") == "connected")
                bits.append(f"mcp={ok}/{len(mcp)}")
            lines.append("init " + " ".join(bits) if bits else "init")
        elif subtype == "compact_boundary":
            lines.append("compact")
    elif typ == "tool_call":
        lines.append(f"🔧 {_acp_tool_line(ev)}")
    elif typ == "tool_call_update":
        status = ev.get("status") or "update"
        out = ev.get("rawOutput")
        summary = _short(decode_tool_result(out) if out not in (None, "", [], {}) else "", TOOL_OUT_WIDTH)
        if summary:
            lines.append(f"📎 tool → {summary}")
        elif status and status != "in_progress":
            lines.append(f"📎 tool {status}")
    elif typ == "end":
        final = ev.get("result")
        if final is None and isinstance(ev.get("data"), str):
            final = ev.get("data")
        ul = usage_line(ev)
        if ul:
            lines.append(ul)
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


class DeltaBuffer:
    """Coalesce ACP per-token ``thought`` / ``text`` deltas into lines."""

    def __init__(self) -> None:
        self.kind: str | None = None
        self.buf = ""

    def push(self, kind: str, data: str) -> list[str]:
        out: list[str] = []
        if self.kind and self.kind != kind:
            out.extend(self.flush())
        self.kind = kind
        self.buf += data
        while "\n" in self.buf:
            row, self.buf = self.buf.split("\n", 1)
            if row.strip():
                out.append(self._render(row))
        return out

    def _render(self, row: str) -> str:
        if self.kind == "thought":
            return f"(thinking) {_short(row, THINK_WIDTH)}"
        return f"🤖 {row}"

    def flush(self) -> list[str]:
        out = []
        if self.buf.strip():
            out.append(self._render(self.buf))
        self.buf = ""
        return out


def main() -> None:
    final = None
    session_id: str | None = None
    announced = False
    last_text_parts: list[str] = []
    usage_extra: dict = {}
    deltas = DeltaBuffer()
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

            typ = ev.get("type")
            if typ in {"thought", "text"} and isinstance(ev.get("data"), str):
                for row in deltas.push(typ, ev["data"]):
                    live_emit(row)
                if typ == "text":
                    last_text_parts.append(ev["data"])
                continue
            for row in deltas.flush():
                live_emit(row)

            sid = extract_session_id(ev)
            if sid and not session_id:
                session_id = sid
                print_session_id(session_id)
                announced = True
                append_registry("session", session_id, {"model": _MODEL_SEEN or env("AGENT_HUMAN_STREAM_MODEL") or None})
            elif sid and session_id and sid != session_id:
                session_id = sid
                print_session_id(session_id)
                append_registry("session", session_id)

            rows, maybe_final = format_event(ev)
            for row in rows:
                live_emit(row)
            if maybe_final is not None and typ in {"result", "end", "error"}:
                final = maybe_final
            if typ in {"result", "end"}:
                usage_extra = usage_fields(ev)

        for row in deltas.flush():
            live_emit(row)
        if final is None and last_text_parts:
            final = "".join(last_text_parts)

        live_emit("")
        if session_id:
            if not announced:
                print_session_id(session_id)
            else:
                print_session_id(session_id, again=True)
            append_registry("end", session_id, usage_extra)
        live_emit("—— final ——")
        live_emit(final if final is not None else "(no result field)")
        if live_path:
            try:
                with open(live_path + ".final.md", "w", encoding="utf-8") as f:
                    f.write((final if final is not None else "") + "\n")
            except OSError:
                pass
    finally:
        if _live_fp is not None:
            try:
                _live_fp.close()
            except OSError:
                pass
            _live_fp = None


if __name__ == "__main__":
    main()
