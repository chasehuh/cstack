#!/usr/bin/env bash
# Install the cstack desk patch onto the global tokenmaxxing@1.10.0 (cstack#25).
#
# Pins upstream tokenmaxxing 1.10.0 (sha256-checked npm tarball), applies
# desk-1.10.0.patch, runs desk.test.ts against the staged tree, then swaps
# src/ into the global package and rewrites the desk wrappers in
# ~/.config/tokenmaxxing/bin. Idempotent. Never prints credential material.
#
# Usage:
#   install-tokenmaxxing-desk.sh [--mirror | --no-mirror] [--no-test] [--if-pinned]
#   install-tokenmaxxing-desk.sh --check
#
#   --mirror      macOS SSH worker host (the Mini): keep the live keychain item
#                 and ~/.claude/.credentials.json in step (live-file-mirror marker)
#   --no-mirror   remove that marker
#   --if-pinned   exit 0 quietly unless the global package is tokenmaxxing 1.10.0
#   --check       report install state only (exit 1 when not current)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/desk-1.10.0.patch"
TEST="$HERE/desk.test.ts"
VERSION=1.10.0
TARBALL_URL="https://registry.npmjs.org/tokenmaxxing/-/tokenmaxxing-$VERSION.tgz"
TARBALL_SHA256=7d2f864054608817d89dedb3604bac39b905e95c45662747ac901c05ad16b932
if [ -z "${BUN:-}" ]; then
  if [ -x "$HOME/.bun/bin/bun" ]; then BUN="$HOME/.bun/bin/bun"; else BUN="$(command -v bun 2>/dev/null || echo bun)"; fi
fi
GLOBAL="${TOKENMAXXING_GLOBAL_DIR:-$HOME/.bun/install/global/node_modules}"
PKG="$GLOBAL/tokenmaxxing"
TM_HOME="${TOKENMAXXING_HOME:-$HOME/.config/tokenmaxxing}"
STAMP="$PKG/.cstack-desk-patch"
LEGACY_SYNC="$HOME/.local/bin/tokenmaxxing-sync-claude-file.sh"

MIRROR=keep
RUN_TESTS=1
IF_PINNED=0
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mirror) MIRROR=on ;;
    --no-mirror) MIRROR=off ;;
    --no-test) RUN_TESTS=0 ;;
    --if-pinned) IF_PINNED=1 ;;
    --check) CHECK=1 ;;
    *) echo "usage: $0 [--mirror|--no-mirror] [--no-test] [--if-pinned] | --check" >&2; exit 2 ;;
  esac
  shift
done

say() { printf 'tokenmaxxing-desk: %s\n' "$*"; }
die() { printf 'tokenmaxxing-desk: %s\n' "$*" >&2; exit 1; }

[ -f "$PATCH" ] || die "missing $PATCH"
PATCH_SHA=$(shasum -a 256 "$PATCH" | cut -c1-12)
CSTACK_SHA=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)

installed_version() {
  [ -f "$PKG/package.json" ] || { echo none; return; }
  sed -n 's/^  "version": "\(.*\)",$/\1/p' "$PKG/package.json" | head -1
}

current_stamp() { [ -f "$STAMP" ] && head -1 "$STAMP" || true; }

wrapper_body() {
  cat <<EOF
#!/bin/sh
# cstack desk wrapper (sume-desk/tokenmaxxing, docs/TOKENMAXXING.md).
# The live file mirror replaces tokenmaxxing-sync-claude-file.sh (cstack#25).
exec "$BUN" run "$PKG/src/main.ts" "\$@"
EOF
}

claude_shim_body() {
  cat <<EOF
#!/bin/sh
# cstack desk wrapper (sume-desk/tokenmaxxing, docs/TOKENMAXXING.md).
# SSH/detached sessions cannot read the login keychain (security exit 36).
# Only there point Claude Code at the file store, ~/.claude/.credentials.json,
# which the tokenmaxxing live file mirror keeps in step with the keychain item.
if ! security show-keychain-info "\$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  export CLAUDE_SECURESTORAGE_CONFIG_DIR="\${CLAUDE_SECURESTORAGE_CONFIG_DIR:-\$HOME/.claude}"
fi
exec "$TM_HOME/bin/tokenmaxxing" __supervise "\$@"
EOF
}

VERSION_NOW=$(installed_version)

if [ "$CHECK" -eq 1 ]; then
  ok=0
  say "global package: $PKG (version $VERSION_NOW)"
  stamp=$(current_stamp)
  say "stamp: ${stamp:-none}"
  say "repo patch: $PATCH_SHA"
  case "$stamp" in *"$PATCH_SHA"*) ;; *) ok=1; say "NOT CURRENT: re-run $0" ;; esac
  if [ "$(cat "$TM_HOME/bin/tokenmaxxing" 2>/dev/null)" != "$(wrapper_body)" ]; then ok=1; say "wrapper $TM_HOME/bin/tokenmaxxing differs"; fi
  if [ -e "$LEGACY_SYNC" ]; then ok=1; say "legacy one-way sync still present: $LEGACY_SYNC"; fi
  if [ -e "$TM_HOME/live-file-mirror" ]; then say "live file mirror: on"; else say "live file mirror: off"; fi
  exit "$ok"
