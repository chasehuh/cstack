#!/usr/bin/env bash
# Regenerate references/ from an upstream pstack checkout (MIT, Lauren Tan).
# Each upstream file gets exactly two edits: its YAML frontmatter is dropped
# (these are references, not skills) and links between pstack skills are
# pointed at sibling files. Provenance and the upstream pin: docs/PSTACK.md.
#
# Usage: sync-from-pstack.sh <cursor/plugins checkout>/pstack
set -euo pipefail

src="${1:?usage: sync-from-pstack.sh <cursor/plugins checkout>/pstack}"
dest="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/references"
[ -d "$src/skills/principle-prove-it-works" ] || {
  echo "not a pstack checkout: $src" >&2
  exit 2
}
mkdir -p "$dest"
# Converge on upstream: a principle renamed or removed upstream must not
# linger here.
find "$dest" -maxdepth 1 -name '*.md' -delete

vendor() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next }
       fm { if ($0 == "---") fm = 0; next }
       !body && $0 == "" { next }
       { body = 1; print }' "$1" |
    sed -E 's#\.\./principle-([a-z-]+)/SKILL\.md#\1.md#g;
            s#\.\./benchmark-checklist/SKILL\.md#benchmark-checklist.md#g' \
      > "$2"
}

for dir in "$src"/skills/principle-*/; do
  name="$(basename "$dir")"
  vendor "$dir/SKILL.md" "$dest/${name#principle-}.md"
done
vendor "$src/skills/benchmark-checklist/SKILL.md" "$dest/benchmark-checklist.md"

if grep -n '](\.\./' "$dest"/*.md; then
  echo "links above point at pstack skills this desk does not vendor; adapt them" >&2
  exit 1
fi
echo "synced $(find "$dest" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') files into $dest"
