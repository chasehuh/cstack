#!/usr/bin/env bash
# Human-readable wrapper for Claude Code, Grok Build and Codex headless streams.
#
#   agent-human-stream "Audit #1708 …"
#   agent-human-stream --backend grok --name land-4414 "Watch MQ …"
#   agent-human-stream --backend codex --name probe-api "Audit routes …"
#   agent-human-stream --resume <uuid> "Follow-up …"
#   agent-human-stream --prompt-file /tmp/sume-grok-prompts/job.md
#   claude-human-stream "…"          # alias: --backend claude
#
# Extra backend flags go after the prompt:
#   agent-human-stream "…" --model opus
#   agent-human-stream --backend grok --prompt-file job.md --effort high
#   agent-human-stream --backend codex "…" --model gpt-5.5 --effort xhigh
set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")" && pwd)"
SKILL_DIR="$(cd "$ROOT/.." && pwd)"
# Runtime logs live outside the git SoT tree (skills are symlinks into cstack).
CSTACK_STATE="${CSTACK_STATE:-$HOME/.cstack/state}"
REGISTRY="${AGENT_HUMAN_STREAM_REGISTRY:-${CLAUDE_HUMAN_STREAM_REGISTRY:-$CSTACK_STATE/opus-sessions.jsonl}}"
LIVE_DIR="${AGENT_HUMAN_STREAM_LIVE_DIR:-${CLAUDE_HUMAN_STREAM_LIVE_DIR:-$CSTACK_STATE/opus-live}}"

# Claude Code CLI 2.1.x (SDK + changelog): low|medium|high|xhigh|max.
# Fable / Opus 4.7+ take `max` natively. Do NOT remap max → high.
# Desk aliases: mid → medium, maximum → max, x-high → xhigh.
_claude_effort_wire() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    mid) printf '%s' medium ;;
    max|maximum) printf '%s' max ;;
    xhigh|x-high|xh|extra-high|extrahigh) printf '%s' xhigh ;;
    low|medium|high) printf '%s' "$lc" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Grok Build CLI: xhigh|high|medium|low (no max / mid).
# Aliases: mid → medium, max|maximum → xhigh (Grok ceiling).
_grok_effort_wire() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    mid) printf '%s' medium ;;
    max|maximum|xhigh|x-high|xh|extra-high|extrahigh) printf '%s' xhigh ;;
    low|medium|high) printf '%s' "$lc" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Codex CLI has no --effort flag; reasoning depth is the config key
# model_reasoning_effort = none|minimal|low|medium|high|xhigh (no max / mid).
# Aliases: mid → medium, max|maximum → xhigh (Codex ceiling).
_codex_effort_wire() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    mid) printf '%s' medium ;;
    max|maximum|xhigh|x-high|xh|extra-high|extrahigh) printf '%s' xhigh ;;
    none|minimal|low|medium|high) printf '%s' "$lc" ;;
    *) printf '%s' "$1" ;;
  esac
}

usage() {
  cat <<'EOF'
Human-readable wrapper around Claude Code, Grok Build and Codex headless NDJSON.

  agent-human-stream [--backend claude|grok|codex|auto] [--name <slug>] <prompt> [backend flags…]
  agent-human-stream --prompt-file <path>         # read prompt after flags; no $(cat)
  agent-human-stream --claude "…"                 # same as --backend claude
  agent-human-stream --grok "…"                   # same as --backend grok
  agent-human-stream --codex "…"                  # same as --backend codex
  agent-human-stream --resume <uuid> --prompt-file <path>
  agent-human-stream --sessions
  agent-human-stream --self-test

Auto backend (default):
  --backend grok / --grok / AGENT_HUMAN_STREAM_BACKEND=grok
  --model grok*  → grok
  --model gpt-*|o3*|o4*|codex* → codex
  --model opus|fable|sonnet|haiku|claude* → claude
  --resume <uuid> uses the last backend recorded for that session
  otherwise → claude (Opus/Fable path unchanged)

Claude (tokenmaxxing `claude` on this desk):
  claude -p … --output-format stream-json --verbose --permission-mode bypassPermissions
  Default --effort when omitted (code lane): opus → medium, fable → high,
  grok → xhigh. Research must pass --effort (grok medium / opus+fable low).
  Named Claude levels pass through: low|medium|high|xhigh|max.
  Chase "Fable max" / --effort max → claude --effort max (not high).
  Aliases: mid → medium, maximum → max, x-high → xhigh.

Grok Build (`grok` on PATH):
  grok -p … --output-format streaming-messages-json --permission-mode bypassPermissions --always-approve
  Native ACP streaming-json is also accepted by the formatter if you pass
  --output-format streaming-json after the prompt.
  Grok --effort enum: xhigh, high, medium, low (not mid / not max).
  Aliases: mid → medium, max|maximum → xhigh (Grok ceiling).

Codex (tokenmaxxing `codex` on this desk; Codex pool, not the Claude pool):
  codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check … </dev/null
  --resume <id>  → codex exec resume <id> "…"      --continue → codex exec resume --last "…"
  --fork-session is not supported by Codex (exit 2).
  --effort has no CLI flag; the wrapper maps it to -c model_reasoning_effort="…"
  (enum none|minimal|low|medium|high|xhigh; mid → medium, max|maximum → xhigh).
  Default --effort when omitted: high (AGENT_HUMAN_STREAM_EFFORT_CODEX).
  --model/-m pass through. Claude-only --verbose / --permission-mode /
  --output-format / --always-approve are dropped with a note.
  Session swap (tokenmaxxing switch --codex) applies on the NEXT codex start.

Resume:
  --resume <uuid>   | AGENT_RESUME_SESSION / CLAUDE_RESUME_SESSION / GROK_RESUME_SESSION
  --continue        most recent session in this cwd
  --fork-session    new session id, copy history

Watch:
  tail -f ~/.cstack/state/opus-live/LATEST.log

On stream start/end the formatter prints:
  📎 session_id=<uuid>  backend=<claude|grok|codex>
and again just above —— final ——.
EOF
}

