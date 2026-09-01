#!/usr/bin/env bash
# One-click: durable SoT at ~/.cstack/src, then install.
#   curl -fsSL https://raw.githubusercontent.com/chasehuh/cstack/main/bootstrap.sh \
#     | bash -s -- --sume-com ~/sume/sume-com
#   # or, from a clone: ./bootstrap.sh --sume-com ~/sume/sume-com
set -euo pipefail

DEST="${CSTACK_SRC:-$HOME/.cstack/src}"
REPO="${CSTACK_REPO:-git@github.com:chasehuh/cstack.git}"

if [ -L "$DEST" ]; then
  echo "bootstrap: replacing symlink $DEST with a real clone"
  rm -f "$DEST"
fi

if [ -d "$DEST/.git" ]; then
  echo "bootstrap: updating $DEST"
  git -C "$DEST" pull --ff-only
else
  if [ -e "$DEST" ]; then
    echo "bootstrap: $DEST exists and is not a git repo" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$DEST")"
  echo "bootstrap: cloning $REPO → $DEST"
  git clone "$REPO" "$DEST"
fi

exec "$DEST/install.sh" "$@"
