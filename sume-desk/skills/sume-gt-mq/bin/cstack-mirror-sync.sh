#!/usr/bin/env bash
# Refresh ~/.cstack/mirrors/sume-com.git (or CSTACK_MIRROR_ROOT).
# Wrapper around `cstack-clone --sync-only`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/cstack-clone.sh" --sync-only
