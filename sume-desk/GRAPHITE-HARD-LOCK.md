# GRAPHITE hard lock (paste into every author prompt)

This is the worker-facing lock. Policy detail: `sume-gt-mq/SKILL.md`.
The enqueue step **is the binary** — do not write a sleep/grep loop.

After `gt submit`, label the **tip** `merge-queue` immediately
([use the merge queue](https://graphite.com/docs/get-started-merge-queue)).
Do **not** wait for PR CI or `gt merge --dry-run` Ready.

- Not mergeable yet → Graphite treats the label as Merge when ready.
  `validate` green → the PR enters MQ, then MQ draft CI runs.
- Already mergeable → the label enqueues now.
- Label the tip; Graphite copies it downstack.

`HANDOFF: grok-ci-merge` only if the label is rejected (or land CI is
truly blocked). Pending PR CI is not blocked.

```text
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md before any gt submit/merge.

GRAPHITE (hard lock):
- Isolated clone only: `CLONE="$(cstack-clone <job-slug>)"` then `cd "$CLONE"`.
  All `gt` commands run in that clone. Forbidden: `git worktree` under the
  shared Cursor checkout (#2383). Forbidden: `gh pr create` (single or stack).
  Publish ONLY via `gt submit`. If submit fails (trunk out of date): new
  `cstack-clone` → cherry-pick/track → `gt submit`. Never `gh pr create`.
- After `gt submit`: SAME session — `cstack-gt-wait-merge --rm <job-slug>`.
  Label the **tip** `merge-queue` immediately. Do NOT wait for PR CI,
  dry-run Ready, or `Cannot determine`. Do NOT write a sleep/grep loop.
  Not mergeable yet → Graphite MWR; `validate` green → enters MQ.
  Already labeled / already in MQ → exit 0.
  Label rejected → exit 2 / `HANDOFF: grok-ci-merge`.
- Repo CI flake (land, after the PR is in CI/MQ): ≤2 `gh run rerun --failed`,
  then minimal CI unblock. Forbidden: endless rerun. Still blocked →
  `HANDOFF: grok-ci-merge`.
- Forbidden: ScheduleWakeup then exit before the label is on the tip.
  Enqueue evidence = `merge-queue` label (MWR counts). Then STOP.
- Own only this train. STOP immediately after the label.
  Done report: clone path + Graphite URL + GitHub PR URL + enqueue
  evidence + `LANDED: no` + `NOT 완료` + `HANDOFF: grok-land`.
  After enqueue: `cstack-clone-rm <job-slug>` (or `--rm` on the binary)
  unless land still needs the tree.
```