BACKEND="${AGENT_HUMAN_STREAM_BACKEND:-auto}"
RESUME="${AGENT_RESUME_SESSION:-${GROK_RESUME_SESSION:-${CLAUDE_RESUME_SESSION:-}}}"
NAME=""
CONTINUE=0
FORK=0
LIST_SESSIONS=0
SELF_TEST=0
PROMPT=""
PROMPT_FILE=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --sessions)
      LIST_SESSIONS=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    --backend)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --backend requires claude|grok|codex|auto" >&2
        exit 2
      fi
      BACKEND=$2
      shift 2
      ;;
    --backend=*)
      BACKEND=${1#--backend=}
      shift
      ;;
    --claude)
      BACKEND=claude
      shift
      ;;
    --grok)
      BACKEND=grok
      shift
      ;;
    --codex)
      BACKEND=codex
      shift
      ;;
    --resume|-r)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --resume requires a session uuid" >&2
        exit 2
      fi
      RESUME=$2
      shift 2
      ;;
    --name|-n)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --name requires a label" >&2
        exit 2
      fi
      NAME=$2
      shift 2
      ;;
    -c|--continue)
      CONTINUE=1
      shift
      ;;
    --fork-session)
      FORK=1
      shift
      ;;
    --prompt-file)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "error: --prompt-file requires a path" >&2
        exit 2
      fi
      PROMPT_FILE=$2
      shift 2
      ;;
    --prompt-file=*)
      PROMPT_FILE=${1#--prompt-file=}
      shift
      ;;
    --)
      shift
      if [[ $# -lt 1 ]]; then
        echo "error: missing prompt after --" >&2
        exit 2
      fi
      PROMPT=$1
      shift
      EXTRA=("$@")
      break
      ;;
    -*)
      # --prompt-file stands in for the positional prompt, so leftover flags
      # are backend extras (--effort, --model, …).
      if [[ -n "$PROMPT_FILE" ]]; then
        EXTRA=("$@")
        break
      fi
      echo "error: unknown wrapper option: $1 (wrapper flags before prompt; backend flags after)" >&2
      echo "run: $0 --help" >&2
      exit 2
      ;;
    *)
      PROMPT=$1
      shift
      EXTRA=("$@")
      break
      ;;
  esac
done

if [[ "$LIST_SESSIONS" -eq 1 ]]; then
  if [[ ! -f "$REGISTRY" ]]; then
    echo "(no registry yet: $REGISTRY)" >&2
    exit 0
  fi
  tail -n 30 "$REGISTRY"
  exit 0
fi

