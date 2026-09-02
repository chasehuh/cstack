#!/usr/bin/env bash
# grok-desk-hook: silent, exit 0, one registry row per event.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export AGENT_HUMAN_STREAM_REGISTRY="$TMP/reg.jsonl"
fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(printf '{"hookEventName":"Stop","sessionId":"01a05e1f-90bb-7561-b9a9-8f5e4f9558c6","reason":"end_turn"}' | "$ROOT/grok-desk-hook.sh" stop)
[[ -z "$out" ]] || fail "hook printed to stdout: $out"
grep -q '"event": "hook_stop"' "$TMP/reg.jsonl" || fail "no hook_stop row"
grep -q '"reason": "end_turn"' "$TMP/reg.jsonl" || fail "reason missing"
printf '{"hookEventName":"PostCompact","sessionId":"x","trigger":"auto","tokensBefore":400000,"tokensAfter":90000}' | "$ROOT/grok-desk-hook.sh" post_compact
grep -q '"event": "hook_post_compact"' "$TMP/reg.jsonl" || fail "no post_compact row"
grep -q '"tokens_before": 400000' "$TMP/reg.jsonl" || fail "tokens_before missing"
printf 'not json' | "$ROOT/grok-desk-hook.sh" stop_failure || fail "hook must exit 0 on garbage"
[[ $(grep -c . "$TMP/reg.jsonl") -eq 3 ]] || fail "expected 3 rows"
AGENT_HUMAN_STREAM_REGISTRY="/nonexistent-dir-$$/reg.jsonl" "$ROOT/grok-desk-hook.sh" session_end </dev/null || fail "hook must exit 0 even if registry is unwritable"
echo "grok-desk-hook test: ok"
