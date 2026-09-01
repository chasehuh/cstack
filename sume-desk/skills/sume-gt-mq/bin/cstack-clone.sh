#!/usr/bin/env bash
# Isolated sume-com clone for every `gt` command.
# Objects come from a durable bare mirror so we do not pay a full .git
# each job. The clone is still its own repo — not a worktree under the
# Cursor checkout (#2383).
#
# Usage:
#   cstack-clone <job-slug>          # print path; reuse if already there
#   cstack-clone --force <job-slug>  # wipe and remake
#   cstack-clone --sync-only         # refresh the mirror only
#
# Env:
#   CSTACK_GIT_URL       default git@github.com:sumelabs/sume-com.git
#   CSTACK_MIRROR_ROOT   default ~/.cstack/mirrors
#   CSTACK_CLONE_ROOT    default /tmp
#   CSTACK_CLONE_PREFIX  default sume-com
set -euo pipefail

REPO="${CSTACK_GIT_URL:-git@github.com:sumelabs/sume-com.git}"
MIRROR_ROOT="${CSTACK_MIRROR_ROOT:-$HOME/.cstack/mirrors}"
MIRROR="$MIRROR_ROOT/sume-com.git"
CLONE_ROOT="${CSTACK_CLONE_ROOT:-/tmp}"
PREFIX="${CSTACK_CLONE_PREFIX:-sume-com}"

usage() {
  echo "usage: cstack-clone [--force] <job-slug> | --sync-only" >&2
  exit 2
}

sync_mirror() {
  mkdir -p "$MIRROR_ROOT"
  if [ ! -d "$MIRROR/objects" ]; then
    echo "cstack-clone: seeding mirror $MIRROR" >&2
    git clone --bare "$REPO" "$MIRROR"
  fi
  # Keep the mirror's main current. Do not `gc --prune=now` while job
  # clones still have alternates pointing here.
  git -C "$MIRROR" fetch --prune origin \
    '+refs/heads/main:refs/heads/main' \
    '+refs/heads/*:refs/remotes/origin/*' \
    || git -C "$MIRROR" fetch origin main
}

FORCE=0
SYNC_ONLY=0
SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --sync-only) SYNC_ONLY=1; shift ;;
    -h|--help) usage ;;
    -*)
      echo "cstack-clone: unknown flag $1" >&2
      usage
      ;;
    *)
      if [ -n "$SLUG" ]; then
        echo "cstack-clone: extra arg $1" >&2
        usage
      fi
      SLUG="$1"
      shift
      ;;
  esac
done

sync_mirror
if [ "$SYNC_ONLY" = 1 ]; then
  echo "$MIRROR"
  exit 0
fi

[ -n "$SLUG" ] || usage
case "$SLUG" in
  *[!a-zA-Z0-9_-]* | "" | -* | *- )
    echo "cstack-clone: bad slug: $SLUG" >&2
    exit 2
    ;;
esac

DEST="$CLONE_ROOT/$PREFIX-$SLUG"
if [ -e "$DEST" ]; then
  if [ "$FORCE" != 1 ]; then
    echo "cstack-clone: reuse $DEST" >&2
    echo "$DEST"
    exit 0
  fi
  echo "cstack-clone: --force removing $DEST" >&2
  rm -rf "$DEST"
fi

# No --dissociate: .git/objects/info/alternates → mirror. Disk win.
# No --depth: shallow + reference fights Graphite trunk checks.
echo "cstack-clone: clone --reference $MIRROR → $DEST" >&2
git clone --reference "$MIRROR" --branch main "$REPO" "$DEST"
git -C "$DEST" fetch origin main
git -C "$DEST" checkout -B main origin/main
echo "$DEST"