if [[ "$SELF_TEST" -eq 1 ]]; then
  _got="$(_grok_effort_wire mid)"
  if [[ "$_got" != "medium" ]]; then
    echo "self-test: grok effort alias mid → medium failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_grok_effort_wire max)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: grok effort alias max → xhigh failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_grok_effort_wire maximum)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: grok effort alias maximum → xhigh failed (got ${_got})" >&2
    exit 1
  fi
  for _keep in medium high low xhigh; do
    _got="$(_grok_effort_wire "$_keep")"
    if [[ "$_got" != "$_keep" ]]; then
      echo "self-test: grok effort ${_keep} should pass through (got ${_got})" >&2
      exit 1
    fi
  done
  _got="$(_codex_effort_wire mid)"
  if [[ "$_got" != "medium" ]]; then
    echo "self-test: codex effort alias mid → medium failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_codex_effort_wire max)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: codex effort alias max → xhigh failed (got ${_got})" >&2
    exit 1
  fi
  for _keep in none minimal low medium high xhigh; do
    _got="$(_codex_effort_wire "$_keep")"
    if [[ "$_got" != "$_keep" ]]; then
      echo "self-test: codex effort ${_keep} should pass through (got ${_got})" >&2
      exit 1
    fi
  done
  _got="$(_claude_effort_wire max)"
  if [[ "$_got" != "max" ]]; then
    echo "self-test: claude effort max must stay max (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire maximum)"
  if [[ "$_got" != "max" ]]; then
    echo "self-test: claude effort alias maximum → max failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire mid)"
  if [[ "$_got" != "medium" ]]; then
    echo "self-test: claude effort alias mid → medium failed (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire xhigh)"
  if [[ "$_got" != "xhigh" ]]; then
    echo "self-test: claude effort xhigh must stay xhigh (got ${_got})" >&2
    exit 1
  fi
  _got="$(_claude_effort_wire high)"
  if [[ "$_got" != "high" ]]; then
    echo "self-test: claude effort high must stay high (got ${_got})" >&2
    exit 1
  fi
  _tmp=$(mktemp -d)
  cat > "$_tmp/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${GROK_ARGV_FILE:?}"
echo '{"type":"result","session_id":"00000000-0000-0000-0000-000000000000","result":"ok"}'
EOF
  chmod +x "$_tmp/grok"
  cat > "$_tmp/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CLAUDE_ARGV_FILE:?}"
echo '{"type":"result","session_id":"00000000-0000-0000-0000-000000000000","result":"ok"}'
EOF
  chmod +x "$_tmp/claude"
  cat > "$_tmp/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CODEX_ARGV_FILE:?}"
