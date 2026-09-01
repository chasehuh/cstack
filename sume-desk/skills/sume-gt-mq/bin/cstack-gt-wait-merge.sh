#!/usr/bin/env bash
# Wait until Graphite may enqueue, then enqueue.
# Default: affirmative Ready → `gt merge`.
# Cannot determine + mergeable → label the tip `merge-queue`
# (Graphite official enqueue-from-anywhere). Never `gt merge` while the
# CLI says it cannot determine. Do not hand-roll this loop.
#
# Usage (from the author clone cwd, stack tip after submit):
#   cstack-gt-wait-merge
#   cstack-gt-wait-merge --interval 8
#   cstack-gt-wait-merge --no-merge
#   cstack-gt-wait-merge --rm <job-slug>     # after successful enqueue
#   cstack-gt-wait-merge --classify-stdin    # test hook (no gt)
#   cstack-gt-wait-merge --gate-stdin        # test hook (gh JSON → gate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INTERVAL="${CSTACK_GT_WAIT_INTERVAL:-8}"
DO_MERGE=1
RM_SLUG=""
CLASSIFY_STDIN=0
GATE_STDIN=0
DID_SYNC=0

usage() {
  cat <<'EOF'
cstack-gt-wait-merge — poll `gt merge --dry-run` then enqueue.

  --interval N     seconds between polls (5–12, default 8)
  --no-merge       wait/classify only; do not `gt merge` or label
  --rm SLUG        after enqueue, run `cstack-clone-rm SLUG`
  --classify-stdin classify one dry-run blob from stdin (exit 10–14)
  --gate-stdin     classify one `gh pr view --json` blob (exit 20–24)
  -h, --help

Ready (affirmative only) → `gt merge`:
  Your stack is ready to merge
  (Ready to merge)
  (Ready to merge as stack)

Cannot determine → do NOT `gt merge`:
  one `gt sync --no-interactive --no-restack`, retry dry-run
  still undetermined + required GH green + CLEAN/UNSTABLE
    → label the tip PR `merge-queue` (exit 0)
  still pending CI → keep polling
  required failed → exit 2

NOT ready (keep waiting):
  not ready to merge
  (Waiting on CI...)

Failed (exit 2, no more sleep):
  Required checks failed
  Failed CI

Already queued (exit 0):
  already merging
  already in the merge queue
  tip already has `merge-queue`
EOF
}

# Classify a `gt merge --dry-run` blob.
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

  # Affirmative only. Never substring-match "ready to merge".
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

# Classify `gh pr view --json number,state,isDraft,mergeStateStatus,labels,statusCheckRollup`.
# Prints: labeled|green|pending|failed|error
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

cstack_gt_gh_gate() {
  local json
  if ! command -v gh >/dev/null 2>&1; then
    printf '%s\n' error
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' error
    return 0
  fi
  if ! json="$(gh pr view --json number,state,isDraft,mergeStateStatus,labels,statusCheckRollup 2>/dev/null)"; then
    printf '%s\n' error
    return 0
  fi
  printf '%s' "$json" | cstack_gt_gh_gate_from_json
}

cstack_gt_pr_number() {
  gh pr view --json number --jq .number 2>/dev/null || true
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
  echo "cstack-gt-wait-merge: labeling merge-queue on #${number} (Cannot determine + mergeable)" >&2
  gh pr edit "$number" --add-label merge-queue
}

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)
      INTERVAL="${2:?--interval needs a number}"
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

# Clamp: finer than 15–30s, not a hot spin.
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "cstack-gt-wait-merge: --interval must be an integer" >&2
  exit 1
fi
if [ "$INTERVAL" -lt 5 ]; then
  INTERVAL=5
fi
if [ "$INTERVAL" -gt 12 ]; then
  INTERVAL=12
fi

if ! command -v gt >/dev/null 2>&1; then
  echo "cstack-gt-wait-merge: gt not on PATH" >&2
  exit 1
fi

echo "cstack-gt-wait-merge: poll every ${INTERVAL}s (affirmative Ready or label fallback)" >&2

while true; do
  blob="$(gt merge --dry-run --no-interactive 2>&1 || true)"
  kind="$(cstack_gt_classify "$blob")"
  case "$kind" in
    ready)
      echo "cstack-gt-wait-merge: READY — enqueue via gt merge" >&2
      if [ "$DO_MERGE" -eq 1 ]; then
        gt merge --no-interactive
      fi
      finish_ok
      ;;
    queued)
      echo "cstack-gt-wait-merge: already in MQ — stop" >&2
      finish_ok
      ;;
    failed)
      echo "cstack-gt-wait-merge: Required checks failed — stop waiting" >&2
      printf '%s\n' "$blob" >&2
      exit 2
      ;;
    undetermined)
      if [ "$DID_SYNC" -eq 0 ]; then
        echo "cstack-gt-wait-merge: Cannot determine — one gt sync --no-restack, then retry" >&2
        gt sync --no-interactive --no-restack || true
        DID_SYNC=1
        continue
      fi
      echo "cstack-gt-wait-merge: Cannot determine after sync — GH probe (do not gt merge)" >&2
      gate="$(cstack_gt_gh_gate)"
      number="$(cstack_gt_pr_number)"
      case "$gate" in
        labeled)
          echo "cstack-gt-wait-merge: tip already has merge-queue — stop" >&2
          finish_ok
          ;;
        green)
          if label_tip_enqueue "$number"; then
            echo "cstack-gt-wait-merge: ENQUEUED via merge-queue label on #${number}" >&2
            finish_ok
          fi
          echo "cstack-gt-wait-merge: label rejected — HANDOFF: grok-ci-merge" >&2
          exit 2
          ;;
        failed)
          echo "cstack-gt-wait-merge: required GH checks failed — stop waiting" >&2
          exit 2
          ;;
        pending)
          echo "cstack-gt-wait-merge: Cannot determine and GH not mergeable yet — sleep ${INTERVAL}s" >&2
          sleep "$INTERVAL"
          ;;
        error)
          echo "cstack-gt-wait-merge: GH probe failed after Cannot determine — HANDOFF: grok-ci-merge" >&2
          exit 2
          ;;
        *)
          echo "cstack-gt-wait-merge: unknown gate: $gate" >&2
          exit 1
          ;;
      esac
      ;;
    wait)
      echo "cstack-gt-wait-merge: not ready yet — sleep ${INTERVAL}s" >&2
      sleep "$INTERVAL"
      ;;
    *)
      echo "cstack-gt-wait-merge: unknown classify: $kind" >&2
      exit 1
      ;;
  esac
done
