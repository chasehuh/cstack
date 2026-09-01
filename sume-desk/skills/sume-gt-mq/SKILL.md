---
name: sume-gt-mq
description: >-
  Sume Graphite (`gt`) author → tip `merge-queue` at submit → land
  playbook for sumelabs/sume-com. Use whenever creating/updating PRs
  with Graphite, running `gt submit`, labeling `merge-queue` (MWR),
  unsticking BLOCKED PRs with zero CI after restack, or handing off
  Grok land babysit. Hard rules against gh pr create, shared-checkout
  worktrees, and exiting before the tip label.
---

# Sume Graphite MQ (`sume-gt-mq`)

**Operational SoT** for `gt` submit → tip `merge-queue` label → land on `sume-com`.

Product / train policy summary still lives in:

`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`
§ **"PR trains and Graphite (`gt`)"**

**Do not fork rules.** If this file and orchestration disagree on ops, **this
file wins for enqueue/land mechanics**; update orchestration to point here.

Repo ops doc: `docs/operations/pr-stack-and-merge-queue.md` (in sume-com).

---

## 완료 = on `origin/main` `(#N)` (Chase lock 2026-08-26)

**Nobody tells Chase “완료 / done / completed / landed” until the change
is actually on trunk.**

Proof (required before those words):

```bash
git fetch origin main
git log origin/main --oneline --grep='(#N)'   # or the landed SHA
```

The log line must exist. Graphite FF may show GitHub `CLOSED` /
`mergedAt: null` — that is still landed **only if** `origin/main` has
`(#N)`.

**Not 완료** (do not say it, do not write a done report that reads as
finished to Chase):

- PR opened / Graphite “Your changes” still lists it
- PR-branch CI green / `gt` Ready / `CLEAN`
- Enqueued / `merge-queue` label / MQ draft open
- `HANDOFF: grok-land` / author STOP after enqueue
- Worker process exited

Author **may** STOP after enqueue (role split). That report must say
**`LANDED: no`** and **`NOT 완료`**. It is a handoff, not a finish.

**Land owner must not STOP at enqueue.** Stay until `origin/main` has
`(#N)`. MQ eject → re-enqueue **same session**. Forbidden: land worker
exits with `HANDOFF: grok-land` (that is handing off to yourself) or
“back in the queue, session stops.”

Main agent: never translate enqueue / green checks into “완료됐습니다”
to Chase. Launch or resume land. Graphite leftover “Your changes” =
land still open.

---

## When you MUST read this skill

Read this file **before** any of:

- `gt create` / `gt submit` / `gt submit --stack`
- After `gt submit` (label the tip `merge-queue` now)
- `merge-queue` label / Graphite MWR / land babysit
- Restack / sync after trunk moves
- Unstick BLOCKED / CI-missing PRs
- Writing `HANDOFF: grok-land` or `HANDOFF: grok-ci-merge`
- Main agent launching Opus/Grok for PR trains

Main-agent Opus prompts on `sume-com` must say:

```text
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md before gt submit/merge.
```

---

## Roles (no fighting)

| Role | Owns | Must not |
|------|------|----------|
| **Opus** (author session) | `cstack-clone` → code → `gt submit` → **`cstack-gt-wait-merge`** (tip `merge-queue` now) → **STOP** with `LANDED: no` / `NOT 완료` → `cstack-clone-rm` | Exit before the label; say 완료; babysit other trains’ PRs |
| **Grok land** | One **owned PR set** only; enqueue if needed → draft CI → **`origin/main` `(#N)`**; re-enqueue on eject | STOP at enqueue; say 완료 before main tip; `gt track` thrash; other stacks |
| **Main agent** | Launch / steer / board; launch Grok after enqueue; **완료 to Chase only after main tip** | Tell Chase 완료 on enqueue/green CI; mid-flight steal of a live owner’s PRs |

