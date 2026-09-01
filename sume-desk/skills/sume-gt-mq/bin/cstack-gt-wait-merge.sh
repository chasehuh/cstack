#!/usr/bin/env bash
# After `gt submit`, label the tip `merge-queue` immediately.
# Graphite: if the PR is not mergeable yet, the label is Merge when ready
# and the PR enters MQ when `validate` passes. If it is already mergeable,
# the label enqueues now. Do not wait for PR CI. Do not `gt merge`.
#
# Usage (from the author clone cwd, stack tip after submit):
#   cstack-gt-wait-merge
#   cstack-gt-wait-merge --rm <job-slug>
#   cstack-gt-wait-merge --no-merge
#   cstack-gt-wait-merge --classify-stdin    # test hook
#   cstack-gt-wait-merge --gate-stdin        # test hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_MERGE=1
RM_SLUG=""
CLASSIFY_STDIN=0
GATE_STDIN=0

usage() {
  cat <<'EOF'
cstack-gt-wait-merge — label the tip `merge-queue` immediately after submit.

  --rm SLUG        after enqueue, run `cstack-clone-rm SLUG`
  --no-merge       print the tip PR; do not label
  --interval N     accepted, unused (no CI poll)
  --classify-stdin classify one dry-run blob from stdin (exit 10–14)
  --gate-stdin     classify one `gh pr view --json` blob (exit 20–24)
  -h, --help

Default: do not wait for PR CI / dry-run Ready.
Label the tip. Not mergeable yet → Graphite MWR → MQ when validate is green.
Already labeled / already in MQ → exit 0.
Label rejected / no tip PR → exit 2.
EOF
}

# Classify a `gt merge --dry-run` blob (test hook only).
# Prints: ready|queued|failed|undetermined|wait
cstack_gt_classify() {
  local blob="$1"

  if printf '%s' "$blob" | grep -qiE 'Required checks failed|Failed CI'; then
    printf '%s\n' failed
    return 0
  fi

  if printf '%s' "$blob" | grep -qiE 'already merging|already in the merge queue'; then
    printf '%s\n' queued
    return 0
  fi

  if printf '%s' "$blob" | grep -qF 'Your stack is ready to merge'; then
    printf '%s\n' ready
    return 0
  fi
  if printf '%s' "$blob" | grep -qF '(Ready to merge as stack)'; then
    printf '%s\n' ready
    return 0
  fi
  if printf '%s' "$blob" | grep -qF '(Ready to merge)'; then
    printf '%s\n' ready
    return 0
  fi

  if printf '%s' "$blob" | grep -qF 'Cannot determine if stack is ready to merge'; then
    printf '%s\n' undetermined
    return 0
  fi

  printf '%s\n' wait
}

# Classify `gh pr view --json` (test hook only).
cstack_gt_gh_gate_from_json() {
  python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("error")
    raise SystemExit(0)

labels = []
for item in data.get("labels") or []:
    if isinstance(item, dict):
        labels.append(item.get("name") or "")
    else:
        labels.append(str(item))
if "merge-queue" in labels:
    print("labeled")
    raise SystemExit(0)

if data.get("state") != "OPEN" or data.get("isDraft"):
    print("pending")
    raise SystemExit(0)

exact = {
    "Format",
    "Typecheck",
    "Build",
    "validate",
    "Graphite CI optimizer",
}

def required(name):
    name = name or ""
    return name in exact or name.startswith("Test")

checks = [
    c for c in (data.get("statusCheckRollup") or [])
    if required(c.get("name") or "")
]
if not checks:
    print("pending")
    raise SystemExit(0)

hard_fail = {"FAILURE", "TIMED_OUT", "ACTION_REQUIRED"}
pending = False
failed = False
success = 0
for check in checks:
    conclusion = (check.get("conclusion") or "").upper()
    status = (check.get("status") or "").upper()
    if conclusion in hard_fail:
        failed = True
        continue
    if conclusion == "CANCELLED":
        pending = True
        continue
    if conclusion in {"SUCCESS", "NEUTRAL"}:
        success += 1
        continue
    if conclusion == "SKIPPED":
        continue
    if status != "COMPLETED":
        pending = True
        continue
    pending = True

if failed:
    print("failed")
    raise SystemExit(0)
if pending or success == 0:
    print("pending")
    raise SystemExit(0)

status = data.get("mergeStateStatus") or ""
if status in {"CLEAN", "UNSTABLE"}:
    print("green")
    raise SystemExit(0)
print("pending")
'
}

cstack_gt_pr_number() {
  gh pr view --json number --jq .number 2>/dev/null || true
}

cstack_gt_has_mq_label() {
  local number="$1"
  local has
  has="$(gh pr view "$number" --json labels --jq '[.labels[].name] | any(. == "merge-queue")' 2>/dev/null || true)"
  [ "$has" = "true" ]
}

finish_ok() {
  if [ -n "$RM_SLUG" ]; then
    "$SCRIPT_DIR/cstack-clone-rm.sh" "$RM_SLUG" || true
  fi
  exit 0
}

label_tip_enqueue() {
  local number="$1"
  if [ -z "$number" ]; then
    echo "cstack-gt-wait-merge: no tip PR to label" >&2
    return 1
  fi
  if [ "$DO_MERGE" -ne 1 ]; then
    echo "cstack-gt-wait-merge: would label merge-queue on #${number} (--no-merge)" >&2
    return 0
  fi
  echo "cstack-gt-wait-merge: labeling merge-queue on #${number} now (MWR if CI pending)" >&2
  gh pr edit "$number" --add-label merge-queue
}

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)
      shift 2
      ;;
    --no-merge)
      DO_MERGE=0
      shift
      ;;
    --rm)
      RM_SLUG="${2:?--rm needs a job slug}"
      shift 2
      ;;
    --classify-stdin)
      CLASSIFY_STDIN=1
      shift
      ;;
    --gate-stdin)
      GATE_STDIN=1
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

if [ "$CLASSIFY_STDIN" -eq 1 ]; then
  blob="$(cat)"
  kind="$(cstack_gt_classify "$blob")"
  printf '%s\n' "$kind"
  case "$kind" in
    ready) exit 10 ;;
    queued) exit 11 ;;
    failed) exit 12 ;;
    wait) exit 13 ;;
    undetermined) exit 14 ;;
    *) exit 1 ;;
  esac
fi

if [ "$GATE_STDIN" -eq 1 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "cstack-gt-wait-merge: python3 required for --gate-stdin" >&2
    exit 1
  fi
  gate="$(cstack_gt_gh_gate_from_json)"
  printf '%s\n' "$gate"
  case "$gate" in
    green) exit 20 ;;
    labeled) exit 21 ;;
    pending) exit 22 ;;
    failed) exit 23 ;;
    error) exit 24 ;;
    *) exit 1 ;;
  esac
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "cstack-gt-wait-merge: gh not on PATH" >&2
  exit 1
fi

number="$(cstack_gt_pr_number)"
if [ -z "$number" ]; then
  echo "cstack-gt-wait-merge: no tip PR — run from the submitted stack tip after gt submit" >&2
  exit 2
fi

if cstack_gt_has_mq_label "$number"; then
  echo "cstack-gt-wait-merge: tip #${number} already has merge-queue — stop" >&2
  finish_ok
fi

if label_tip_enqueue "$number"; then
  echo "cstack-gt-wait-merge: ENQUEUED via merge-queue label on #${number} (MWR if CI still running)" >&2
  finish_ok
fi

echo "cstack-gt-wait-merge: label rejected — HANDOFF: grok-ci-merge" >&2
exit 2
