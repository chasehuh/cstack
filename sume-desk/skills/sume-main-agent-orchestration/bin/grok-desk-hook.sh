#!/usr/bin/env bash
# Grok Build hook → desk registry row. Installed by cstack install.sh as
# ~/.grok/hooks/sume-desk.json for Stop / SessionEnd / PostCompact /
# StopFailure (sumelabs/sume#5706 Slice D).
#
# Contract (Grok 1.0.11 hooks reference, same as tokenmaxxing's hook): stdin is
# a camelCase JSON envelope (sessionId, hookEventName, reason, error, …). A
# hook that exits 0 with NO stdout allows the event; never print, never block.
#
#   grok-desk-hook.sh <event>      # event = stop|session_end|post_compact|stop_failure
set -uo pipefail

EVENT="${1:-unknown}"
REGISTRY="${AGENT_HUMAN_STREAM_REGISTRY:-${CSTACK_STATE:-$HOME/.cstack/state}/opus-sessions.jsonl}"
RAW="$(cat 2>/dev/null || true)"

python3 - "$EVENT" "$REGISTRY" "$RAW" <<'PYHOOK' >/dev/null 2>&1 || true
import json, os, sys, time
event, path, raw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    env = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    env = {}
if not isinstance(env, dict):
    env = {}
row = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "event": f"hook_{event}",
    "backend": "grok",
    "session_id": env.get("sessionId") or env.get("session_id"),
    "cwd": env.get("cwd") or os.getcwd(),
    "name": os.environ.get("AGENT_HUMAN_STREAM_NAME") or None,
    "pid": int(os.environ.get("AGENT_HUMAN_STREAM_PID") or "0") or None,
    "hook_event": env.get("hookEventName") or event,
    "reason": env.get("reason"),
    "error": env.get("error"),
    "trigger": env.get("trigger"),
    "tokens_before": env.get("tokensBefore") or env.get("tokens_before"),
    "tokens_after": env.get("tokensAfter") or env.get("tokens_after"),
    "supervisor_id": os.environ.get("TOKENMAXXING_GROK_SUPERVISOR_ID"),
}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYHOOK
exit 0
