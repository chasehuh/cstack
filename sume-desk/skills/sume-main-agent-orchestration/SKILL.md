---
name: sume-main-agent-orchestration
description: Sume main-agent orchestration. Use when the current thread coordinates Opus workers on the M5 Mac Mini (sume-bg-launch --host mini), writes their prompts, forks or steers them, tracks their status, files GitHub mega-issues, or reports to Chase instead of implementing code itself. Covers model/effort picks, fork vs steer, land through origin/main, release lock, Slack reports and dest evidence.
---

# Sume Main Agent Orchestration

## Purpose

The main agent is Chase's communication, planning and coordination layer.
Workers own scoped execution: investigation, implementation, PR and land,
experiments, monitoring. The main agent keeps Chase oriented, delegates with
clear prompts, reads worker results and decides the next step.

**SoT:** this file (`~/.agents/skills/sume-main-agent-orchestration/`, a
symlink into `chasehuh/cstack`). Do not copy these rules elsewhere; point
here. How the desk got to this shape and what was removed:
`~/.cstack/src/docs/CHANGELOG.md`.

## The desk today (2026-11-01)

| Piece | What runs it |
|---|---|
| Main agent | Claude Code on Chase's laptop (Codex can play the same role; same rules) |
| Workers | Claude **Opus** (`claude-opus-5-5`) through `agent-human-stream`, started with `sume-bg-launch --host mini` |
| Worker host | The **M5** Mac Mini (`sume-desk/hosts.env` → `CSTACK_MINI_SSH_M5`). The M4 runs jobs only when Chase says M4 (`--host m4`) |
| Land | `gh stack submit --auto --open` → `cstack-gt-wait-merge` → the author stays until `origin/main` has `(#N)` (`sume-gt-mq`) |
| Report | The worker posts one Korean report to Slack `#coding-agents` as a new thread (`docs/SLACK-REPORT.md`) |
| Release | Only a release-only job, only on Chase's word for that release (`docs/RELEASE-LOCK.md`) |

Not used now: Grok workers (Chase: "grok 은 일단 필요 없고"), Cursor as the
main agent, Graphite (`gt`) as a land path, Fable unless Chase names it.

