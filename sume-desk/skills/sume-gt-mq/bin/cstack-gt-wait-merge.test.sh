#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/cstack-gt-wait-merge.sh"

assert_chain() {
  local tip="$1" want="$2" want_rc="$3" blob="$4" got rc
  set +e
  got="$("$BIN" --chain-stdin "$tip" <<<"$blob")"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL chain tip=$tip: exit $rc want $want_rc ($got)" >&2
    exit 1
  fi
  if [ "$want_rc" -eq 0 ] && [ "$got" != "$want" ]; then
    echo "FAIL chain tip=$tip: want '$want' got '$got'" >&2
    exit 1
  fi
}

assert_validate() {
  local want="$1" blob="$2" got
  got="$("$BIN" --validate-stdin <<<"$blob")"
  if [ "$got" != "$want" ]; then
    echo "FAIL validate: want=$want got=$got blob=$blob" >&2
    exit 1
  fi
}

PRS='[
  {"number": 11, "headRefName": "a", "baseRefName": "main"},
  {"number": 12, "headRefName": "b", "baseRefName": "a"},
  {"number": 13, "headRefName": "c", "baseRefName": "b"},
  {"number": 20, "headRefName": "solo", "baseRefName": "main"},
  {"number": 30, "headRefName": "orphan", "baseRefName": "gone"},
  {"number": 41, "headRefName": "x", "baseRefName": "y"},
  {"number": 42, "headRefName": "y", "baseRefName": "x"},
  {"number": 51, "headRefName": "dup", "baseRefName": "main"},
  {"number": 52, "headRefName": "dup", "baseRefName": "main"},
  {"number": 53, "headRefName": "top", "baseRefName": "dup"}
]'

assert_chain 13 "11 12 13" 0 "$PRS"
assert_chain 12 "11 12" 0 "$PRS"
assert_chain 11 "11" 0 "$PRS"
assert_chain 20 "20" 0 "$PRS"
assert_chain 30 "" 2 "$PRS"
assert_chain 41 "" 2 "$PRS"
assert_chain 53 "" 2 "$PRS"
assert_chain 99 "" 2 "$PRS"
assert_chain 11 "" 2 "not json"
TRUNK=develop assert_chain 11 "" 2 "$PRS"

assert_validate green '{"statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"Build","status":"COMPLETED","conclusion":"SKIPPED"}]}'
assert_validate pending '{"statusCheckRollup":[{"name":"validate","status":"IN_PROGRESS","conclusion":""}]}'
assert_validate pending '{"statusCheckRollup":[{"name":"Typecheck and Format (review)","status":"COMPLETED","conclusion":"SUCCESS"}]}'
assert_validate pending '{"statusCheckRollup":[]}'
assert_validate failed '{"statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"FAILURE"}]}'
assert_validate failed '{"statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"CANCELLED"}]}'
assert_validate pending '{"statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"FAILURE"},{"name":"validate","status":"QUEUED","conclusion":""}]}'
assert_validate green '{"statusCheckRollup":[{"context":"validate","state":"SUCCESS"}]}'
assert_validate failed '{"statusCheckRollup":[{"context":"validate","state":"ERROR"}]}'
assert_validate pending '{"statusCheckRollup":[{"context":"validate","state":"PENDING"}]}'
assert_validate error 'not json'

echo "cstack-gt-wait-merge tests: ok"
