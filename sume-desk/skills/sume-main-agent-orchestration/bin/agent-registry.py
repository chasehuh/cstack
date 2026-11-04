#!/usr/bin/env python3
"""Registry rows for agent-human-stream (start / exit) with Grok harvest.

    agent-registry.py start
    agent-registry.py exit --exit-code N [--aborted 0|1] [--landed yes|no|n/a]
                           [--cycles N] [--child-pid P]

Reads the AGENT_HUMAN_STREAM_* environment the wrapper exports. On exit for
a Grok session it also harvests ~/.grok/sessions/*/<uuid>/{signals,summary}.json
(context %, compaction count, tool calls, errors, git/PR counts) so the
registry answers "how big did that session get" without opening Grok.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import time


def env(key: str) -> str | None:
    val = os.environ.get(key)
    return val if val is not None and val.strip() else None


def base_row(event: str) -> dict:
    pid = int(env("AGENT_HUMAN_STREAM_PID") or "0") or None
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
        "backend": env("AGENT_HUMAN_STREAM_BACKEND"),
        "session_id": env("AGENT_HUMAN_STREAM_SESSION_ID"),
        "cwd": env("AGENT_HUMAN_STREAM_CWD") or os.getcwd(),
        "name": env("AGENT_HUMAN_STREAM_NAME"),
        "prompt_head": env("AGENT_HUMAN_STREAM_PROMPT_HEAD"),
        "pid": pid,
        "pgid": int(env("AGENT_HUMAN_STREAM_PGID") or "0") or None,
        "resume_from": env("AGENT_HUMAN_STREAM_RESUME_FROM"),
        "live_log": env("AGENT_HUMAN_STREAM_LIVE_LOG"),
        "model": env("AGENT_HUMAN_STREAM_MODEL"),
        "effort": env("AGENT_HUMAN_STREAM_EFFORT"),
        "grok_version": env("AGENT_HUMAN_STREAM_GROK_VERSION"),
        "wall_timeout": env("AGENT_HUMAN_STREAM_WALL_TIMEOUT"),
        "until_landed": env("AGENT_HUMAN_STREAM_UNTIL_LANDED"),
    }


def harvest_grok(session_id: str) -> dict:
    out: dict = {}
    home = os.path.expanduser(os.environ.get("GROK_HOME") or "~/.grok")
    for d in glob.glob(os.path.join(home, "sessions", "*", session_id)):
        out["session_dir"] = d
        try:
            sig = json.load(open(os.path.join(d, "signals.json"), encoding="utf-8"))
            out.update(
                {
                    "context_pct": sig.get("contextWindowUsage"),
                    "context_tokens": sig.get("contextTokensUsed"),
                    "context_window": sig.get("contextWindowTokens"),
                    "compaction_count": sig.get("compactionCount"),
                    "tool_calls": sig.get("toolCallCount"),
                    "errors": sig.get("errorCount"),
                    "git_commits": sig.get("gitCommitCount"),
                    "prs_created": sig.get("prCreatedCount"),
                    "prs_merged": sig.get("prMergedCount"),
                    "idle_timeouts": sig.get("inferenceIdleTimeouts"),
                }
            )
            models = sig.get("modelsUsed") or []
            if models and not env("AGENT_HUMAN_STREAM_MODEL"):
                out["model"] = sig.get("primaryModelId") or models[0]
        except (OSError, ValueError):
            pass
        try:
            summ = json.load(open(os.path.join(d, "summary.json"), encoding="utf-8"))
            out["num_messages"] = summ.get("num_messages")
            out["session_kind"] = summ.get("session_kind")
            out["session_title"] = summ.get("session_summary")
            out["session_cwd"] = (summ.get("info") or {}).get("cwd")
            if not out.get("model"):
                out["model"] = summ.get("current_model_id")
        except (OSError, ValueError):
            pass
        break
    return out


def write(row: dict) -> None:
    path = env("AGENT_HUMAN_STREAM_REGISTRY")
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("event", choices=["start", "exit"])
    ap.add_argument("--exit-code", type=int, default=None)
    ap.add_argument("--aborted", default="0")
    ap.add_argument("--landed", default="")
    ap.add_argument("--cycles", type=int, default=0)
    ap.add_argument("--child-pid", default="")
    a = ap.parse_args()
    if a.event == "start":
        write(base_row("start"))
        return
    aborted = a.aborted == "1" or (a.exit_code in (124, 130, 143))
    row = base_row("abort" if aborted else "exit")
    row.update(
        {
            "exit_code": a.exit_code,
            "aborted": aborted,
            "landed": a.landed or None,
            "land_cycles": a.cycles or None,
            "child_pid": int(a.child_pid) if a.child_pid.isdigit() else None,
        }
    )
    sid = row.get("session_id")
    if sid and row.get("backend") == "grok":
        row.update(harvest_grok(sid))
    write(row)


if __name__ == "__main__":
    main()