echo '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-00000000c0de"}'
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
EOF
  chmod +x "$_tmp/codex"
  GROK_ARGV_FILE="$_tmp/argv.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend grok "self-test mid alias" --effort mid >/dev/null
  if ! grep -qx 'medium' "$_tmp/argv.txt"; then
    echo "self-test: grok argv missing effort medium:" >&2
    cat "$_tmp/argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'mid' "$_tmp/argv.txt"; then
    echo "self-test: grok argv still has bare mid:" >&2
    cat "$_tmp/argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  echo "prompt-file self-test ok" > "$_tmp/p.md"
  GROK_ARGV_FILE="$_tmp/argv-file.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend grok --prompt-file "$_tmp/p.md" --effort high >/dev/null
  if ! grep -q 'prompt-file self-test ok' "$_tmp/argv-file.txt"; then
    echo "self-test: --prompt-file did not reach grok -p:" >&2
    cat "$_tmp/argv-file.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  GROK_ARGV_FILE="$_tmp/argv-max.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend grok "self-test max alias" --effort max >/dev/null
  if ! grep -qx 'xhigh' "$_tmp/argv-max.txt"; then
    echo "self-test: grok argv missing effort xhigh from max:" >&2
    cat "$_tmp/argv-max.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'max' "$_tmp/argv-max.txt"; then
    echo "self-test: grok argv still has bare max:" >&2
    cat "$_tmp/argv-max.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  CLAUDE_ARGV_FILE="$_tmp/claude-argv.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend claude --name self-test-max "self-test claude max" --model fable --effort max >/dev/null
  if ! grep -qx 'max' "$_tmp/claude-argv.txt"; then
    echo "self-test: claude argv missing effort max:" >&2
    cat "$_tmp/claude-argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'high' "$_tmp/claude-argv.txt"; then
    echo "self-test: claude --effort max was remapped to high:" >&2
    cat "$_tmp/claude-argv.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  CLAUDE_ARGV_FILE="$_tmp/claude-argv-maximum.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend claude --name self-test-maximum "self-test claude maximum" --model fable --effort maximum >/dev/null
  if ! grep -qx 'max' "$_tmp/claude-argv-maximum.txt"; then
    echo "self-test: claude argv missing effort max from maximum:" >&2
    cat "$_tmp/claude-argv-maximum.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qx 'maximum' "$_tmp/claude-argv-maximum.txt"; then
    echo "self-test: claude argv still has bare maximum:" >&2
    cat "$_tmp/claude-argv-maximum.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  # Codex: exec --json + bypass + effort → -c model_reasoning_effort, stdin closed.
  CODEX_ARGV_FILE="$_tmp/codex-argv.txt" \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    TOKENMAXXING_REQUIRE_SUPERVISOR=0 \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --backend codex --name self-test-codex "self-test codex mid" --model gpt-5.5 --effort mid --verbose >"$_tmp/codex-out.txt"
  for _want in exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      'model_reasoning_effort="medium"' gpt-5.5 'self-test codex mid'; do
    if ! grep -qxF -- "$_want" "$_tmp/codex-argv.txt"; then
      echo "self-test: codex argv missing ${_want}:" >&2
      cat "$_tmp/codex-argv.txt" >&2
      rm -rf "$_tmp"
      exit 1
    fi
  done
  for _bad in --effort mid --verbose --permission-mode --output-format --name resume; do
    if grep -qxF -- "$_bad" "$_tmp/codex-argv.txt"; then
      echo "self-test: codex argv still has ${_bad}:" >&2
      cat "$_tmp/codex-argv.txt" >&2
      rm -rf "$_tmp"
      exit 1
    fi
  done
  if ! grep -q 'session_id=00000000-0000-0000-0000-00000000c0de  backend=codex' "$_tmp/codex-out.txt"; then
    echo "self-test: codex formatter did not surface thread_id as session_id:" >&2
    cat "$_tmp/codex-out.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if ! grep -q '"backend": "codex"' "$_tmp/reg.jsonl"; then
    echo "self-test: registry missing backend=codex rows" >&2
    cat "$_tmp/reg.jsonl" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  # Codex auto-detect from --model gpt-* + resume → `codex exec resume <id> "…"`.
  CODEX_ARGV_FILE="$_tmp/codex-argv-resume.txt" \
    AGENT_HUMAN_STREAM_BACKEND=auto \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    TOKENMAXXING_REQUIRE_SUPERVISOR=0 \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --resume 00000000-0000-0000-0000-00000000c0de "self-test codex resume" --model gpt-5.5 --effort max >/dev/null
  if ! grep -qxF -- 'resume' "$_tmp/codex-argv-resume.txt"; then
    echo "self-test: codex --resume did not use exec resume:" >&2
    cat "$_tmp/codex-argv-resume.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if grep -qxF -- '--resume' "$_tmp/codex-argv-resume.txt"; then
    echo "self-test: codex argv has Claude-style --resume:" >&2
    cat "$_tmp/codex-argv-resume.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if ! grep -qxF -- '00000000-0000-0000-0000-00000000c0de' "$_tmp/codex-argv-resume.txt"; then
    echo "self-test: codex resume id missing from argv" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  if ! grep -qxF -- 'model_reasoning_effort="xhigh"' "$_tmp/codex-argv-resume.txt"; then
    echo "self-test: codex --effort max → xhigh failed:" >&2
    cat "$_tmp/codex-argv-resume.txt" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  # Registry-only resume (no --model) must pick backend=codex from the record.
  CODEX_ARGV_FILE="$_tmp/codex-argv-reg.txt" \
    AGENT_HUMAN_STREAM_BACKEND=auto \
    AGENT_HUMAN_STREAM_REGISTRY="$_tmp/reg.jsonl" \
    AGENT_HUMAN_STREAM_LIVE_DIR="$_tmp/live" \
    TOKENMAXXING_REQUIRE_SUPERVISOR=0 \
    PATH="$_tmp:$PATH" \
    "$SOURCE" --resume 00000000-0000-0000-0000-00000000c0de "self-test codex registry resume" >/dev/null
  if [[ ! -s "$_tmp/codex-argv-reg.txt" ]]; then
    echo "self-test: --resume did not route to codex from registry backend" >&2
    rm -rf "$_tmp"
    exit 1
  fi
  rm -rf "$_tmp"
  exec python3 "$ROOT/agent-human-stream.test.py"
fi

if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "error: --prompt-file not found: $PROMPT_FILE" >&2
    exit 2
  fi
  if [[ ! -s "$PROMPT_FILE" ]]; then
    echo "error: --prompt-file is empty: $PROMPT_FILE" >&2
    exit 2
  fi
  if [[ -n "$PROMPT" ]]; then
    echo "error: use either --prompt-file or a positional prompt, not both" >&2
    exit 2
  fi
  PROMPT=$(cat "$PROMPT_FILE")
  if [[ -z "$PROMPT" ]]; then
    echo "error: --prompt-file read empty: $PROMPT_FILE" >&2
    exit 2
  fi
fi

if [[ -z "$PROMPT" ]]; then
  echo "error: missing prompt" >&2
  echo "usage: $0 [--backend claude|grok|codex|auto] [--resume <uuid>|--continue] [--name <label>] (--prompt-file <path> | <prompt>) [backend args...]" >&2
  exit 2
fi

if [[ -n "$RESUME" && "$CONTINUE" -eq 1 ]]; then
  echo "error: use either --resume <uuid> or --continue, not both" >&2
  exit 2
fi

BACKEND=$(printf '%s' "$BACKEND" | tr '[:upper:]' '[:lower:]')
case "$BACKEND" in
  claude|grok|codex|auto) ;;
  *)
    echo "error: --backend must be claude, grok, codex, or auto (got: $BACKEND)" >&2
    exit 2
    ;;
esac

