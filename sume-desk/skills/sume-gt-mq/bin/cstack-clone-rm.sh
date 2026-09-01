#!/usr/bin/env bash
# Remove a job clone made by cstack-clone. Does not touch the bare mirror.
# Usage: cstack-clone-rm <job-slug>
set -euo pipefail

CLONE_ROOT="${CSTACK_CLONE_ROOT:-/tmp}"
PREFIX="${CSTACK_CLONE_PREFIX:-sume-com}"

[ $# -eq 1 ] || {
  echo "usage: cstack-clone-rm <job-slug>" >&2
  exit 2
}
SLUG="$1"
DEST="$CLONE_ROOT/$PREFIX-$SLUG"

if [ ! -e "$DEST" ]; then
  echo "cstack-clone-rm: missing $DEST" >&2
  exit 0
fi

# Refuse if a process has this directory as cwd (live worker).
if command -v lsof >/dev/null 2>&1; then
  if lsof -a -d cwd 2>/dev/null | grep -qF "$DEST"; then
    echo "cstack-clone-rm: in use (cwd) $DEST — not deleting" >&2
    exit 3
  fi
fi

rm -rf "$DEST"
echo "cstack-clone-rm: removed $DEST" >&2
