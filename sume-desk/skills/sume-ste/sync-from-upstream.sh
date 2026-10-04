#!/usr/bin/env bash
# Copy the upstream Simplified Technical English skill into this folder,
# byte for byte. SKILL.md here is the desk wrapper; the upstream SKILL.md
# lands as STE-SKILL.md. Provenance and the upstream pin: docs/STE.md.
#
# Usage: sync-from-upstream.sh <checkout of 0xpili/simplified-technical-english>
set -euo pipefail

src="${1:?usage: sync-from-upstream.sh <simplified-technical-english checkout>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$src/scripts/ste_check.py" ] || { echo "not an STE checkout: $src" >&2; exit 2; }

rm -rf "$here/references" "$here/examples" "$here/scripts"
mkdir -p "$here/references" "$here/examples" "$here/scripts"
cp "$src"/references/*.md "$here/references/"
cp "$src"/examples/*.md "$here/examples/"
cp "$src"/scripts/ste_check.py "$here/scripts/"
chmod +x "$here/scripts/ste_check.py"
cp "$src/SKILL.md" "$here/STE-SKILL.md"
cp "$src/NOTICE.md" "$here/NOTICE.md"
cp "$src/LICENSE" "$here/LICENSE"
echo "synced $(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown) into $here"
