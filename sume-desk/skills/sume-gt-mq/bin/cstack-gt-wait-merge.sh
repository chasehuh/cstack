#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_MERGE=1
RM_SLUG=""
TIMEOUT="${CSTACK_WAIT_MERGE_TIMEOUT:-2700}"
INTERVAL=20
CHAIN_TIP=""
CHAIN_STDIN=0
VALIDATE_STDIN=0

usage() {
  cat <<'EOF'
cstack-gt-wait-merge — queue the stack at this branch in GitHub's merge queue.

Run it from the author clone at the stack tip, after `gh stack submit`
(an older `gt submit` stack works too). It walks the PR chain from the tip
down to the trunk, marks draft layers ready, links two or more PRs into one
GitHub stack (`gh stack link`), waits for `validate` on every layer, then
queues:
  one PR    gh pr merge <N> --auto --squash
  a stack   gh stack merge <tip> --yes      (every layer enters the queue)

Exit 0 means queued, already queued or already merged: enqueue evidence only.
Stay until `git log origin/main --fixed-strings --grep='(#N)'` shows every
layer.

  --rm SLUG          after queueing, run `cstack-clone-rm SLUG`
  --no-merge         print the chain; do not ready, link or queue
  --timeout N        seconds to wait for validate (default 2700)
  --interval N       seconds between validate polls (default 20)
  --chain-stdin TIP  test hook: open PRs JSON on stdin → chain bottom..tip
                     (env CSTACK_TRUNK: stack base other than the default branch)
  --validate-stdin   test hook: one `gh pr view --json statusCheckRollup` blob
  -h, --help

Exit: 0 queued · 1 usage · 2 no PR or broken chain · 3 validate failed ·
4 validate timed out · 5 no merge queue on the trunk, or queueing failed
EOF
}

cstack_chain_from_json() {
  TIP="$1" TRUNK="${TRUNK:-main}" python3 -c '
import json, os, sys

tip = int(os.environ["TIP"])
trunk = os.environ["TRUNK"]
try:
    prs = json.load(sys.stdin)
except Exception:
    print("error: unreadable PR list")
    raise SystemExit(2)
by_number = {p["number"]: p for p in prs}
by_head = {}
for p in prs:
    by_head.setdefault(p["headRefName"], []).append(p)
if tip not in by_number:
    print(f"error: #{tip} is not an open PR")
    raise SystemExit(2)
chain = [tip]
seen = {tip}
current = by_number[tip]
while current["baseRefName"] != trunk:
    below = by_head.get(current["baseRefName"]) or []
    if len(below) != 1:
        number, base = current["number"], current["baseRefName"]
        print(f"error: #{number} sits on {base}, which has {len(below)} open PRs")
        raise SystemExit(2)
    current = below[0]
    if current["number"] in seen:
        print("error: the PR chain loops")
        raise SystemExit(2)
    seen.add(current["number"])
    chain.append(current["number"])
print(" ".join(str(n) for n in reversed(chain)))
'
}

cstack_validate_from_json() {
  python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("error")
    raise SystemExit(0)
checks = [
    c for c in (data.get("statusCheckRollup") or [])
    if (c.get("name") or c.get("context") or "") == "validate"
]
if not checks:
    print("pending")
    raise SystemExit(0)
bad = {"FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "STARTUP_FAILURE", "ERROR"}
states = []
for c in checks:
    status = (c.get("status") or "COMPLETED").upper()
    result = (c.get("conclusion") or c.get("state") or "").upper()
    if status != "COMPLETED" or result in {"", "PENDING", "EXPECTED"}:
        states.append("pending")
    elif result in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
        states.append("green")
    elif result in bad:
        states.append("failed")
    else:
        states.append("pending")
if "pending" in states:
    print("pending")
elif "green" in states:
    print("green")
else:
    print("failed")
'
}

pr_queue_state() {
  # shellcheck disable=SC2016
  gh api graphql -F n="$1" -f owner="$OWNER" -f name="$NAME" -f query='
query($owner: String!, $name: String!, $n: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $n) { state isInMergeQueue }
  }
}' --jq '.data.repository.pullRequest | if .state == "MERGED" then "merged" elif .isInMergeQueue then "queued" else "open" end' 2>/dev/null || echo unknown
}

has_merge_queue() {
  # shellcheck disable=SC2016
  gh api graphql -f owner="$OWNER" -f name="$NAME" -f branch="$TRUNK" -f query='
query($owner: String!, $name: String!, $branch: String!) {
  repository(owner: $owner, name: $name) { mergeQueue(branch: $branch) { id } }
}' --jq '.data.repository.mergeQueue != null' 2>/dev/null || echo unknown
}

finish_ok() {
  if [ -n "$RM_SLUG" ]; then
    "$SCRIPT_DIR/cstack-clone-rm.sh" "$RM_SLUG" || true
  fi
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --rm)
      RM_SLUG="${2:?--rm needs a job slug}"
      shift 2
      ;;
    --no-merge)
      DO_MERGE=0
      shift
      ;;
    --timeout)
      TIMEOUT="${2:?--timeout needs seconds}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:?--interval needs seconds}"
      shift 2
      ;;
    --chain-stdin)
      CHAIN_STDIN=1
      CHAIN_TIP="${2:?--chain-stdin needs the tip PR number}"
      shift 2
      ;;
    --validate-stdin)
      VALIDATE_STDIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "cstack-gt-wait-merge: unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$CHAIN_STDIN" -eq 1 ]; then
  cstack_chain_from_json "$CHAIN_TIP"
  exit $?
