#!/usr/bin/env bash
# Install the Sume desk flow onto this machine so any agent follows it.
# Real SoT is this checkout of chasehuh/cstack (pointed at ~/.cstack/src).
# Usage:
#   ./install.sh
#   ./install.sh --sume-com /path/to/sume-com
# One-click refresh:
#   ./bootstrap.sh --sume-com ~/sume/sume-com
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

mkdir -p "$HOME/.cstack/state"
# Machine SoT: prefer a real clone at ~/.cstack/src. Never ln -sfn a
# directory onto itself (that replaces the clone with a broken symlink).
CANON="$HOME/.cstack/src"
ROOT_REAL="$(cd "$ROOT" && pwd)"
if [ -d "$CANON/.git" ] && [ "$(cd "$CANON" && pwd)" = "$ROOT_REAL" ]; then
  echo "SoT checkout is $CANON"
elif [ -e "$CANON" ] && [ ! -L "$CANON" ] && [ -d "$CANON/.git" ]; then
  echo "NOTE: $CANON is a real clone; not retargeting it to $ROOT_REAL"
  echo "      Re-run $CANON/install.sh (or ./bootstrap.sh) to publish that tree."
else
  ln -sfn "$ROOT_REAL" "$CANON"
  echo "SoT pointer: ~/.cstack/src → $ROOT_REAL"
fi

# Move wrapper logs out of the skill tree before we replace rsync copies
# with symlinks into the git checkout.
OLD_STATE="$HOME/.agents/skills/sume-main-agent-orchestration/state"
if [ -d "$OLD_STATE" ] && [ ! -L "$HOME/.agents/skills/sume-main-agent-orchestration" ]; then
  rsync -a "$OLD_STATE/" "$HOME/.cstack/state/"
  echo "migrated runtime state → ~/.cstack/state"
fi

link_skill() {
  local name="$1"
  local src="$DESK/skills/$name"
  local dest="$HOME/.agents/skills/$name"
  [ -d "$src" ] || return 0
  mkdir -p "$HOME/.agents/skills"
  if [ -L "$dest" ]; then
    ln -sfn "$src" "$dest"
  elif [ -d "$dest" ]; then
    rm -rf "$dest"
    ln -sfn "$src" "$dest"
  else
    ln -sfn "$src" "$dest"
  fi
  echo "skill SoT: $dest → $src"
  for harness in "$HOME/.cursor/skills" "$HOME/.claude/skills" \
                 "$HOME/.codex/skills" "$HOME/.grok/skills"; do
    mkdir -p "$harness"
    ln -sfn "$src" "$harness/$name"
    echo "linked: $harness/$name"
  done
}

echo "== skills (symlink → cstack, not rsync copy) =="
link_skill sume-main-agent-orchestration
link_skill sume-gt-mq
link_skill github-mega-issue
link_skill mobidoo-live-commerce-update

echo "== user Cursor rules =="
mkdir -p "$HOME/.cursor/rules"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$DESK/cursor-rules/user/" "$HOME/.cursor/rules/"
else
  cp -a "$DESK/cursor-rules/user/." "$HOME/.cursor/rules/"
fi
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
  # Refresh pointer copies that already live in the product checkout.
  # sume-com is not SoT — these stay in sync with cstack when present.
  for f in graphite-ci-ready.mdc sume-chase-work-loop.mdc \
           opus-background-terminal.mdc main-agent-orchestration.mdc; do
    if [ -f "$SUME_COM/.cursor/rules/$f" ] && [ -f "$DESK/cursor-rules/user/$f" ]; then
      cp "$DESK/cursor-rules/user/$f" "$SUME_COM/.cursor/rules/$f"
    fi
  done
  "$HOME/.agents/skills/sume-main-agent-orchestration/install-cursor-rule.sh" "$SUME_COM"
fi

