---
name: sume-gt-mq
description: >-
  Sume stack author → GitHub merge queue → land playbook for sumelabs/sume
  (sume-com). Use whenever creating/updating PRs with `gh stack`, running
  `gh stack submit`, queueing with `cstack-gt-wait-merge`, or unsticking a
  PR the queue removed. The author session stays until origin/main. Hard
  rules against gh pr create, shared-checkout worktrees, admin bypass,
  handing land to another worker, and exiting before the main tip.
---

# Sume stacks and GitHub merge queue (`sume-gt-mq`)

**Operational SoT** for `gh stack submit` → `cstack-gt-wait-merge` → land
on `sume-com`. The skill keeps its old name; Graphite (`gt`, the
`merge-queue` label, Graphite's queue) is retired for `sume` since
2026-10-30 (Chase, during Graphite's merge-queue outage).

Repo ops doc: `docs/operations/pr-stack-and-merge-queue.md` (in sume-com).
Failures runbook: `docs/operations/merge-queue-failures.md`.

**Do not fork rules.** If this file and orchestration disagree on ops, **this
file wins for queue/land mechanics**; update orchestration to point here.

---

## 완료 = on `origin/main` `(#N)` (Chase lock 2026-08-26)

**Nobody tells Chase “완료 / done / completed / landed” until the change
is actually on trunk.**

Proof (required before those words), for **every** layer:

```bash
git fetch origin main
git log origin/main --oneline --fixed-strings --grep='(#N)'
```

GitHub squash-merges each PR as `<title> (#N)` and marks it `MERGED`.

**Not 완료** (do not say it, do not write a done report that reads as
finished to Chase):

- PR opened / `gh stack view` lists it open
- PR-branch CI green / `CLEAN`
- Queued (`cstack-gt-wait-merge` exited 0, the queue page lists it)
- Author STOP after queueing
- Worker process exited

**Chase lock 2026-09-06:** the **author session owns land**. Do not STOP
after queueing. Stay until `origin/main` has every `(#N)`. Queue removal →
fix → re-queue **same session**. Never hand land to another worker.

Main agent: never translate queueing / green checks into “완료됐습니다”
to Chase. If the author exited early, **steer that same session**
(`sume-bg-launch --host mini --resume <uuid>`); never launch a second land
worker.

---

## When you MUST read this skill

Read this file **before** any of:

- `gh stack init` / `gh stack add` / `gh stack submit`
- `cstack-gt-wait-merge` (queueing), land babysit
- Restack / sync after a lower layer lands or review edits
- Unsticking a PR the queue removed
- Exiting before the main tip
- Main agent launching Opus **author** trains

Main-agent author prompts on `sume-com` must say:

```text
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md before gh stack submit.
```

---

## Roles (no fighting)

| Role | Owns | Must not |
|------|------|----------|
| **Author** (Opus; Fable if named) | `cstack-clone` → code → `gh stack submit` → **`cstack-gt-wait-merge`** → queue runs → **`origin/main` `(#N)` for every layer** → then `cstack-clone-rm` | STOP at queueing; hand land to another worker; say 완료 before main tip; other trains |
| **Main agent** | Launch / fork / steer; steer the **same** author if they exited early; **완료 to Chase only after main tip** | Launch a separate land worker; tell Chase 완료 on queueing/green CI |

**Ownership rule:** one job slug ↔ one PR stack. Parallel trains = parallel
owners. Never two workers queue / push / restack the same head.

---

## Hard locks (sume-com)

1. **Isolated clone only** — **`cstack-clone <job-slug>`** →
   `/tmp/sume-com-<job-slug>` from the bare mirror
   `~/.cstack/mirrors/sume-com.git`.
   **Forbidden:** `git worktree add` under the shared Cursor checkout (#2383).
   After land: **`cstack-clone-rm <slug>`** unless a live worker still has
   that cwd.
2. **Publish only via `gh stack submit --auto --open`.** It pushes every
   layer, opens ready PRs with the right bases and links them into one
   GitHub stack. **Forbidden:** `gh pr create` (single or stack).
3. **Queue only via `cstack-gt-wait-merge`.** It walks the PR chain from the
   tip, marks drafts ready, links the chain into a stack, waits for
   `validate` on every layer, then runs `gh stack merge <tip> --yes` (a
   stack) or `gh pr merge <N> --auto --squash` (one PR). Do **not** hand-roll
   a sleep/grep loop.
4. **Forbidden:** `gh pr merge --admin`, a direct push to `main`, or any
   queue bypass without Chase's word for that PR. GitHub can bypass only the
   bottom layer of a stack anyway.
5. **Retired:** `gt create` / `gt submit` / `gt merge` and the
   `merge-queue` label (Graphite's queue for `sume` is off; the label does
   nothing). A stack opened by `gt submit` before the switch still lands:
   run `cstack-gt-wait-merge` from its tip.
6. **Author stays after queueing.** Land is the same session until
   `origin/main` has every `(#N)`.

---

## What GitHub's queue does (probe #17991–#17995, 2026-10-30)

- Every layer is its own queue entry with its own `merge_group` run of the
  full suite (Typecheck and Format, Test 1–4, Build). Layer N's run is built
  on layer N−1's squash commit, so it tests that layer's diff.
- When a layer fails in the queue, the queue removes it and every layer
  above it. **A layer below it still lands on its own.**
- When every layer passes, the stack lands together: one squash commit per
  PR, bottom first.
- A push to a queued PR removes it from the queue. Finish every edit before
  `cstack-gt-wait-merge`.

---

## Exit rules (Chase lock 2026-08-07 — failure mode)

These are **failed handoffs**, not “still waiting”:

| Bad | Why | Required |
|-----|-----|----------|
| Arm `Monitor` / `ScheduleWakeup` then **end the session** with “I’ll queue when green” | Wrapper exits; nothing queues | **Stay in-session**; `cstack-gt-wait-merge` waits for `validate` itself |
| Done report without queue evidence | Looks green, nothing queued | Evidence = the helper's `QUEUED` line or the queue page |
| Handing land to another worker | Wrong split (2026-09-06) | Author queues + stays until main |

---

## Clone / disk (Chase lock 2026-09-01)

| Piece | Path | Role |
|---|---|---|
| Bare mirror | `~/.cstack/mirrors/sume-com.git` | Object store only. `cstack-mirror-sync` / `cstack-clone --sync-only`. **Do not `gc --prune=now`** while job clones have alternates. |
| Job clone | `/tmp/sume-com-<slug>` | `git clone --reference <mirror>` — **no `--dissociate`**, no `--depth`. Own `.git`, own `gh stack` state. |
| Cursor checkout | `~/sume/sume-com` | Read / chat root. **Never author here. Never `git worktree add`.** |
| `node_modules` | per clone | Still `pnpm install --prefer-offline`. Do not symlink across clones. |

Binaries (install.sh puts them on `~/.local/bin`):

```bash
cstack-clone <job-slug>             # stdout = /tmp/sume-com-<slug> only
cstack-clone --force <job-slug>     # wipe + remake
cstack-mirror-sync                  # fetch main into the mirror
cstack-clone-rm <job-slug>          # after land; refuses live cwd
cstack-gt-wait-merge [--rm <slug>]  # after gh stack submit; queue the stack
```

`gh stack` is a gh extension: `gh extension install github/gh-stack`
(install.sh does it).

**Fetch:** **main only.** Never `+refs/heads/*` (that pulls every queue and
author branch into the mirror).

---

## Canonical flow

```text
CLONE="$(cstack-clone <slug>)" && cd "$CLONE"
gh stack init <branch-1>               # bottom layer, based on main
  → edit + git commit
gh stack add <branch-2>                # each extra layer, same session
  → edit + git commit
gh stack submit --auto --open          # push, open ready PRs, link the stack
cstack-gt-wait-merge --rm <slug>       # validate green → whole stack queued
  → AUTHOR stays: queue runs → fix + re-queue on removal → origin/main (#N) ×layers
  → LANDED: yes (PR URLs + main SHAs)
```

All layers in one session. Do not “land A only → resume for B”. Review
edits to a lower layer: `gh stack down` / `gh stack up` → commit →
`gh stack sync` → `cstack-gt-wait-merge` again.

---

## Queue evidence (required in done report)

- `cstack-gt-wait-merge: QUEUED #a #b — tip #b is queued` (or `merged`)
- or the queue page <https://github.com/sumelabs/sume/queue/main> listing them

Plus: clone path + GitHub PR URL(s) + stack URL. Queue-only reports must
say **`LANDED: no`** and **keep the session**. Chase-facing done only after
main-tip proof + **`LANDED: yes`**.

---

## Unstick playbook (owned stack only)

Runbook in sume-com: `docs/operations/merge-queue-failures.md`.

### A. The queue removed a layer (its `merge_group` run is red)

1. `gh run list --event merge_group --limit 10`, then
   `gh run view <run> --log-failed`.
2. Real failure → fix in the owning layer, `gh stack sync`,
   `cstack-gt-wait-merge` again. Lower layers that already landed stay
   landed; the helper queues what is left.
3. Known flake → § F.

### B. Helper exit 3 (`validate` failed on a PR head)

Review CI is thin: a red PR `validate` means a review job failed (Format,
CSS-module purity, a script test). Fix, `gh stack sync`, run again.

### C. Helper exit 4 (`validate` still pending)

No CI at a head (a push GitHub did not run): push a real commit to that
layer or dispatch ci.yml with `base_sha`; then run the helper again.

### D. Every queue run fails the same unrelated test

Something reached `main` outside the queue and broke it (2026-10-30:
migration `0165` after a direct merge). Fix `main` in its own PR at the
bottom of your stack.

### E. `gh stack submit`: "Stacked PRs are not enabled for this repository" (exit 9)

Stacked PRs are on for `sumelabs/sume`. gh-stack (v0.3.0, `cmd/submit.go`)
prints this warning and exits 9 when its preflight
`GET repos/<owner>/<repo>/stacks` fails **for any reason**. It drops the
real error, so a timeout, a TLS handshake timeout, a 5xx or a rate limit
all look like "not enabled". It checks before it pushes, so nothing is on
GitHub yet.

Incident: on 2026-11-01 at 04:10Z the `sentry-since-1031` 3-layer submit
hit this while the Mini's GitHub traffic was timing out (other sessions
logged `net/http: TLS handshake timeout` to api.github.com at 04:04Z and
04:16Z). Stacks #18086 (04:28Z) and #18090 (04:31Z) opened on the same
repo minutes later.

1. Probe: `gh api 'repos/sumelabs/sume/stacks?per_page=1' --silent && echo ok`.
2. If that prints `ok`, or fails with a network error, the cause was the
   network. Wait for `gh api rate_limit` to answer, then run
   `gh stack submit --auto --open` again.
3. Only a steady `HTTP 404` on that probe means stacks are off. Report it
   to main. Do not change repo settings.

Do not split the layers into one-PR stacks to get around it.

### F. Repo-wide CI flake blocking land (Chase lock 2026-08-07)

Incident class: Opus `sentry-cutover-stack` / `studio-stream-arch-100k`
sat in endless `gh run rerun` while `studio-agent-core` Vitest **5s
timeouts** / EPIPE / pool death hit **unrelated PRs** the same way. Product
diff was green locally; nothing landed.

**Diagnosis (do this first, ≤2 evidence points):**

- Fail set **shifts** across reruns (different files each time), or
- Same timeout/EPIPE signature on an **unrelated** PR touching the same
  package, or
- Local package suite green in seconds while CI blows 5s defaults

→ Treat as **repo flake / runner overload**, not “keep retrying my product
PR forever.”

**Allowed after 1–2 failed reruns (same head):**

1. **Minimal CI unblock commit** on the owned train (a new bottom layer or
   an amend), e.g. a package `vitest.config` `testTimeout` bump for a known
   load-flake suite.
2. Keep scope **CI-only**. Do not expand product locks to “fix CI.”
3. `gh stack sync` → `cstack-gt-wait-merge`.

**Forbidden:**

- Infinite / double-digit `gh run rerun --failed` with **zero code change**
- Simultaneous mass-reruns of many PRs that overload the self-hosted pool
- Calling flake “not my problem” then **STOP without land**
- Large suite rewrites / unrelated refactors as “CI fix”

If you still cannot land after a minimal unblock: stay, report flake
evidence to main; do not hand land to another worker.

---

## Author land (after queueing — stay until main)

1. **Do not re-queue** while the PR is still in the queue.
   Removed → fix → **re-queue same session**. Do not exit.
2. Own **only** this train.
3. Watch the `merge_group` runs; act on red only.
4. **Do not STOP / do not say 완료** until
   `git fetch origin main && git log origin/main --oneline --fixed-strings --grep='(#N)'`
   shows every layer.
5. Issue comment + STOP **only after** that proof.

---

## Delegation block (paste into author prompts)

Same text: `sume-desk/GRAPHITE-HARD-LOCK.md` in chasehuh/cstack.

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
```

---

## Pointers

- Orchestration (launch, fork, steer, Chase loop): `sume-main-agent-orchestration`
