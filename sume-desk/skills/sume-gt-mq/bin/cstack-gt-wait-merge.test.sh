#!/usr/bin/env bash
# Matcher tests for cstack-gt-wait-merge --classify-stdin / --gate-stdin.
# No gt / gh required.
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
    undetermined) [ "$rc" -eq 14 ] || { echo "FAIL exit $rc want 14"; exit 1; } ;;
  esac
}

assert_gate() {
  local want="$1"
  local blob="$2"
  local got rc
  set +e
  got="$("$BIN" --gate-stdin <<<"$blob")"
  rc=$?
  set -e
  if [ "$got" != "$want" ]; then
    echo "FAIL gate: want=$want got=$got" >&2
    exit 1
  fi
  case "$want" in
    green) [ "$rc" -eq 20 ] || { echo "FAIL gate exit $rc want 20"; exit 1; } ;;
    labeled) [ "$rc" -eq 21 ] || { echo "FAIL gate exit $rc want 21"; exit 1; } ;;
    pending) [ "$rc" -eq 22 ] || { echo "FAIL gate exit $rc want 22"; exit 1; } ;;
    failed) [ "$rc" -eq 23 ] || { echo "FAIL gate exit $rc want 23"; exit 1; } ;;
    error) [ "$rc" -eq 24 ] || { echo "FAIL gate exit $rc want 24"; exit 1; } ;;
  esac
}

# Affirmative ready
assert_kind ready $'Your stack is ready to merge\n'
assert_kind ready $'✔ Your stack is ready to merge\n'
assert_kind ready $'PR #1 (Ready to merge)\n'
assert_kind ready $'PR #1 (Ready to merge as stack)\n'

# Landmines — substring "ready to merge" must NOT match ready
assert_kind undetermined $'Cannot determine if stack is ready to merge\n'
assert_kind undetermined $'ERROR: Cannot determine if stack is ready to merge\n'
assert_kind wait $'This stack is not ready to merge\n'
assert_kind wait $'(Waiting on CI...)\n'

# Failed / queued
assert_kind failed $'Required checks failed\n'
assert_kind failed $'Failed CI\n'
assert_kind queued $'The stack is already merging.\n'
assert_kind queued $'This PR is already in the merge queue\n'

# Failed wins over ready-looking noise
assert_kind failed $'Your stack is ready to merge\nRequired checks failed\n'

required_ok='[
  {"name":"Format","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Build","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Test 1/4","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Graphite CI optimizer","status":"COMPLETED","conclusion":"SKIPPED"}
]'

assert_gate labeled "$(cat <<EOF
{"number":5616,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","labels":[{"name":"merge-queue"}],"statusCheckRollup":[]}
EOF
)"

assert_gate green "$(cat <<EOF
{"number":5616,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":${required_ok}}
EOF
)"

assert_gate green "$(cat <<EOF
{"number":5615,"state":"OPEN","isDraft":false,"mergeStateStatus":"UNSTABLE","labels":[],"statusCheckRollup":${required_ok}}
EOF
)"

# Non-required red does not block (Vercel / mergeability).
assert_gate green "$(cat <<EOF
{"number":1,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[
  {"name":"Format","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Typecheck","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Build","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Test 1/4","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Vercel Preview Comments","status":"COMPLETED","conclusion":"FAILURE"},
  {"name":"Graphite / mergeability_check","status":"IN_PROGRESS","conclusion":""}
]}
EOF
)"

assert_gate pending "$(cat <<EOF
{"number":1,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[
  {"name":"Format","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Test 1/4","status":"IN_PROGRESS","conclusion":""}
]}
EOF
)"

assert_gate pending "$(cat <<EOF
{"number":1,"state":"OPEN","isDraft":false,"mergeStateStatus":"DIRTY","labels":[],"statusCheckRollup":${required_ok}}
EOF
)"

assert_gate pending "$(cat <<EOF
{"number":1,"state":"OPEN","isDraft":false,"mergeStateStatus":"BLOCKED","labels":[],"statusCheckRollup":${required_ok}}
EOF
)"

assert_gate pending "$(cat <<EOF
{"number":1,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[]}
EOF
)"

assert_gate failed "$(cat <<EOF
{"number":1,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[
  {"name":"Format","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"Test 1/4","status":"COMPLETED","conclusion":"FAILURE"}
]}
EOF
)"

assert_gate pending "$(cat <<EOF
{"number":1,"state":"DRAFT","isDraft":true,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":${required_ok}}
EOF
)"

assert_gate error $'not-json\n'

echo "cstack-gt-wait-merge.test.sh: ok"