echo "== host bins on PATH =="
mkdir -p "$HOME/.local/bin"
BIN="$HOME/.agents/skills/sume-main-agent-orchestration/bin"
GTBIN="$HOME/.agents/skills/sume-gt-mq/bin"
ln -sfn "$BIN/agent-human-stream.sh" "$HOME/.local/bin/agent-human-stream"
ln -sfn "$BIN/claude-human-stream.sh" "$HOME/.local/bin/claude-human-stream"
ln -sfn "$BIN/sume-bg-launch.sh" "$HOME/.local/bin/sume-bg-launch"
ln -sfn "$GTBIN/cstack-clone.sh" "$HOME/.local/bin/cstack-clone"
ln -sfn "$GTBIN/cstack-clone-rm.sh" "$HOME/.local/bin/cstack-clone-rm"
ln -sfn "$GTBIN/cstack-mirror-sync.sh" "$HOME/.local/bin/cstack-mirror-sync"
ln -sfn "$GTBIN/cstack-gt-wait-merge.sh" "$HOME/.local/bin/cstack-gt-wait-merge"
chmod +x "$BIN/agent-human-stream.sh" "$BIN/agent-human-stream.py" \
  "$BIN/agent-human-stream.test.py" \
  "$BIN/claude-human-stream.sh" "$BIN/claude-human-stream.py" \
  "$BIN/sume-bg-launch.sh" \
  "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" \
  "$HOME/.agents/skills/sume-gt-mq/install-symlinks.sh" \
  "$GTBIN/cstack-clone.sh" "$GTBIN/cstack-clone-rm.sh" \
  "$GTBIN/cstack-mirror-sync.sh" "$GTBIN/cstack-gt-wait-merge.sh" \
  "$GTBIN/cstack-gt-wait-merge.test.sh" \
  "$ROOT/bootstrap.sh" || true
if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  echo "NOTE: add \$HOME/.local/bin to PATH (e.g. in ~/.zshrc)"
fi

# Codex owns the full pointer snippet; Claude Code imports it via
# `@~/.codex/AGENTS.md` (check-wiring.sh asserts that import exists).
append_entry() {
  local f="$1" snip="$2" marker="$3"
  [ -f "$snip" ] || return 0
  mkdir -p "$(dirname "$f")"
  touch "$f"
  if ! grep -q "$marker" "$f"; then
    echo "" >> "$f"
    cat "$snip" >> "$f"
    echo "appended pointer: $f"
  fi
}
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/codex-agents-snippet.md" \
  "sume-main-agent-orchestration/SKILL.md"
append_entry "$HOME/.claude/CLAUDE.md" \
  "$ROOT/sume-desk/claude-import-snippet.md" \
  "codex/AGENTS.md"
append_entry "$HOME/.grok/AGENTS.md" \
  "$ROOT/sume-desk/grok-agents-snippet.md" \
  "sume-main-agent-orchestration/SKILL.md"

# Existing snippets keep the old marker, so append the wait cook if missing.
ensure_wait_hint() {
  local f="$1"
  [ -f "$f" ] || return 0
  if ! grep -q "cstack-gt-wait-merge" "$f"; then
    printf '\nAfter `gt submit` on sume-com, run `cstack-gt-wait-merge` (do not hand-roll a sleep/grep loop).\n' >> "$f"
    echo "updated wait hint: $f"
  fi
}
ensure_wait_hint "$HOME/.codex/AGENTS.md"
ensure_wait_hint "$HOME/.claude/CLAUDE.md"
ensure_wait_hint "$HOME/.grok/AGENTS.md"

if [ -x "$GTBIN/cstack-gt-wait-merge.test.sh" ]; then
  echo "== cstack-gt-wait-merge matcher =="
  "$GTBIN/cstack-gt-wait-merge.test.sh"
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

if [ -x "$HOME/.local/bin/cstack-mirror-sync" ]; then
  echo "== cstack mirror (sume-com objects) =="
  "$HOME/.local/bin/cstack-mirror-sync" || echo "NOTE: seed later with cstack-mirror-sync"
fi

echo ""
echo "Installed. SoT is chasehuh/cstack (this checkout), not a rsync fork."
echo "pointer: ~/.cstack/src"
echo "policy:  ~/.agents/skills/sume-main-agent-orchestration/SKILL.md"
echo "gt:      ~/.agents/skills/sume-gt-mq/SKILL.md"
echo "wait:    cstack-gt-wait-merge  (label tip merge-queue now; MWR if CI pending)"
echo "clone:   cstack-clone / cstack-clone-rm / cstack-mirror-sync"
echo "state:   ~/.cstack/state/opus-live"
echo "harness: Cursor + Claude Code + Codex + Grok Build (~/.grok/skills)"
echo "LC:      ~/.agents/skills/mobidoo-live-commerce-update/SKILL.md"
echo "Claude:  docs/TOKENMAXXING.md (tokenmaxxing pool, not a single login)"
echo "Do not copy API keys / PEMs / tokenmaxxing accounts.json into this repo."