fi

if [ "$VALIDATE_STDIN" -eq 1 ]; then
  cstack_validate_from_json
  exit 0
fi

for tool in gh python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "cstack-gt-wait-merge: $tool not on PATH" >&2
    exit 1
  fi
done

repo_json="$(gh repo view --json owner,name,defaultBranchRef 2>/dev/null || true)"
if [ -z "$repo_json" ]; then
  echo "cstack-gt-wait-merge: run from a clone of the repo" >&2
  exit 2
fi
OWNER="$(printf '%s' "$repo_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["owner"]["login"])')"
NAME="$(printf '%s' "$repo_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
TRUNK="${CSTACK_TRUNK:-$(printf '%s' "$repo_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["defaultBranchRef"]["name"])')}"
export TRUNK

tip="$(gh pr view --json number --jq .number 2>/dev/null || true)"
if [ -z "$tip" ]; then
  echo "cstack-gt-wait-merge: no PR for this branch — run from the stack tip after gh stack submit" >&2
  exit 2
fi

case "$(pr_queue_state "$tip")" in
  merged)
    echo "cstack-gt-wait-merge: #${tip} already merged" >&2
    finish_ok
    ;;
  queued)
    echo "cstack-gt-wait-merge: #${tip} already in the merge queue" >&2
    finish_ok
    ;;
esac

set +e
chain="$(gh pr list --state open --limit 1000 --json number,headRefName,baseRefName | cstack_chain_from_json "$tip")"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "cstack-gt-wait-merge: $chain" >&2
  exit 2
fi
read -r -a layers <<<"$chain"
echo "cstack-gt-wait-merge: stack $(printf '#%s ' "${layers[@]}")(bottom → tip) onto ${TRUNK}" >&2

if [ "$DO_MERGE" -ne 1 ]; then
  echo "cstack-gt-wait-merge: --no-merge; not queueing" >&2
  exit 0
fi

if [ "$(has_merge_queue)" != "true" ]; then
  echo "cstack-gt-wait-merge: ${TRUNK} has no merge queue — refusing a direct merge (PR CI does not run the full suite)" >&2
  exit 5
fi

for n in "${layers[@]}"; do
  if [ "$(gh pr view "$n" --json isDraft --jq .isDraft)" = "true" ]; then
    echo "cstack-gt-wait-merge: #${n} is a draft — marking it ready" >&2
    gh pr ready "$n" >&2
  fi
done

if [ "${#layers[@]}" -ge 2 ]; then
  if ! gh stack link --base "$TRUNK" "${layers[@]}" >&2; then
    echo "cstack-gt-wait-merge: gh stack link failed (gh extension install github/gh-stack)" >&2
    exit 5
  fi
fi

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  pending=""
  for n in "${layers[@]}"; do
    verdict="$(gh pr view "$n" --json statusCheckRollup | cstack_validate_from_json)"
    case "$verdict" in
      failed)
        echo "cstack-gt-wait-merge: validate failed on #${n} — fix, gh stack sync, run again" >&2
        exit 3
        ;;
      green) ;;
      *) pending="$pending #$n" ;;
    esac
  done
  [ -z "$pending" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "cstack-gt-wait-merge: validate still pending on${pending} after ${TIMEOUT}s" >&2
    exit 4
  fi
  echo "cstack-gt-wait-merge: waiting for validate on${pending}" >&2
  sleep "$INTERVAL"
done

if [ "${#layers[@]}" -eq 1 ]; then
  if ! gh pr merge "$tip" --auto --squash >&2; then
    echo "cstack-gt-wait-merge: gh pr merge --auto failed on #${tip}" >&2
    exit 5
  fi
else
  out="$(mktemp)"
  gh stack merge "$tip" --yes </dev/null >"$out" 2>&1 &
  pid=$!
  for _ in $(seq 1 90); do
    if grep -qE 'Added #|merged|error|Error|failed' "$out" || ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 2
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out" >&2
  rm -f "$out"
fi

for _ in $(seq 1 15); do
  state="$(pr_queue_state "$tip")"
  case "$state" in
    queued|merged)
      echo "cstack-gt-wait-merge: QUEUED $(printf '#%s ' "${layers[@]}")— tip #${tip} is ${state}" >&2
      finish_ok
      ;;
  esac
  sleep 2
done

if [ "${#layers[@]}" -eq 1 ] && [ "$(gh pr view "$tip" --json autoMergeRequest --jq '.autoMergeRequest != null')" = "true" ]; then
  echo "cstack-gt-wait-merge: QUEUED #${tip} — auto-merge on; it enters the queue when GitHub admits it" >&2
  finish_ok
fi

echo "cstack-gt-wait-merge: #${tip} is not in the merge queue — see the output above" >&2
exit 5
