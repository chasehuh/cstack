# GRAPHITE hard lock (paste into every author prompt)

This is the worker-facing lock. Policy detail: `sume-gt-mq/SKILL.md`.
The ready-signal **is the binary** — do not write a sleep/grep loop.

Graphite MQ enqueue has two official paths
([use the merge queue](https://graphite.com/docs/get-started-merge-queue)):

1. App Merge/Queue or CLI `gt merge` — default when dry-run is
   affirmatively Ready.
2. The repo merge label (`merge-queue` on `sume-com`) — enqueue from
   anywhere. Label the **tip**; Graphite copies it downstack.

`gt merge --dry-run` saying `Cannot determine if stack is ready to merge`
is **not** “keep waiting for Ready”. Graphite does not document that
string as a CI-wait signal. Do **not** `gt merge` while the CLI cannot
determine. After one metadata `gt sync --no-interactive --no-restack`,
if required GitHub checks are green and `mergeStateStatus` is
`CLEAN`/`UNSTABLE`, the binary labels the tip. That **is** enqueue.

`HANDOFF: grok-ci-merge` only when required checks are red or the label
is rejected — not because dry-run said Cannot determine.

```text
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md before any gt submit/merge.

GRAPHITE (hard lock):
- Isolated clone only: `CLONE="$(cstack-clone <job-slug>)"` then `cd "$CLONE"`.
  All `gt` commands run in that clone. Forbidden: `git worktree` under the
  shared Cursor checkout (#2383). Forbidden: `gh pr create` (single or stack).
  Publish ONLY via `gt submit`. If submit fails (trunk out of date): new
  `cstack-clone` → cherry-pick/track → `gt submit`. Never `gh pr create`.
- After `gt submit`: SAME session — `cstack-gt-wait-merge`
  (poll 5–12s, default 8s; `--rm <job-slug>` after enqueue).
  That binary is the ready-signal. Do NOT write a `sleep` + `grep` loop.
  Ready = ONLY `Your stack is ready to merge` or `(Ready to merge)` /
  `(Ready to merge as stack)`. Forbidden: substring grep `ready to merge`
  (false-matches `Cannot determine if stack is ready to merge` and
  `not ready to merge`). Failed CI / `Required checks failed` → binary
  exits 2 immediately — break, do NOT keep polling Ready.
  Already merging / already in the merge queue → exit 0 (STOP).
  Cannot determine → do NOT `gt merge`. Binary: one
  `gt sync --no-interactive --no-restack`, retry dry-run; still
  Cannot determine + required GH green + CLEAN/UNSTABLE → label the
  **tip** PR `merge-queue` (Graphite official enqueue-from-anywhere)
  and exit 0. Still pending CI → keep polling. Required failed or
  label rejected → exit 2 / `HANDOFF: grok-ci-merge`.
  Do not wait forever for a Ready that never comes.
- Repo CI flake: ≤2 `gh run rerun --failed`, then minimal CI unblock commit.
  Forbidden: endless rerun with no code change. Still blocked →
  `HANDOFF: grok-ci-merge`.
- Forbidden: ScheduleWakeup then exit before enqueue evidence.
  Stay in-session until enqueue confirmed (no minute cap).
- Own only this train. STOP immediately after enqueue.
  Done report: clone path + Graphite URL + GitHub PR URL + enqueue
  evidence + `LANDED: no` + `NOT 완료` + `HANDOFF: grok-land`.
  After enqueue: `cstack-clone-rm <job-slug>` (or `--rm` on the waiter)
  unless land still needs the tree.
```
