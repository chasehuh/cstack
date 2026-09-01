#!/usr/bin/env bash
# Wait until Graphite may enqueue, then `gt merge`. Affirmative ready only.
# Finer poll so Ready → merge without a 20s tail. Do not hand-roll this loop.
#
# Usage (from the author clone cwd):
#   cstack-gt-wait-merge
#   cstack-gt-wait-merge --interval 8
#   cstack-gt-wait-merge --no-merge
#   cstack-gt-wait-merge --rm <job-slug>     # after successful enqueue
#   cstack-gt-wait-merge --classify-stdin    # test hook (no gt)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INTERVAL="${CSTACK_GT_WAIT_INTERVAL:-8}"
DO_MERGE=1
RM_SLUG=""
CLASSIFY_STDIN=0

usage() {
  cat <<'EOF'
cstack-gt-wait-merge — poll `gt merge --dry-run` then enqueue.

  --interval N     seconds between polls (5–12, default 8)
  --no-merge       wait/classify only; do not run `gt merge`
  --rm SLUG        after enqueue, run `cstack-clone-rm SLUG`
  --classify-stdin classify one dry-run blob from stdin (exit 10/11/12/13)
  -h, --help

Ready (affirmative only):
  Your stack is ready to merge
  (Ready to merge)
  (Ready to merge as stack)

NOT ready (keep waiting):
  Cannot determine if stack is ready to merge
  not ready to merge
  (Waiting on CI...)

Failed (exit 2, no more sleep):
  Required checks failed
  Failed CI

Already queued (exit 0):
  already merging
  already in the merge queue
EOF
}

# Classify a `gt merge --dry-run` blob. Prints: ready|queued|failed|wait
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

  printf '%s\n' wait
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

echo "cstack-gt-wait-merge: poll every ${INTERVAL}s (affirmative Ready only)" >&2

while true; do
  blob="$(gt merge --dry-run --no-interactive 2>&1 || true)"
  kind="$(cstack_gt_classify "$blob")"
  case "$kind" in
    ready)
      echo "cstack-gt-wait-merge: READY — enqueue now" >&2
      if [ "$DO_MERGE" -eq 1 ]; then
        gt merge --no-interactive
      fi
      if [ -n "$RM_SLUG" ]; then
        "$SCRIPT_DIR/cstack-clone-rm.sh" "$RM_SLUG" || true
      fi
      exit 0
      ;;
    queued)
      echo "cstack-gt-wait-merge: already in MQ — stop" >&2
      if [ -n "$RM_SLUG" ]; then
        "$SCRIPT_DIR/cstack-clone-rm.sh" "$RM_SLUG" || true
      fi
      exit 0
      ;;
    failed)
      echo "cstack-gt-wait-merge: Required checks failed — stop waiting" >&2
      printf '%s\n' "$blob" >&2
      exit 2
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