fi

if [ "$VERSION_NOW" != "$VERSION" ]; then
  if [ "$IF_PINNED" -eq 1 ]; then
    say "global tokenmaxxing is $VERSION_NOW, not $VERSION - desk patch skipped (docs/TOKENMAXXING.md)"
    exit 0
  fi
  die "global tokenmaxxing is $VERSION_NOW; the desk patch targets $VERSION. Pin it first: $BUN add -g tokenmaxxing@$VERSION"
fi
[ -x "$BUN" ] || die "bun not found ($BUN)"

if case "$(current_stamp)" in *"$PATCH_SHA"*) true ;; *) false ;; esac; then
  say "desk patch $PATCH_SHA already installed"
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/tokenmaxxing-desk.XXXXXX")
  STAGE="$GLOBAL/.tokenmaxxing-desk-stage"
  cleanup() { rm -rf "$WORK" "$STAGE"; }
  trap cleanup EXIT
  say "fetching tokenmaxxing@$VERSION"
  curl -fsSL -o "$WORK/pkg.tgz" "$TARBALL_URL"
  got=$(shasum -a 256 "$WORK/pkg.tgz" | cut -d' ' -f1)
  [ "$got" = "$TARBALL_SHA256" ] || die "tarball sha256 mismatch ($got)"
  tar -xzf "$WORK/pkg.tgz" -C "$WORK"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$WORK/package/." "$STAGE/"
  (cd "$STAGE" && GIT_CEILING_DIRECTORIES="$GLOBAL" git apply -p1 --whitespace=nowarn "$PATCH") \
    || die "patch does not apply to pristine $VERSION"
  if [ "$RUN_TESTS" -eq 1 ]; then
    say "testing the staged tree (hermetic: fake keychain, fake token endpoint)"
    (cd "$HERE" && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CONFIG_DIR \
      TOKENMAXXING_SRC="$STAGE" "$BUN" test "$TEST") >"$WORK/test.log" 2>&1 \
      || { tail -40 "$WORK/test.log" >&2; die "desk tests failed - nothing installed"; }
    say "$(grep -E '^ *[0-9]+ pass' "$WORK/test.log" | head -1 | sed 's/^ *//')"
  fi
  rm -rf "$PKG/.src.prev"
  mv "$PKG/src" "$PKG/.src.prev"
  mv "$STAGE/src" "$PKG/src"
  printf 'cstack desk patch %s on tokenmaxxing %s (cstack %s, installed %s)\n' \
    "$PATCH_SHA" "$VERSION" "$CSTACK_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STAMP"
  say "installed: $(current_stamp)"
  say "previous src kept at $PKG/.src.prev"
fi

mkdir -p "$TM_HOME/bin"
if [ "$(cat "$TM_HOME/bin/tokenmaxxing" 2>/dev/null)" != "$(wrapper_body)" ]; then
  wrapper_body >"$TM_HOME/bin/tokenmaxxing.tmp" && chmod 755 "$TM_HOME/bin/tokenmaxxing.tmp"
  mv "$TM_HOME/bin/tokenmaxxing.tmp" "$TM_HOME/bin/tokenmaxxing"
  say "wrote $TM_HOME/bin/tokenmaxxing"
fi
if [ "$(uname -s)" = "Darwin" ] && [ "$(cat "$TM_HOME/bin/claude" 2>/dev/null)" != "$(claude_shim_body)" ]; then
  claude_shim_body >"$TM_HOME/bin/claude.tmp" && chmod 755 "$TM_HOME/bin/claude.tmp"
  mv "$TM_HOME/bin/claude.tmp" "$TM_HOME/bin/claude"
  say "wrote $TM_HOME/bin/claude"
fi
if [ -e "$LEGACY_SYNC" ]; then
  rm -f "$LEGACY_SYNC"
  say "retired $LEGACY_SYNC (one-way keychain -> file copy; it duplicated the live grant)"
fi
case "$MIRROR" in
  on)
    [ "$(uname -s)" = "Darwin" ] || die "--mirror is macOS-only"
    : >"$TM_HOME/live-file-mirror"
    say "live file mirror: on"
    ;;
  off)
    rm -f "$TM_HOME/live-file-mirror"
    say "live file mirror: off"
    ;;
  keep)
    if [ -e "$TM_HOME/live-file-mirror" ]; then say "live file mirror: on"; else say "live file mirror: off (pass --mirror on an SSH worker host)"; fi
    ;;
esac
if [ -e "$TM_HOME/live-file-mirror" ]; then
  "$TM_HOME/bin/tokenmaxxing" sync-file || true
fi
