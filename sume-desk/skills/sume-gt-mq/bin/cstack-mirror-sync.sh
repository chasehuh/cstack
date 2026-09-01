#!/usr/bin/env bash
# Refresh ~/.cstack/mirrors/sume-com.git (or CSTACK_MIRROR_ROOT).
# Wrapper around `cstack-clone --sync-only`.
set -euo pipefail
if command -v cstack-clone >/dev/null 2>&1; then
  exec cstack-clone --sync-only
fi
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in
    /*) ;;
    *) SOURCE="$DIR/$SOURCE" ;;
  esac
done
HERE="$(cd "$(dirname "$SOURCE")" && pwd)"
exec "$HERE/cstack-clone.sh" --sync-only