_has_effort=0
_resolved_model=""
_passed_effort=""
_has_output_format=0
_has_permission_mode=0
_has_always_approve=0
_has_sandbox=0
_i=0
while [[ $_i -lt ${#EXTRA[@]} ]]; do
  _a="${EXTRA[$_i]}"
  case "$_a" in
    --effort|--reasoning-effort)
      _has_effort=1
      _passed_effort="${EXTRA[$((_i + 1))]:-}"
      _i=$((_i + 2))
      continue
      ;;
    --effort=*|--reasoning-effort=*)
      _has_effort=1
      _passed_effort="${_a#*=}"
      _i=$((_i + 1))
      continue
      ;;
    --model|-m)
      _resolved_model="${EXTRA[$((_i + 1))]:-}"
      _i=$((_i + 2))
      continue
      ;;
    --model=*|-m=*)
      _resolved_model="${_a#*=}"
      _i=$((_i + 1))
      continue
      ;;
    --output-format)
      _has_output_format=1
      _i=$((_i + 2))
      continue
      ;;
    --output-format=*)
      _has_output_format=1
      _i=$((_i + 1))
      continue
      ;;
    --permission-mode)
      _has_permission_mode=1
      _i=$((_i + 2))
      continue
      ;;
    --permission-mode=*)
      _has_permission_mode=1
      _i=$((_i + 1))
      continue
      ;;
    --always-approve|--yolo)
      _has_always_approve=1
      _i=$((_i + 1))
      continue
      ;;
    --dangerously-bypass-approvals-and-sandbox|--full-auto|--sandbox|-s|--sandbox=*|-a|--ask-for-approval|--ask-for-approval=*)
      _has_sandbox=1
      _i=$((_i + 1))
      continue
      ;;
  esac
  _i=$((_i + 1))
done

lookup_session_field() {
  local sid="$1" field="$2"
  [[ -n "$sid" && -f "$REGISTRY" ]] || return 0
  python3 -c '
import json, sys
path, sid, field = sys.argv[1], sys.argv[2], sys.argv[3]
found = ""
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("session_id") == sid and rec.get(field):
                found = str(rec[field])
except OSError:
    pass
print(found)
' "$REGISTRY" "$sid" "$field"
}

if [[ -z "$_resolved_model" && -n "$RESUME" ]]; then
  _resolved_model=$(lookup_session_field "$RESUME" model)
fi

if [[ "$BACKEND" == "auto" && -n "$RESUME" ]]; then
  _reg_backend=$(lookup_session_field "$RESUME" backend)
  case "$_reg_backend" in
    claude|grok|codex) BACKEND=$_reg_backend ;;
  esac
fi

if [[ "$BACKEND" == "auto" ]]; then
  _model_lc=$(printf '%s' "${_resolved_model}" | tr '[:upper:]' '[:lower:]')
  case "$_model_lc" in
    grok|grok*|grok-*)
      BACKEND=grok
      ;;
    gpt|gpt-*|gpt*|o3|o3-*|o3*|o4|o4-*|o4*|codex|codex*)
      BACKEND=codex
      ;;
    opus|opus*|fable|fable*|sonnet|sonnet*|haiku|haiku*|claude|claude-*)
      BACKEND=claude
      ;;
    *)
      BACKEND=claude
      ;;
  esac
fi

_effort="$_passed_effort"
if [[ "$BACKEND" == "claude" && "$_has_effort" -eq 0 ]]; then
  _model_lc=$(printf '%s' "${_resolved_model:-opus}" | tr '[:upper:]' '[:lower:]')
  case "$_model_lc" in
    fable|fable*|claude-fable*)
      _effort="${CLAUDE_HUMAN_STREAM_EFFORT_FABLE:-${AGENT_HUMAN_STREAM_EFFORT_FABLE:-high}}"
      ;;
    *)
      _effort="${CLAUDE_HUMAN_STREAM_EFFORT_OPUS:-${AGENT_HUMAN_STREAM_EFFORT_OPUS:-medium}}"
      ;;
  esac
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for model=${_resolved_model:-opus}; override with --effort)" >&2
elif [[ "$BACKEND" == "grok" && "$_has_effort" -eq 0 ]]; then
  _effort="$(_grok_effort_wire "${AGENT_HUMAN_STREAM_EFFORT_GROK:-xhigh}")"
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for grok code lane; research → --effort medium)" >&2
elif [[ "$BACKEND" == "codex" && "$_has_effort" -eq 0 ]]; then
  _effort="$(_codex_effort_wire "${AGENT_HUMAN_STREAM_EFFORT_CODEX:-high}")"
  EXTRA+=(--effort "$_effort")
  echo "effort: ${_effort} (default for codex code lane; research → --effort medium)" >&2
fi

