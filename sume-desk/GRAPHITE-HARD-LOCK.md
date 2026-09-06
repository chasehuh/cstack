# GRAPHITE hard lock (paste into every author prompt)

This is the worker-facing lock. Policy detail: `sume-gt-mq/SKILL.md`.
The enqueue step **is the binary** — do not write a sleep/grep loop.

**Chase lock 2026-09-06:** the worker who authored the PR **owns land
through `origin/main` `(#N)`**. CI is thinner; do **not** hand MQ babysit
to Grok. `HANDOFF: grok-land` is forbidden on the default path.

After `gt submit`, label the **tip** `merge-queue` immediately
([use the merge queue](https://graphite.com/docs/get-started-merge-queue)).
Do **not** wait for PR CI or `gt merge --dry-run` Ready. Then **stay**.

- Not mergeable yet → Graphite treats the label as Merge when ready.
  `validate` green → the PR enters MQ, then MQ draft CI runs.
- Already mergeable → the label enqueues now.
- Label the tip; Graphite copies it downstack.
- Eject / empty labels → re-enqueue **same session**.
- Pending PR CI is not eject.

```text
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md before any gt submit/merge.

GRAPHITE (hard lock) — Chase 2026-09-06: author owns land to origin/main:
- Isolated clone only: `CLONE="$(cstack-clone <job-slug>)"` then `cd "$CLONE"`.
  All `gt` commands run in that clone. Forbidden: `git worktree` under the
  shared Cursor checkout (#2383). Forbidden: `gh pr create` (single or stack).
  Publish ONLY via `gt submit`. If submit fails (trunk out of date): new
  `cstack-clone` → cherry-pick/track → `gt submit`. Never `gh pr create`.
- After `gt submit`: SAME session — `cstack-gt-wait-merge --rm <job-slug>`.
  Label the **tip** `merge-queue` immediately. Do NOT wait for PR CI,
  dry-run Ready, or `Cannot determine`. Do NOT write a sleep/grep loop.
  Not mergeable yet → Graphite MWR; `validate` green → enters MQ.
  Already labeled / already in MQ → keep going (do not STOP).
  Label rejected → `gh pr edit <N> --add-label merge-queue` and continue.
- Then **stay until** `git fetch origin main && git log origin/main --oneline --grep='(#N)'`.
  Re-enqueue on eject. Repo CI flake: ≤2 `gh run rerun --failed`, then
  minimal CI unblock. Forbidden: endless rerun. Forbidden: `HANDOFF: grok-land`.
- Forbidden: ScheduleWakeup then exit before the main tip.
  Enqueue is not 완료. Done report only after main-tip proof:
  clone path + Graphite URL + GitHub PR URL + SHA + `LANDED: yes`.
  `cstack-clone-rm <job-slug>` after land (keep the tree while unblocking).
```
