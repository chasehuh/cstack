---
name: sume-gt-mq
description: >-
  Sume Graphite (`gt`) author → MQ enqueue → land ownership playbook for
  sumelabs/sume-com. Use whenever creating/updating PRs with Graphite, waiting
  on review CI, running `gt submit` / `gt merge`, adding `merge-queue`,
  unsticking BLOCKED PRs with zero CI after restack, or handing off Grok land
  babysit. Hard rules against gh pr create, shared-checkout worktrees, and
  exiting before enqueue evidence.
---

# Sume Graphite MQ (`sume-gt-mq`)

**Operational SoT** for `gt` submit → Ready → enqueue → land on `sume-com`.

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
- Waiting on review CI / “Ready to merge”
- `gt merge` / `merge-queue` label
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
| **Opus** (author session) | `cstack-clone` → code → `gt submit` → wait **`gt` Ready** → **`gt merge`** → enqueue evidence → **STOP** with `LANDED: no` / `NOT 완료` → `cstack-clone-rm` | Exit before enqueue; say 완료; babysit other trains’ PRs |
| **Grok land** | One **owned PR set** only; enqueue if needed → draft CI → **`origin/main` `(#N)`**; re-enqueue on eject | STOP at enqueue; say 완료 before main tip; `gt track` thrash; other stacks |
| **Main agent** | Launch / steer / board; launch Grok after enqueue; **완료 to Chase only after main tip** | Tell Chase 완료 on enqueue/green CI; mid-flight steal of a live owner’s PRs |

**Ownership rule:** one job slug ↔ one PR stack. Parallel trains = parallel
owners. Never two workers `gt merge` / empty-commit / restack the same head.

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
5. **Primary ready-signal = `cstack-gt-wait-merge`** (wraps
   `gt merge --dry-run` / `gt` Ready). Not `gh pr checks` loops. Poll
   **5–12s** (default **8s**); affirmative ready → merge **immediately**.
   Do **not** hand-roll a sleep/grep loop (see Ready-signal +
   `graphite-ci-ready.mdc`).
6. **Opus default enqueue:** `gt merge --no-interactive` when dry-run is
   affirmatively Ready (same clone). **Cannot determine + mergeable:**
   the same binary labels the **tip** `merge-queue` (Graphite official
   enqueue-from-anywhere). Do **not** `gt merge` while the CLI cannot
   determine. Manual fallback if the binary cannot label:
   `gh pr edit <N> --add-label merge-queue`.
7. **Author STOP after enqueue is a handoff, not 완료.** Land owner
   stays until `origin/main` has `(#N)`. Grok owns land unless Chase
   said the author owns land (`merge까지` / `landing까지`).

---

## Exit rules (Chase lock 2026-08-07 — failure mode)

These are **failed handoffs**, not “still waiting”:

| Bad | Why | Required |
|-----|-----|----------|
| Arm `Monitor` / `ScheduleWakeup` / background `until` then **end the session** with “I’ll enqueue when green” | Wrapper exits; enqueue never runs | **Stay in-session** until `gt merge` (or label fallback) **succeeds** and enqueue evidence is in the done report — **no minute cap** |
| Done report without enqueue evidence | Looks green, MQ empty | Evidence required (below) |
| `HANDOFF: grok-land` when never enqueued | Grok assumes queued | Use `HANDOFF: grok-ci-merge` **only** if submit done but enqueue truly blocked (required checks red, or tip `merge-queue` label rejected). `Cannot determine` + mergeable is **not** blocked — the binary must label. |

**Allowed while waiting:** tight poll in the **same** live session (below).  
**Forbidden:** “wakeup in 20 min” / Monitor / “I’ll merge when checks settle”
then process exit before enqueue.

---

## Ready-signal + poll loop (Chase lock 2026-08-07)

From the **Graphite-ready author clone**. **Primary ready probe =
`gt merge --dry-run`** (also accept `gt info` / `gt log` Ready).

| Signal | Action |
|--------|--------|
| `gt merge --dry-run` → ready / `Your stack is ready to merge` | **Immediately** `gt merge --no-interactive` (no extra sleep) |
| `gt info` / `gt log` → **`(Ready to merge)`** or **`(Ready to merge as stack)`** | Same — merge now |
| `(Waiting on CI...)` only (no failed) | Sleep **5–12s** (default **8s**), re-probe dry-run |
| **`Cannot determine if stack is ready to merge`** | CLI undecided — **not Ready**. Do **not** `gt merge`. Binary: one `gt sync --no-interactive --no-restack`, retry dry-run; still undetermined + required GH green + `CLEAN`/`UNSTABLE` → label the **tip** `merge-queue` and exit 0. Still pending CI → keep polling. Required failed or label rejected → exit 2. Do **not** wait forever for Ready. |
| **`Required checks failed`** / `Failed CI` / dry-run ERROR with failed checks | **Break immediately — do NOT sleep.** Act (below). Never treat failed as “still waiting.” |

### On dry-run CI **failed** (Chase lock 2026-08-08 — snappy)