# Claude: rewrite desk aliases so --effort max/xhigh reach the CLI as-is.
if [[ "$BACKEND" == "claude" && ${#EXTRA[@]} -gt 0 ]]; then
  _filtered=()
  _i=0
  while [[ $_i -lt ${#EXTRA[@]} ]]; do
    _a="${EXTRA[$_i]}"
    case "$_a" in
      --effort|--reasoning-effort)
        _val="${EXTRA[$((_i + 1))]:-}"
        _wire="$(_claude_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping claude --effort ${_val} → ${_wire} (Claude Code enum)" >&2
        fi
        _filtered+=("$_a" "$_wire")
        _effort="$_wire"
        _i=$((_i + 2))
        continue
        ;;
      --effort=*|--reasoning-effort=*)
        _flag="${_a%%=*}"
        _val="${_a#*=}"
        _wire="$(_claude_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping claude --effort ${_val} → ${_wire} (Claude Code enum)" >&2
        fi
        _filtered+=("${_flag}=${_wire}")
        _effort="$_wire"
        _i=$((_i + 1))
        continue
        ;;
    esac
    _filtered+=("$_a")
    _i=$((_i + 1))
  done
  EXTRA=("${_filtered[@]+"${_filtered[@]}"}")
fi

# Grok does not accept Claude-only --verbose / stream-json name.
if [[ "$BACKEND" == "grok" && ${#EXTRA[@]} -gt 0 ]]; then
  _filtered=()
  _i=0
  while [[ $_i -lt ${#EXTRA[@]} ]]; do
    _a="${EXTRA[$_i]}"
    case "$_a" in
      --verbose)
        echo "note: dropping --verbose (Claude-only) for grok" >&2
        _i=$((_i + 1))
        continue
        ;;
      --output-format)
        _fmt="${EXTRA[$((_i + 1))]:-}"
        if [[ "$_fmt" == "stream-json" ]]; then
          _fmt="streaming-messages-json"
          echo "note: mapping --output-format stream-json → streaming-messages-json" >&2
        fi
        _filtered+=(--output-format "$_fmt")
        _i=$((_i + 2))
        continue
        ;;
      --output-format=stream-json)
        _filtered+=(--output-format streaming-messages-json)
        echo "note: mapping --output-format stream-json → streaming-messages-json" >&2
        _i=$((_i + 1))
        continue
        ;;
      --effort|--reasoning-effort)
        _val="${EXTRA[$((_i + 1))]:-}"
        _wire="$(_grok_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping grok --effort ${_val} → ${_wire} (Grok CLI enum)" >&2
        fi
        _filtered+=("$_a" "$_wire")
        _effort="$_wire"
        _i=$((_i + 2))
        continue
        ;;
      --effort=*|--reasoning-effort=*)
        _flag="${_a%%=*}"
        _val="${_a#*=}"
        _wire="$(_grok_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping grok --effort ${_val} → ${_wire} (Grok CLI enum)" >&2
        fi
        _filtered+=("${_flag}=${_wire}")
        _effort="$_wire"
        _i=$((_i + 1))
        continue
        ;;
    esac
    _filtered+=("$_a")
    _i=$((_i + 1))
  done
  EXTRA=("${_filtered[@]+"${_filtered[@]}"}")
fi

# Codex: no --effort / --verbose / --permission-mode / --output-format flags.
# --effort becomes the config override -c model_reasoning_effort="…".
if [[ "$BACKEND" == "codex" && ${#EXTRA[@]} -gt 0 ]]; then
  _filtered=()
  _i=0
  while [[ $_i -lt ${#EXTRA[@]} ]]; do
    _a="${EXTRA[$_i]}"
    case "$_a" in
      --verbose|--always-approve|--yolo|--no-auto-update|--fork-session)
        echo "note: dropping ${_a} (not a codex exec flag)" >&2
        _i=$((_i + 1))
        continue
        ;;
      --output-format|--permission-mode|--name|--max-turns)
        echo "note: dropping ${_a} ${EXTRA[$((_i + 1))]:-} (not a codex exec flag)" >&2
        _i=$((_i + 2))
        continue
        ;;
      --output-format=*|--permission-mode=*|--name=*|--max-turns=*)
        echo "note: dropping ${_a} (not a codex exec flag)" >&2
        _i=$((_i + 1))
        continue
        ;;
      --effort|--reasoning-effort)
        _val="${EXTRA[$((_i + 1))]:-}"
        _wire="$(_codex_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping codex --effort ${_val} → ${_wire} (model_reasoning_effort enum)" >&2
        fi
        _filtered+=(-c "model_reasoning_effort=\"${_wire}\"")
        _effort="$_wire"
        _i=$((_i + 2))
        continue
        ;;
      --effort=*|--reasoning-effort=*)
        _val="${_a#*=}"
        _wire="$(_codex_effort_wire "$_val")"
        if [[ "$_wire" != "$_val" ]]; then
          echo "note: mapping codex --effort ${_val} → ${_wire} (model_reasoning_effort enum)" >&2
        fi
        _filtered+=(-c "model_reasoning_effort=\"${_wire}\"")
        _effort="$_wire"
        _i=$((_i + 1))
        continue
        ;;
      --model=*)
        _filtered+=(-m "${_a#*=}")
        _i=$((_i + 1))
        continue
        ;;
      --model)
        _filtered+=(-m "${EXTRA[$((_i + 1))]:-}")
        _i=$((_i + 2))
        continue
        ;;
    esac
    _filtered+=("$_a")
    _i=$((_i + 1))
  done
  EXTRA=("${_filtered[@]+"${_filtered[@]}"}")
fi

# Codex must be the tokenmaxxing supervisor when this desk has one. Hard-fail
# only when TOKENMAXXING_REQUIRE_SUPERVISOR=1 or when ~/.config/tokenmaxxing
# has a codex shim that PATH does not pick first (PATH order bug).
_codex_supervisor_check() {
  local real shim="$HOME/.config/tokenmaxxing/bin/codex"
  real=$(command -v codex 2>/dev/null || true)
  if [[ -z "$real" ]]; then
    echo "error: codex not on PATH (want tokenmaxxing supervisor on this desk: tokenmaxxing init --codex)" >&2
    exit 127
  fi
  case "$real" in
    */.config/tokenmaxxing/bin/codex) return 0 ;;
  esac
  if [[ "${TOKENMAXXING_REQUIRE_SUPERVISOR:-0}" == "1" ]]; then
    echo "error: codex resolves to ${real}, not the tokenmaxxing supervisor (TOKENMAXXING_REQUIRE_SUPERVISOR=1)" >&2
    exit 127
  fi
  if [[ -x "$shim" ]]; then
    if [[ "${TOKENMAXXING_REQUIRE_SUPERVISOR:-}" == "0" ]]; then
      echo "note: codex is ${real}, not ${shim} (TOKENMAXXING_REQUIRE_SUPERVISOR=0 bypass)" >&2
      return 0
    fi
    echo "error: ${shim} exists but PATH picks ${real} first. Put ~/.config/tokenmaxxing/bin ahead (tokenmaxxing doctor)." >&2
    echo "       TOKENMAXXING_REQUIRE_SUPERVISOR=0 to bypass on purpose." >&2
    exit 127
  else
    echo "note: codex is ${real} (no tokenmaxxing codex pool on this machine)" >&2
  fi
}

CMD=()
if [[ "$BACKEND" == "codex" ]]; then
  _codex_supervisor_check
  if [[ "$FORK" -eq 1 ]]; then
    echo "error: --fork-session is not supported by codex exec (resume appends to the thread)" >&2
    exit 2
  fi
  CMD=(codex exec)
  if [[ -n "$RESUME" || "$CONTINUE" -eq 1 ]]; then
    CMD+=(resume)
  fi
  CMD+=(--json --skip-git-repo-check)
  if [[ "$_has_sandbox" -eq 0 ]]; then
    CMD+=(--dangerously-bypass-approvals-and-sandbox)
  fi
  CMD+=("${EXTRA[@]+"${EXTRA[@]}"}")
  if [[ -n "$RESUME" ]]; then
    CMD+=("$RESUME")
  elif [[ "$CONTINUE" -eq 1 ]]; then
    CMD+=(--last)
  fi
  CMD+=("$PROMPT")
elif [[ "$BACKEND" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "error: claude not on PATH (want tokenmaxxing supervisor on this desk)" >&2
    exit 127
  fi
  CMD=(claude -p "$PROMPT" --output-format stream-json --verbose)
  if [[ "$_has_permission_mode" -eq 0 ]]; then
    CMD+=(--permission-mode bypassPermissions)
  fi
else
  if ! command -v grok >/dev/null 2>&1; then
    echo "error: grok not on PATH. Install Grok Build: curl -fsSL https://x.ai/cli/install.sh | bash" >&2
    exit 127
  fi
  CMD=(grok -p "$PROMPT")
  if [[ "$_has_output_format" -eq 0 ]]; then
    CMD+=(--output-format streaming-messages-json)
  fi
  if [[ "$_has_permission_mode" -eq 0 ]]; then
    CMD+=(--permission-mode bypassPermissions)
  fi
  if [[ "$_has_always_approve" -eq 0 ]]; then
    CMD+=(--always-approve)
  fi
  CMD+=(--no-auto-update)
fi

if [[ "$BACKEND" != "codex" ]]; then
  if [[ -n "$RESUME" ]]; then
    CMD+=(--resume "$RESUME")
  fi
  if [[ "$CONTINUE" -eq 1 ]]; then
    CMD+=(--continue)
  fi
  if [[ "$FORK" -eq 1 ]]; then
    CMD+=(--fork-session)
  fi
  # Claude /resume picker; Grok/Codex have no --name display flag — logs only.
  if [[ -n "$NAME" && "$BACKEND" == "claude" ]]; then
    CMD+=(--name "$NAME")
  fi
  CMD+=("${EXTRA[@]+"${EXTRA[@]}"}")
fi

PROMPT_HEAD=$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-200)

export AGENT_HUMAN_STREAM_BACKEND="$BACKEND"
export AGENT_HUMAN_STREAM_MODEL="${_resolved_model:-}"
export AGENT_HUMAN_STREAM_EFFORT="${_effort:-}"
export AGENT_HUMAN_STREAM_PROMPT_HEAD="$PROMPT_HEAD"
export AGENT_HUMAN_STREAM_NAME="$NAME"
export AGENT_HUMAN_STREAM_REGISTRY="$REGISTRY"
export AGENT_HUMAN_STREAM_PID="$$"
export AGENT_HUMAN_STREAM_CWD="$PWD"
export AGENT_HUMAN_STREAM_RESUME_FROM="${RESUME:-}"
if [[ "$CONTINUE" -eq 1 ]]; then
  export AGENT_HUMAN_STREAM_RESUME_FROM="${AGENT_HUMAN_STREAM_RESUME_FROM:-continue}"
fi
# Legacy names so a leftover claude-human-stream.py still tees correctly.
export CLAUDE_HUMAN_STREAM_BACKEND="$BACKEND"
export CLAUDE_HUMAN_STREAM_MODEL="$AGENT_HUMAN_STREAM_MODEL"
export CLAUDE_HUMAN_STREAM_EFFORT="$AGENT_HUMAN_STREAM_EFFORT"
export CLAUDE_HUMAN_STREAM_PROMPT_HEAD="$PROMPT_HEAD"
export CLAUDE_HUMAN_STREAM_NAME="$NAME"
export CLAUDE_HUMAN_STREAM_REGISTRY="$REGISTRY"
export CLAUDE_HUMAN_STREAM_PID="$$"
export CLAUDE_HUMAN_STREAM_CWD="$PWD"
export CLAUDE_HUMAN_STREAM_RESUME_FROM="$AGENT_HUMAN_STREAM_RESUME_FROM"

mkdir -p "$LIVE_DIR"
LIVE_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LIVE_LABEL="${NAME:-$BACKEND}"
LIVE_LABEL=${LIVE_LABEL//[^a-zA-Z0-9._-]/_}
if [[ -n "$RESUME" ]]; then
  LIVE_LABEL="${LIVE_LABEL}-resume-${RESUME:0:8}"
fi
LIVE_LOG="$LIVE_DIR/${LIVE_STAMP}-${LIVE_LABEL}.log"
: >"$LIVE_LOG"
ln -sfn "$LIVE_LOG" "$LIVE_DIR/LATEST.log"
export AGENT_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"
export CLAUDE_HUMAN_STREAM_LIVE_LOG="$LIVE_LOG"

mkdir -p "$(dirname "$REGISTRY")"
python3 - <<'PY' || true
import json, os, time
path = os.environ["AGENT_HUMAN_STREAM_REGISTRY"]
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "event": "start",
    "backend": os.environ.get("AGENT_HUMAN_STREAM_BACKEND") or None,
    "session_id": None,
    "cwd": os.environ.get("AGENT_HUMAN_STREAM_CWD") or os.getcwd(),
    "name": os.environ.get("AGENT_HUMAN_STREAM_NAME") or None,
    "prompt_head": os.environ.get("AGENT_HUMAN_STREAM_PROMPT_HEAD") or None,
    "pid": int(os.environ.get("AGENT_HUMAN_STREAM_PID") or "0") or None,
    "resume_from": os.environ.get("AGENT_HUMAN_STREAM_RESUME_FROM") or None,
    "live_log": os.environ.get("AGENT_HUMAN_STREAM_LIVE_LOG") or None,
    "model": os.environ.get("AGENT_HUMAN_STREAM_MODEL") or None,
    "effort": os.environ.get("AGENT_HUMAN_STREAM_EFFORT") or None,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY

echo "backend: $BACKEND" >&2
echo "👁 live_log: $LIVE_LOG" >&2
echo "👁 watch:    tail -f $(printf %q "$LIVE_LOG")" >&2
echo "👁 latest:   tail -f $(printf %q "$LIVE_DIR/LATEST.log")" >&2

if [[ "$BACKEND" == "codex" ]]; then
  # codex exec appends piped stdin to the prompt and blocks on a non-tty
  # stdin (background Shells) — always close it.
  "${CMD[@]}" </dev/null | python3 -u "$ROOT/agent-human-stream.py"
else
  "${CMD[@]}" | python3 -u "$ROOT/agent-human-stream.py"
fi
