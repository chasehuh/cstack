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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "repo view") echo '{"owner":{"login":"acme"},"name":"repo","defaultBranchRef":{"name":"main"}}' ;;
  "api graphql")
    if printf '%s' "$*" | grep -q 'mergeQueue(branch'; then echo true
    elif [ -f "$FAKE_GH_STATE/queued" ]; then echo queued
    else echo open; fi ;;
  "pr list") echo '[{"number": 20, "headRefName": "last-layer", "baseRefName": "main"}]' ;;
  "pr view")
    case "$*" in
      *"--json number"*) echo 20 ;;
      *isDraft*) echo false ;;
      *statusCheckRollup*) echo '{"statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"}]}' ;;
      *autoMergeRequest*) echo false ;;
    esac ;;
  "pr merge")
    echo "$FAKE_GH_MERGE_ERROR" >&2
    exit 1 ;;
  "stack merge")
    echo "✓ Added #20 to the merge queue for main"
    : >"$FAKE_GH_STATE/queued" ;;
esac
FAKE
chmod +x "$T/bin/gh"

run_helper() {
  mkdir -p "$T/state"
  rm -f "$T/state/queued"
  : >"$T/gh.log"
  set +e
  PATH="$T/bin:$PATH" FAKE_GH_LOG="$T/gh.log" FAKE_GH_STATE="$T/state" FAKE_GH_MERGE_ERROR="$1" \
    CSTACK_WAIT_MERGE_STACK_POLL=0 "$BIN" --interval 0 >"$T/out.txt" 2>"$T/err.txt"
  HELPER_RC=$?
  set -e
}

run_helper "GraphQL: Auto-merge is not supported for stacked pull requests. (enablePullRequestAutoMerge)"
if [ "$HELPER_RC" -ne 0 ]; then
  echo "FAIL last layer of a stack: exit $HELPER_RC, want 0 ($(tail -n 3 "$T/err.txt"))" >&2
  exit 1
fi
grep -q '^stack merge 20 --yes$' "$T/gh.log" || { echo "FAIL last layer of a stack: gh stack merge was not called ($(cat "$T/gh.log"))" >&2; exit 1; }
grep -q 'QUEUED #20' "$T/err.txt" || { echo "FAIL last layer of a stack: no QUEUED line ($(tail -n 3 "$T/err.txt"))" >&2; exit 1; }

run_helper "GraphQL: Pull request is in clean status (enablePullRequestAutoMerge)"
if [ "$HELPER_RC" -ne 5 ]; then
  echo "FAIL other auto-merge error: exit $HELPER_RC, want 5" >&2
  exit 1
fi
if grep -q '^stack merge' "$T/gh.log"; then
  echo "FAIL other auto-merge error: gh stack merge must not be called" >&2
  exit 1
fi

echo "cstack-gt-wait-merge tests: ok"