**When this harness is the worker** (env `SUME_WORKER_SESSION` or a
`[sume worker session]` preamble): ignore every main-agent rule here. Do the
task in this session and end with the final report. Never launch, resume or
hand off another worker; the launcher refuses nested launches (exit 5) and a
nested process dies with the session (sume#7839).

## Main agent

- Talk to Chase in his language (Korean in → Korean out). Workers always
  work and report in **English**.
- Restate the goal, constraints and current state; pick fork vs fresh vs
  steer; send a precise prompt with done criteria.
- Launch in the background and return control. Do not block on a worker
  unless Chase's next request depends on that exact result. The completion
  notification is the monitor; no sleep/poll loops.
- Read only the worker's `—— final ——` block and `📎 session_id=`; translate
  it into a short update.
- Do not silently implement what Chase expected a worker to do. Tiny
  coordination (reading a log, filing an issue, a status check) is fine.
- Code questions read `origin/main` (`git show origin/main:<path>`), not a
  dirty local checkout.

### 완료 only after `origin/main` (Chase lock 2026-08-26, 2026-09-06)

```bash
git fetch origin main
git log origin/main --oneline --fixed-strings --grep='(#N)'
```

No line → not 완료. Not proof: PR open, green PR checks, queued, a queue run
in progress, worker exited. The author session owns land; if it exited
early, steer **that same session** (`--resume`) to finish. Never launch a
second land worker.

### Release lock (Chase 2026-10-18, `docs/RELEASE-LOCK.md`)

Staging → prod only when Chase allows **that** release. "Do it on prod" /
"hide it on prod" is not permission to tag. Product workers stop at
`origin/main` and a staging candidate and write `RELEASE: needs Chase`.
Never put a tag or release step in a product prompt. After Chase allows a
release, launch a release-only job that quotes his words and the exact SHA.

### Dev only

Dev (`www.dev.sume.com`, Railway development) unless Chase says otherwise.
Prod tests: sumelabs workspace and the desk key only; never paste keys.

## Launching workers

### Prompt file (durable dir)

Write prompts under `~/.cstack/state/prompts/`, not `/tmp` (a `/tmp` dir
vanished mid-day on 2026-11-01 and a launch failed with
`--prompt-file not found`). `sume-bg-launch --prompt-dir` creates and prints
the dir.

```bash
P="$(sume-bg-launch --prompt-dir)/<job-slug>.md"
cat > "$P" <<'EOF'
# Opus: <what, one line>

Work in **English**. <fresh / fork of <uuid> / steer>. Do not stop other jobs (<names>).

## Facts so far
- …

## Task
1. …

## Done
- … (land through origin/main, SHOTS if dest verify, no release)
EOF
```

Prompt body = task, facts, locks, done criteria. Do not quote launcher flags
in the body; the worker reads them as instructions (sume#7839). The launcher
adds the worker preamble, release lock and Slack-report tail itself.

### Fresh job

```bash
sume-bg-launch --host mini --backend claude --name <job-slug> \
  --prompt-file "$P" -- --model claude-opus-5-5 --effort high
```

Run it as a background command. Smoke once for `📎 session_id=` (dead =
an `exit_code` in seconds), tell Chase the job slug and session id, then
return control. The attach streams the M5 log into
`~/.cstack/state/opus-live/<job>.log` (+ `LATEST.log`); laptop sleep ends
only the attach, never the job.

### Fork (new session that keeps a parent's context)

```bash
sume-bg-launch --host mini --backend claude --name <new-slug> \
  --resume <parent-uuid> --fork-session --prompt-file "$P" -- --model claude-opus-5-5 --effort high
```

Use a fork when the new ask needs what an earlier worker learned. The parent
keeps running. Most desk jobs are forks or steers (86% of starts since
2026-10-18).

### Steer (same session, follow-up)

```bash
sume-bg-launch --host mini --backend claude --name <same-slug> \
  --resume <session-uuid> --prompt-file "$P"
```

Open the prompt with `STEERING UPDATE` and say what changed. The worker's
report goes to a **new top-level message** in `#coding-agents`. For a poke,
restart or effort change with no new instruction, add `--same-thread` so the
report replies in the job's existing thread instead. On the M5 the
start step stops the older job holding that session first (the job that
printed `📎 session_id=<uuid>` or resumed it), so one session never has two
wrappers. `--resume` is same-host only: a Mini session resumed with
`--host local` exits 4 and prints the host.

### Model and effort

- Model: `--model claude-opus-5-5` (alias `opus-5.5`). Fable
  (`--model fable`) or Sonnet 5.5 only when Chase names them.
- Effort: Chase usually names it; pass it through:
  `--effort low|medium|high|xhigh|max` (`mid` → `medium`, `maximum` → `max`,
  `x-high` → `xhigh`). Since 2026-10-18 the mix is high 48%, medium 27%,
  xhigh 19%, max 5%, low 1%.
- Chase silent: code lane `medium`, research `low` (lock 2026-08-24). The
  wrapper injects `medium` for Opus when `--effort` is omitted.

### Job slug and title

`--name` = 2–4 lowercase kebab tokens that say what the job is
(`gh-stack-not-enabled`, `heygen-ticket-button`), never an issue number
alone. Title everywhere (board, Slack parent): `Opus : <job-slug> (#N)`.

### Control plane

```bash
sume-bg-launch --host mini --jobs              # alive / state per job
sume-bg-launch --host mini --status <job>      # truth = M5 pid + recorded start time
sume-bg-launch --host mini --attach <job>      # re-attach; rewrites the replica log
sume-bg-launch --host mini --kill <job>        # TERM → KILL the job's process group
```

`state=pid-reused` means the recorded pid now belongs to another process
(pids repeat after a reboot); the job is dead and `--kill` refuses it
(exit 6). Never count the replica log as liveness. Details:
`docs/MINI-WORKER-HOST.md`.

## Delegation template

```text
# Opus: <what>
Work in **English**. <fresh | fork of <uuid> | STEERING UPDATE>.
Do not stop other jobs (<running job slugs>).

Context: repo, issue URL, recent PRs/incidents, what Chase wants and why.
Task: numbered steps.
Constraints:
- No deploys / DB mutation / paid provider calls unless authorized here.
- No secrets in output. No code comments (docs are the SoT).
- sume-com code: read ~/.agents/skills/sume-gt-mq/SKILL.md; paste the
  STACKS block from ~/.cstack/src/sume-desk/GRAPHITE-HARD-LOCK.md.
Done:
- Land through origin/main (LANDED: yes + PR URL + main SHA), or "research only".
- Dest/prod browser verify: SHOTS: <issue comment URL>.
- No release (RELEASE: needs Chase if prod needs it).
```

Research-only tasks say "research only; no code changes". Prod mutations
name the exact authorized scope and require a dry run first.

## Chase work loop

Discuss (Chase's language) → lock nouns, defaults, non-goals, stage
boundary → GitHub mega-issue (`github-mega-issue`) when a context-free
worker needs it → Opus prompt → the worker lands through `origin/main` →
short report in Chase's language. Triggers: "그렇게 가보자", "플로우 타자",
"mega-issue → opus".

- **Heavy / ambiguous** (RCA, cross-surface, risky migration): one Opus
  session designs (`sume-architect` for a new API or data model,
  `sume-blast-radius` before a risky submit) and implements through main.
- **Clear / small**: one Opus session, implement → land.
- **One train, one session:** dependent layers go in one stack, one
  `gh stack submit`, not "land A, then resume for B".

## Landing (sume-com)

Mechanics: `~/.agents/skills/sume-gt-mq/SKILL.md`. Short version:
`cstack-clone <slug>` → `gh stack init` / `gh stack add` →
`gh stack submit --auto --open` → `cstack-gt-wait-merge --rm <slug>` → stay
until every layer is on `origin/main`. Forbidden: `gh pr create`, `gt`, the
`merge-queue` label, `gh pr merge --admin`, `git worktree add` under a
shared checkout. Queue removal → fix → `gh stack sync` → helper again, same
session.

## Status checks

When Chase asks for status: one-shot read of each live job (`--jobs`, then a
`tail` of its replica log), grouped by job: `running` (with 진행 = last real
step), `final report` (not 완료 unless main has `(#N)`), `blocked`,
`landed`, `bad state`. Chat shows the live (`지금`) jobs only; finished work
is in Slack `#coding-agents` (Chase lock 2026-10-17). No polling loops.

## Slack `#coding-agents`

Every worker posts its own Korean completion report (`docs/SLACK-REPORT.md`)
as a **new top-level message** `<short what> — \`Opus : <slug> (#N)\`` with
the report in that message, for fresh jobs, forks and `--resume` steers alike
(Chase lock 2026-10-13, 2026-11-03). A reply in the job's old thread only
with `--same-thread` (a poke, restart or effort change, no new instruction).
When Chase asks for a DM, the DM is extra: the channel report still happens,
amounts included. The launcher appends these rules; do not paste them into
prompts, and never write "DM only" as if it replaced the channel. A final block with `SLACK_TEXT:` means the worker could not
post; the main agent posts that text as a new channel message.

## Browser verification and dest evidence

Workers that ship user-visible product verify in a real browser after their
own work: locally first, then dev after the dev deploy. Use the
`ego-browser` skill (own TaskSpace and tab; never drive Chase's live tab),
or `aside repl` only when ego is unavailable. M5 ego is allowed.

- Dev or prod under the **sumelabs** workspace only; compose model **Auto**.
- Destructive steps (send, delete, pay, ops settings) need Chase first.
- Hard lock (#7110): after any dest/prod verify, post **one** `gh issue
  comment` on the Job issue with 2–4 screenshots + host, sumelabs, Auto,
  deployed SHA, pass/fail, URL. Final report carries `SHOTS: <comment URL>`;
  no URL ⇒ no `DEST: pass`. Stay until dest `/api/build` reports the land
  SHA or a descendant; a background watch is not completion.
- Recipe: [references/dest-verify-issue-shots.md](references/dest-verify-issue-shots.md).

## Safety

- Never put secrets in prompts (the launcher refuses prompts that look like
  credentials) or in reports.
- No broad production mutation without explicit, scoped authorization.
- Do not override work in someone else's dirty checkout or clone.
- Do not stop or restart other jobs' wrappers unless Chase asks.
- A worker that answered the wrong task is `bad state`: say so and relaunch
  with a corrected prompt.

## Harness wiring

| Harness | Entry point |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` imports `~/.codex/AGENTS.md`; skills in `~/.claude/skills/` |
| Codex | `~/.codex/AGENTS.md` "Sume Orchestration" section; skills in `~/.codex/skills/` |

`install.sh` writes those sections from `sume-desk/*-snippet.md` and links
the skills. `check-wiring.sh` verifies the result.