**Ownership rule:** one job slug ↔ one PR stack. Parallel trains = parallel
owners. Never two workers label / empty-commit / restack the same head.

---

## Hard locks (sume-com)

1. **Isolated clone only** for all `gt` commands — **`cstack-clone <job-slug>`**  
   → `/tmp/sume-com-<job-slug>` from the bare mirror
   `~/.cstack/mirrors/sume-com.git`.  
   **Forbidden:** `git worktree add` under the shared Cursor checkout (#2383).  
   **Forbidden:** a full `git clone` of `sume-com` when the mirror exists
   (use `cstack-clone`; `--depth=100` is not the cook).  
   After author enqueue (or land `origin/main` `(#N)`): **`cstack-clone-rm
   <slug>`** unless a live worker still has that cwd.
2. **Forbidden:** `gh pr create` (single or stack) as author path.  
   Publish **only** via `gt submit`.
3. **`gt submit` fails** (trunk out of date / poisoned) → **new clone**
   (`cstack-clone --force <slug>` or a new slug) → cherry-pick/track →
   `gt submit`. Never `gh pr create`.
4. After restack/sync: **`gt submit` again** before enqueue.
5. **Primary enqueue = `cstack-gt-wait-merge`** after `gt submit`.
   It labels the **tip** `merge-queue` immediately. Do **not** wait for
   PR CI / dry-run Ready. Do **not** hand-roll a sleep/grep loop.
6. **Opus default enqueue:** tip `merge-queue` label (Graphite MWR if
   CI is still running; enters MQ when `validate` is green). Manual
   fallback if the binary cannot label:
   `gh pr edit <N> --add-label merge-queue`. Do **not** `gt merge` as
   the author wait path.
7. **Author STOP after enqueue is a handoff, not 완료.** Land owner
   stays until `origin/main` has `(#N)`. Grok owns land unless Chase
   said the author owns land (`merge까지` / `landing까지`).

---

## Exit rules (Chase lock 2026-08-07 — failure mode)

These are **failed handoffs**, not “still waiting”:

| Bad | Why | Required |
|-----|-----|----------|
| Arm `Monitor` / `ScheduleWakeup` then **end the session** with “I’ll enqueue when green” | Wrapper exits; label never lands | **Stay in-session** until the tip has `merge-queue` (MWR counts) |
| Done report without enqueue evidence | Looks green, no label | Evidence = tip `merge-queue` label |
| `HANDOFF: grok-land` when never labeled | Grok assumes queued | Use `HANDOFF: grok-ci-merge` **only** if the label was rejected |

**Forbidden:** “wakeup in 20 min” / Monitor / “I’ll merge when checks settle”
then process exit before the label.

---

## Enqueue at submit (Chase lock 2026-09-01)

From the **Graphite-ready author clone**, after `gt submit`:

```bash
cstack-gt-wait-merge --rm <job-slug>
```

That labels the **tip** immediately. Do **not** poll `gt merge --dry-run`.
Do **not** wait for PR CI. Pending CI is Graphite MWR — the PR enters
MQ when `validate` is green. Author STOP after the label.

Land owns PR-CI failure / MQ draft red / eject. Author does not sit
in a Ready loop.

**Forbidden:** `cstack-gt-wait-merge 2>&1 | tail`. Stay until it exits.

### PR / MQ CI failed (land — Chase lock 2026-08-08)

Author does not wait for this. Land:

1. Known repo flake: `gh run rerun --failed` **≤2** on that head.
2. Still red → **minimal CI unblock** (§ F) → `gt submit` → label again
   if the label dropped.
3. Still blocked → `HANDOFF: grok-ci-merge` with evidence.

**Forbidden:** author-side dry-run / `gh pr checks` poll loops after submit.

---

## Clone / disk (Chase lock 2026-09-01)

Graphite wants **one clean repo** and a stack. `#2383` forbids that repo
from being the dirty Cursor checkout (shared `.git` poisons `gt submit`).

Desk BP:

| Piece | Path | Role |
|---|---|---|
| Bare mirror | `~/.cstack/mirrors/sume-com.git` | Object store only. `cstack-mirror-sync` / `cstack-clone --sync-only`. **Do not `gc --prune=now`** while job clones have alternates. |
| Job clone | `/tmp/sume-com-<slug>` | `git clone --reference <mirror>` — **no `--dissociate`**, no `--depth`. Own `.git`, own `gt`. |
| Cursor checkout | `~/sume/sume-com` | Read / chat root. **Never `gt` here. Never `git worktree add` + `gt`.** |
| `node_modules` | per clone | Still `pnpm install --prefer-offline`. Do not symlink across clones. |

Binaries (install.sh puts them on `~/.local/bin`):

```bash
cstack-clone <job-slug>           # stdout = /tmp/sume-com-<slug> only
cstack-clone --force <job-slug>   # wipe + remake
cstack-mirror-sync                # fetch main into the mirror
cstack-clone-rm <job-slug>        # after enqueue / land; refuses live cwd
cstack-gt-wait-merge [--rm <slug>]  # after gt submit; label tip now
```

`CLONE="$(cstack-clone <slug>)"` is the cook. Progress is stderr.

**Seed:** if `$CSTACK_SEED_REPO` (default `$HOME/sume/sume-com`) exists,
the first mirror is `git clone --bare` from that tree, then `origin` is
GitHub. **Do not** `--reference` the Cursor `.git` — it is shallow and
git rejects it.

**Fetch:** **main only.** Never `+refs/heads/*` (that pulls every
`gtmq_*` branch into the mirror).

---

## Canonical flow

```text
cstack-clone <slug> → gt init → gt create → commit(s) → gt submit [--stack]
  → cstack-gt-wait-merge --rm <slug>   # label tip now; same session
  → enqueue evidence
  → AUTHOR: STOP + LANDED: no + NOT 완료 + HANDOFF: grok-land
  → cstack-clone-rm <slug> (unless land still needs the clone)
  → LAND: do not STOP — watch MQ → re-enqueue on eject → origin/main (#N)
  → only then STATUS: landed (Chase 완료)
```

Stack: **all layers one session** → `gt submit --stack` → label the **tip**.
Do not “land A only → resume for B”.

---

## Enqueue evidence (required in done report)

At least one of:

- Graphite / `gt` output showing queued / merge requested
- `merge-queue` label present on the PR(s)
- Graphite activity / MQ draft reference

Plus: clone path + Graphite URL + GitHub PR URL(s) + **`LANDED: no`** +
**`NOT 완료`** + `HANDOFF: grok-land` (or `grok-ci-merge`).

Author enqueue evidence is **not** a Chase-facing “done.”

---

## Unstick playbook (owned stack only)

### A. After lower PR lands / restack: `mergeStateStatus=BLOCKED`, **zero CI.yml checks**

Symptom: head only has Vercel + Graphite mergeability; Format/Test/… missing.

1. Confirm ownership (your slug’s PRs).
2. In Graphite-ready clone (or push access to head): **empty commit** + push to
   re-fire `ci.yml` (same pattern as wallet #2769).
3. Keep or re-add `merge-queue` on the **tip**. Do not wait for Ready.
4. Do not open a new PR.

### B. Superseded / cancelled validate “fail”

Ignore cancelled runs on old SHAs. Judge current head. Re-label the tip
if the label dropped.

### C. Mid-stack Graphite CI optimizer `skipping`

Expected on intermediate stack PRs. Label the **tip**.

### D. MQ draft red

Grok land: fix or bounce to Opus. Do not thrash restack while Graphite says
already merging unless entry failed / evicted.

### E. Graphite FF land

`CLOSED` + `mergedAt: null` can still be landed. Truth = `main` tip `(#N)`.

### F. Repo-wide CI flake blocking enqueue (Chase lock 2026-08-07)

Incident class: Opus `sentry-cutover-stack` / `studio-stream-arch-100k`
sat in endless `gh run rerun` while `studio-agent-core` Vitest **5s
timeouts** / EPIPE / pool death hit **unrelated PRs** the same way. Product
diff was green locally; enqueue never happened.

**Diagnosis (do this first, ≤2 evidence points):**

- Fail set **shifts** across reruns (different files each time), or
- Same timeout/EPIPE signature on an **unrelated** PR touching the same
  package, or
- Local package suite green in seconds while CI blows 5s defaults

→ Treat as **repo flake / runner overload**, not “keep retrying my product
PR forever.”

**Allowed after 1–2 failed reruns (same head):**

1. **Minimal CI unblock commit** on the owned train (fresh clone →
   `gt create` / amend tip → `gt submit` again), e.g.:
   - package `vitest.config` `testTimeout` bump for known load-flake suites
   - isolate/timeout only the known `sandbox-runner.*` class
   - empty commit to re-fire CI **only** if prior run was cancelled/missing
     jobs (playbook A) — not as a substitute for a real flake fix
2. Keep scope **CI-only**. Do not expand product locks to “fix CI.”
3. Then `gt submit` again if the tip moved → `cstack-gt-wait-merge`
   (label again if the label dropped).

**Forbidden:**

- Infinite / double-digit `gh run rerun --failed` with **zero code change**
- Simultaneous mass-reruns of many PRs that overload the self-hosted pool
- Calling flake “not my problem” then **STOP without enqueue** and no
  `HANDOFF: grok-ci-merge` — either unblock or hand off explicitly
- Large suite rewrites / unrelated refactors as “CI fix”

**Handoff:** If you still cannot enqueue after a minimal unblock + green
(or Chase killed the loop): done report with flake evidence →
**`HANDOFF: grok-ci-merge`**.

---

## Grok land (after enqueue — stay until main)

1. **Do not re-enqueue** if already queued **and still in MQ**.
   Evicted / labels empty / Graphite “Your changes” leftover →
   **re-enqueue same session**. Do not exit.
2. Own **only** the handed-off PR numbers.
3. Watch MQ draft CI; act on red only.
4. **Do not STOP / do not say 완료** until
   `git fetch origin main && git log origin/main --oneline --grep='(#N)'`
   shows the commit.
5. Issue comment + STOP **only after** that proof.

Forbidden land exits:

- `HANDOFF: grok-land` (you **are** land)
- “back in the queue, this session stops”
- Done report that only lists enqueue evidence

`HANDOFF: grok-ci-merge`: if the tip has no `merge-queue` label, **label
now** (do not wait for PR CI). Then **stay until main tip**. If PR never
Graphite-bound → reject; repair with fresh-clone `gt submit` first.
Label present + CI still running is **MWR, not eject**.

Grok land from a Cursor main agent: **`agent-human-stream --backend grok`**
in a background Shell (`block_until_ms: 0`, title `Grok : <job-slug> (#N)`).
Do **not** use Cursor `Task` / `cursor-grok-*` for land.

---

## Delegation block (paste into Opus prompts)

Same text: `sume-desk/GRAPHITE-HARD-LOCK.md` in chasehuh/cstack.

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

**Grok land prompt must also say:** stay until `origin/main` `(#N)`;
re-enqueue on eject; forbidden to STOP at enqueue or write `HANDOFF:
grok-land` from the land session.

---

## Pointers

- Orchestration (routing, Chase loop): `sume-main-agent-orchestration`
- Cursor ready-signal rule: `~/.cursor/rules/graphite-ci-ready.mdc`
- Opus Shell cookbook: `~/.cursor/rules/opus-background-terminal.mdc`
- Chase loop: `~/.cursor/rules/sume-chase-work-loop.mdc`
