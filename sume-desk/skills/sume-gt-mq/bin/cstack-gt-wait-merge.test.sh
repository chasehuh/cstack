#!/usr/bin/env bash
# Matcher tests for cstack-gt-wait-merge --classify-stdin. No gt required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/cstack-gt-wait-merge.sh"

assert_kind() {
  local want="$1"
  local blob="$2"
  local got rc
  set +e
  got="$("$BIN" --classify-stdin <<<"$blob")"
  rc=$?
  set -e
  if [ "$got" != "$want" ]; then
    echo "FAIL: want=$want got=$got blob=$(printf '%s' "$blob" | tr '\n' ' ')" >&2
    exit 1
  fi
  case "$want" in
    ready) [ "$rc" -eq 10 ] || { echo "FAIL exit $rc want 10"; exit 1; } ;;
    queued) [ "$rc" -eq 11 ] || { echo "FAIL exit $rc want 11"; exit 1; } ;;
    failed) [ "$rc" -eq 12 ] || { echo "FAIL exit $rc want 12"; exit 1; } ;;
    wait) [ "$rc" -eq 13 ] || { echo "FAIL exit $rc want 13"; exit 1; } ;;
  esac
}

# Affirmative ready
assert_kind ready $'Your stack is ready to merge\n'
assert_kind ready $'✔ Your stack is ready to merge\n'
assert_kind ready $'PR #1 (Ready to merge)\n'
assert_kind ready $'PR #1 (Ready to merge as stack)\n'

# Landmines — substring "ready to merge" must NOT match
assert_kind wait $'Cannot determine if stack is ready to merge\n'
assert_kind wait $'This stack is not ready to merge\n'
assert_kind wait $'(Waiting on CI...)\n'

# Failed / queued
assert_kind failed $'Required checks failed\n'
assert_kind failed $'Failed CI\n'
assert_kind queued $'The stack is already merging.\n'
assert_kind queued $'This PR is already in the merge queue\n'

# Failed wins over ready-looking noise
assert_kind failed $'Your stack is ready to merge\nRequired checks failed\n'

echo "cstack-gt-wait-merge.test.sh: ok"