`Waiting on CI` ≠ `Required checks failed`. The second will **never** become
Ready by polling. Same session, same turn:

1. Stop the wait loop (**no** further `sleep` / dry-run-only iterations).
2. Known repo flake (EPIPE / shifting timeouts / same sig on unrelated PRs):
   `gh run rerun --failed` **≤2** on that head — then resume dry-run poll.
3. Still red → **minimal CI unblock** (§ F) → `gt submit` → dry-run → merge.
4. Still blocked → `HANDOFF: grok-ci-merge` with evidence. Do **not** sit in
   dry-run until Ready.

**Forbidden:** dry-run poll / `for i in 1..N; sleep` while the last dry-run
already said **Required checks failed**. That is the “infinite wait for a
Ready that never comes” failure mode.

### Poll cookbook (required shape)

**Do not write this loop.** The binary is the ready-signal:

```bash
# After gt submit / gt submit --stack — SAME session, no minute cap:
cstack-gt-wait-merge --rm <job-slug>
# poll 5–12s (default 8s). Affirmative Ready only.
# Ready → gt merge immediately. Already in MQ → exit 0.
# Cannot determine + mergeable → label tip merge-queue, exit 0.
# Required checks failed / Failed CI / label rejected → exit 2.
```

Do **not** pipe the waiter (`cstack-gt-wait-merge 2>&1 | tail`). Stay
until it exits.

(`exit 2` = leave the wait loop into the failure handler in the same session —
rerun / unblock / handoff — not “end the Opus job empty-handed.”)

**Hard poll rules:**

1. **Cap sleep at 12s** per iteration (prefer **8s**, min 5s).
   **Forbidden default:** `sleep 20` / `sleep 60` / `sleep 75` / `sleep 180`.
2. On dry-run **ready** → **break immediately** → real `gt merge`. Do not
   finish a fixed `for i in 1..N` that keeps sleeping after green.
3. On dry-run **Required checks failed** → **break immediately** → act
   (rerun/fix). Do not keep sleeping “until Ready.”
4. Prefer the binary over grepping `gt log` for a single PR’s Ready string
   (stack tip Ready is what enqueue needs).
5. **Forbidden:** substring `grep -qiE 'ready to merge'` (false-matches
   `Cannot determine if stack is ready to merge` and `not ready to merge`).
6. **Forbidden primary wait:** `sleep N; gh pr checks`.
7. **Forbidden:** a hand-rolled `while sleep; grep` when
   `cstack-gt-wait-merge` is on PATH.
8. **Forbidden:** treat `Cannot determine` as infinite wait when GitHub
   required checks are already green and `mergeStateStatus` is
   `CLEAN`/`UNSTABLE`. That is enqueue time — label the tip. Do **not**
   `gt merge` in that state.

**Ignore as “CI red”:** ignored/cancelled Vercel rows; alone
`mergeStateStatus=UNSTABLE`; alone pending `Graphite / mergeability_check`
when `gt` already says Ready / dry-run ready.

**`gh pr checks`:** fallback only if `gt` broken. Filter required jobs
(Format / Typecheck / Test / Build / validate / Graphite CI optimizer).  
**HTTP 401 ≠ pending** — fix auth, return to `gt`.

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
cstack-gt-wait-merge [--rm <slug>]  # after gt submit; poll 5–12s, then merge
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
  → cstack-gt-wait-merge --rm <slug>   # 5–12s, default 8s; same session
  → enqueue evidence
  → AUTHOR: STOP + LANDED: no + NOT 완료 + HANDOFF: grok-land
  → cstack-clone-rm <slug> (unless land still needs the clone)
  → LAND: do not STOP — watch MQ → re-enqueue on eject → origin/main (#N)
  → only then STATUS: landed (Chase 완료)
```

Stack: **all layers one session** → `gt submit --stack` → one `gt merge` for
the train. Do not “land A only → resume for B”.

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
3. Wait `gt` Ready → ensure `merge-queue` still on → enqueue if not queued.
4. Do not open a new PR.

### B. Superseded / cancelled validate “fail”

Ignore cancelled runs on old SHAs. Judge current head + `gt` Ready.

### C. Mid-stack Graphite CI optimizer `skipping`

Expected on intermediate stack PRs. Tip / `gt` Ready is SoT.

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
3. Then return to dry-run poll → `gt merge`.

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

`HANDOFF: grok-ci-merge`: wait ready → **label** (no clone for `gt merge`) →
**stay until main tip**. If PR never Graphite-bound → reject; repair with
fresh-clone `gt submit` first.

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

**Grok land prompt must also say:** stay until `origin/main` `(#N)`;
re-enqueue on eject; forbidden to STOP at enqueue or write `HANDOFF:
grok-land` from the land session.

---

## Pointers

- Orchestration (routing, Chase loop): `sume-main-agent-orchestration`
- Cursor ready-signal rule: `~/.cursor/rules/graphite-ci-ready.mdc`
- Opus Shell cookbook: `~/.cursor/rules/opus-background-terminal.mdc`
- Chase loop: `~/.cursor/rules/sume-chase-work-loop.mdc`
