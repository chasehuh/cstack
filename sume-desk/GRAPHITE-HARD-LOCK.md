# STACKS hard lock (paste into every author prompt)

This is the worker-facing lock. Policy detail: `sume-gt-mq/SKILL.md`.
The file keeps its old name; Graphite is retired for `sume` since
2026-10-30. Authors stack with `gh stack` and land through GitHub's merge
queue. The queue step **is the binary** — do not write a sleep/grep loop.

**Chase lock 2026-09-06:** the worker who authored the PR **owns land
through `origin/main` `(#N)`**. Do **not** hand land to another worker.

After `gh stack submit --auto --open`, run `cstack-gt-wait-merge`. It
links the PR chain into one GitHub stack, waits for `validate` on every
layer, then queues the whole stack (`gh stack merge`; one PR:
`gh pr merge --auto --squash`). Then **stay**.

- Every layer gets its own queue run; a failed layer leaves the queue with
  every layer above it, and the layers below it still land.
- Removed from the queue → fix → `gh stack sync` → run the helper again,
  **same session**.
- A push to a queued PR takes it out of the queue: finish edits first.

```text
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md before gh stack submit.

STACKS (hard lock) — Chase 2026-10-30: GitHub stacks + GitHub merge queue; author owns land to origin/main:
- Isolated clone only: `CLONE="$(cstack-clone <job-slug>)"` then `cd "$CLONE"`.
  Forbidden: `git worktree` under a shared checkout (#2383).
  Forbidden: `gh pr create`, `gt`, the `merge-queue` label, `gh pr merge --admin`.
- Author: `gh stack init <branch>` → commit → `gh stack add <branch>` per layer
  → `gh stack submit --auto --open`.
- Then SAME session: `cstack-gt-wait-merge --rm <job-slug>` (waits for validate,
  queues the whole stack). Do NOT write a sleep/grep loop.
- Then **stay until** `git fetch origin main && git log origin/main --oneline --fixed-strings --grep='(#N)'`
  shows every layer. Queue removal → fix → `gh stack sync` → helper again.
  Repo CI flake: ≤2 `gh run rerun --failed`, then minimal CI unblock.
  Forbidden: endless rerun. Forbidden: handing land to another worker.
- Forbidden: ScheduleWakeup then exit before the main tip.
  Queueing is not 완료. Done report only after main-tip proof:
  clone path + GitHub PR URL(s) + SHA(s) + `LANDED: yes`.
  `cstack-clone-rm <job-slug>` after land (keep the tree while unblocking).
- RELEASE (hard lock 2026-10-18, docs/RELEASE-LOCK.md): stop at origin/main
  and a staging candidate. No rc / vX.Y.Z tag, no release dispatch, no
  Production approval. "Do it on prod" is not permission to tag; only a
  release-only job that quotes Chase allowing that release may ship.
- DEST EVIDENCE (hard lock 2026-09-11, #7110): after dest/prod browser verify,
  post ONE `gh issue comment` on the Job issue with 2–4 screenshots + host,
  sumelabs, Auto (not Astra), SHA, pass/fail. Final report must carry
  `SHOTS: <comment URL>`. Forbidden: `DEST: pass` without SHOTS. Forbidden:
  exiting after main land while dest deploy is still building.
```
