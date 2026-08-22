#!/usr/bin/env bash
# Install the Sume desk flow onto this machine so any agent follows it.
# Usage:
#   ./install.sh
#   ./install.sh --sume-com /path/to/sume-com
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK="$ROOT/sume-desk"
SUME_COM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sume-com)
      SUME_COM="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--sume-com <path>]" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$DESK/skills/sume-main-agent-orchestration" ]; then
  echo "missing pack: $DESK/skills/sume-main-agent-orchestration" >&2
  exit 1
fi

link_skill() {
  local name="$1"
  local src="$DESK/skills/$name"
  [ -d "$src" ] || return 0
  mkdir -p "$HOME/.agents/skills"
  # Sync pack files without wiping local runtime state/ (opus-live logs, sessions).
  mkdir -p "$HOME/.agents/skills/$name"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude state/ "$src/" "$HOME/.agents/skills/$name/"
  else
    # cp fallback: refresh tracked files, keep state/
    find "$HOME/.agents/skills/$name" -mindepth 1 -maxdepth 1 ! -name state -exec rm -rf {} +
    cp -a "$src/." "$HOME/.agents/skills/$name/"
  fi
  for dest in "$HOME/.cursor/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    mkdir -p "$dest"
    ln -sfn "$HOME/.agents/skills/$name" "$dest/$name"
    echo "linked: $dest/$name"
  done
}

echo "== skills =="
link_skill sume-main-agent-orchestration
link_skill sume-gt-mq
link_skill github-mega-issue

echo "== user Cursor rules =="
mkdir -p "$HOME/.cursor/rules"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$DESK/cursor-rules/user/" "$HOME/.cursor/rules/"
else
  cp -a "$DESK/cursor-rules/user/." "$HOME/.cursor/rules/"
fi
# Keep pointer template in sync with the installed skill
if [ -x "$HOME/.agents/skills/sume-main-agent-orchestration/install-cursor-rule.sh" ]; then
  "$HOME/.agents/skills/sume-main-agent-orchestration/install-cursor-rule.sh" --user
fi

if [ -n "$SUME_COM" ]; then
  echo "== sume-com repo rules → $SUME_COM =="
  mkdir -p "$SUME_COM/.cursor/rules"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$DESK/cursor-rules/sume-com/" "$SUME_COM/.cursor/rules/"
  else
    cp -a "$DESK/cursor-rules/sume-com/." "$SUME_COM/.cursor/rules/"
  fi
  "$HOME/.agents/skills/sume-main-agent-orchestration/install-cursor-rule.sh" "$SUME_COM"
fi

echo "== claude-human-stream on PATH =="
mkdir -p "$HOME/.local/bin"
ln -sfn "$HOME/.agents/skills/sume-main-agent-orchestration/bin/claude-human-stream.sh" \
  "$HOME/.local/bin/claude-human-stream"
chmod +x "$HOME/.agents/skills/sume-main-agent-orchestration/bin/claude-human-stream.sh" \
  "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" \
  "$HOME/.agents/skills/sume-gt-mq/install-symlinks.sh" || true
if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  echo "NOTE: add \$HOME/.local/bin to PATH (e.g. in ~/.zshrc)"
fi

SNIP_FILE="$ROOT/sume-desk/codex-agents-snippet.md"
if [ -f "$SNIP_FILE" ]; then
  for f in "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md"; do
    mkdir -p "$(dirname "$f")"
    touch "$f"
    if ! grep -q "sume-main-agent-orchestration/SKILL.md" "$f"; then
      echo "" >> "$f"
      cat "$SNIP_FILE" >> "$f"
      echo "appended pointer: $f"
    fi
  done
fi

if [ -x "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" ]; then
  echo "== wiring check =="
  "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" || true
fi

echo ""
echo "== tokenmaxxing (local Claude supervisor) =="
if command -v tokenmaxxing >/dev/null 2>&1; then
  tokenmaxxing doctor || true
  echo "Claude workers use tokenmaxxing — see docs/TOKENMAXXING.md"
else
  echo "NOTE: tokenmaxxing not on PATH. Opus/Fable expect the supervisor"
  echo "      (~/.config/tokenmaxxing/bin ahead of real claude)."
  echo "      Install: bun add -g tokenmaxxing && tokenmaxxing init"
  echo "      Docs: $ROOT/docs/TOKENMAXXING.md"
fi

echo ""
echo "Installed. Next: open sume-com in Cursor and read AGENTS.md in this repo."
echo "SoT: ~/.agents/skills/sume-main-agent-orchestration/SKILL.md"
echo "gt:  ~/.agents/skills/sume-gt-mq/SKILL.md"
echo "Claude: docs/TOKENMAXXING.md (tokenmaxxing pool, not a single login)"
echo "Do not copy API keys / PEMs / tokenmaxxing accounts.json into this repo."
