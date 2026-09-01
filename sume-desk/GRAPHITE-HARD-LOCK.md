# GRAPHITE hard lock (paste into every author prompt)

This is the worker-facing lock. Policy detail: `sume-gt-mq/SKILL.md`.
The ready-signal **is the binary** — do not write a sleep/grep loop.

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
  Cannot determine → binary keeps waiting (do NOT `gt merge`).
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
