#!/usr/bin/env bash
# Install the pointer rule that makes Cursor read the shared orchestration SoT.
# Usage:
#   install-cursor-rule.sh --user              # ~/.cursor/rules/
#   install-cursor-rule.sh <repo-path>...     # <repo>/.cursor/rules/
#   install-cursor-rule.sh --user <repo>...   # both
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SKILL_DIR/cursor-rule-template.mdc"

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") [--user] [<repo-path>...]" >&2
  exit 2
fi

install_one() {
  local dest_dir="$1"
  local dest="$dest_dir/main-agent-orchestration.mdc"
  mkdir -p "$dest_dir"
  cp "$TEMPLATE" "$dest"
  echo "installed: $dest"
}

for arg in "$@"; do
  if [ "$arg" = "--user" ]; then
    install_one "$HOME/.cursor/rules"
    continue
  fi
  if [ ! -d "$arg" ]; then
    echo "skip (not a directory): $arg" >&2
    continue
  fi
  install_one "$arg/.cursor/rules"
done
