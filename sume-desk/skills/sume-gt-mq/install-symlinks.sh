#!/usr/bin/env bash
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for dest in "$HOME/.cursor/skills" "$HOME/.claude/skills" \
            "$HOME/.codex/skills" "$HOME/.grok/skills"; do
  mkdir -p "$dest"
  ln -sfn "$SKILL_DIR" "$dest/sume-gt-mq"
  echo "linked: $dest/sume-gt-mq"
done
