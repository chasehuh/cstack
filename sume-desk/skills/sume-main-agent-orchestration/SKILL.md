---
name: sume-main-agent-orchestration
description: Sume-specific main-agent orchestration workflow. Use when the user wants the current thread to coordinate workers/subagents (Claude Code, Grok Build via agent-human-stream, Composer Task, or Codex), track their status, delegate tasks, compact finished workers, create Linear/GitHub issues, or summarize what main_agent and workers are doing instead of directly implementing code. Includes Fable / Opus / Grok Build routing for mega-issue → implement → PR → merge.
---

# Sume Main Agent Orchestration

## Purpose

Use this skill when the current thread is acting as the Sume main agent:

- The main agent is the user's communication, planning, and coordination layer.
- Workers / subagents own scoped execution — implementation, investigation, PR,
  merge, experiment, or monitoring (Cursor Task subagents, Claude workers, or
  Codex worker threads — same role split).
- The main agent should keep the user oriented, delegate clearly, inspect worker outputs, and decide next routing.

**SoT location:** `~/.agents/skills/sume-main-agent-orchestration/`.
This file is the single source of truth for Codex, Cursor, and Claude Code.
Never copy these rules into another file; point at this file instead.
See "Harness Wiring" at the end for how each harness reaches this file.

This is the default Sume collaboration style for the "main agent / worker"
pattern (including legacy names like `worker2`…`worker7`, `exp9`, `cc-worker-*`).

## Harness Scope

Most of this skill is **shared** across Cursor, Codex, and Claude Code when
they act as the Sume main agent.

Sections and bullets marked **Cursor-only** apply **only** when the main agent
is Cursor (Shell `block_until_ms`, completion notifications, Cursor `Task`
slugs, `AwaitShell`, etc.).

When the main agent is **Codex or Claude Code**:

- **Ignore every Cursor-only rule.** Do not invent Cursor `Task` /
  `AwaitShell` / `notify_on_output` / custom sleep-watchers for Opus.
- Still use this skill for role split, language, pipelines, and the shared
  Opus path (`claude-human-stream` when you need a Claude Code Opus worker
  from another harness that can shell out).
- Use that harness's native background / subagent completion model instead
  of Cursor notification semantics.

When Claude Code **is** the Opus worker (not the main agent): ignore all
main-agent monitoring rules; just do the delegated task and emit the final
report.

## Core Role Split

### Main Agent

The main agent should:

- Talk to the user in the same language the user is using (match the latest
  user message unless they explicitly ask for a different language).
- Understand and restate the goal, constraints, and current system state.
- Pick the right worker thread for each task based on current load and task type.
- Send precise delegation prompts with context, constraints, expected output, and done criteria.
- Read worker thread summaries/statuses and translate them into concise user-facing updates.
- Track which workers are active, idle, blocked, complete, merged, or awaiting review.
- Ask workers to compact after completed or stale tasks.
- Create Linear issues when the user wants product/work tracking.
- Avoid doing implementation directly when the user explicitly says to delegate.

Default execution mode for workers/subagents:

- Launch workers in the background by default.
- Do **not** `wait`/block on a worker just because it was spawned. Waiting turns
  the main agent into an idle state and stalls the user conversation.
- After spawn, either continue useful main-agent work or return control to the
  user with a short "running in background" update.
- Wait only when the user's next requested action is blocked on that exact
  worker result, or when the user explicitly asks to wait/check now.
- Prefer completion notifications / later status checks over polling loops.

The main agent may directly execute tiny coordination tasks such as reading a
thread, creating a Linear issue, or checking a command result. It should not
silently take over a code implementation that the user expected to be delegated.

### Code SoT when answering (Chase lock 2026-08-24)

Shared Cursor / local `main` is **usually dirty**. When the user **asks a
question** about shipped product code (not “what’s in this dirty tree?”):

- Read **`origin/main`** (`git fetch` if needed, then
  `git show origin/main:<path>` / `git grep … origin/main --`).
- Do not treat the chat workspace working tree as current trunk.
- Implementation still uses a fresh worktree/clone. Cursor user rule:
  `~/.cursor/rules/origin-main-sot.mdc`.

### Workers / Subagents

Workers (Cursor Task subagents, Claude/Codex worker threads) should:

- Always work and report in English (thinking, tools, status, commits, PRs,
  final reports), unless the user explicitly overrides that for a specific task.
- Own a scoped execution unit: investigation, implementation, PR/merge, log audit,
  provider experiment, or research report.
- Use fresh worktrees for repo code changes.
- Follow repo instructions, especially `AGENTS.md`, DB safety, deploy safety, and
  the Sume worktree/PR/merge flow.
- Report exact files changed, PRs, merge commits, validation, caveats, and blockers.
- Not mutate production data, deploy, or trigger paid provider calls unless the
  delegation explicitly authorizes that exact action.

**Chase lock (2026-08-26) — 완료 to Chase only after `origin/main` `(#N)`.**

Subagents / workers / this main agent must **check that the change is
fully in** before telling Chase it is done.

```bash
git fetch origin main
git log origin/main --oneline --grep='(#N)'
```

No log line → **not 완료**. Forbidden words to Chase until that proof:
완료 / done / completed / landed / “들어갔습니다.”

**Not proof:** PR open, PR-branch CI green, `gt` Ready, enqueued,
`merge-queue` label, MQ draft, `HANDOFF: grok-land`, Graphite “Your
changes” still listing the PR, worker process exited.

Author STOP after enqueue is a **handoff**. Final report must say
`LANDED: no` + `NOT 완료`. Land worker stays until the main-tip grep
hits; MQ eject → re-enqueue same session; forbidden to exit with
`HANDOFF: grok-land`. Main agent launches/resumes land and does **not**
translate enqueue into 완료. Leftover “Your changes” = still open.

## Delegation Template

When sending a task to a worker, include:

```text
You are workerN. Work in English.

Context:
- Repo/thread/environment.
- Relevant recent PRs, incidents, decisions, or constraints.
- What the user wants and why.

Task:
1. ...
2. ...
3. ...

Constraints:
- No deploys / no DB mutation / no provider calls unless explicitly authorized.
- No secrets or private data in output.
- Use fresh worktree -> validation -> PR -> merge when code changes are requested.

Final report:
- Root cause / findings.
- Implementation or recommendation.
- PR/merge/deploy status if applicable.
- Tests/validation.
- Caveats/follow-ups.
```

For research-only tasks, state "research only; no code changes." For production
mutations, state the exact authorized scope and require a dry run first unless
the user already approved the precise mutation.

After sending the delegation, keep the worker in background mode by default.
Do not immediately wait on it unless the current user turn is blocked on that
result.

## Coding Worker Model Routing (Fable / Opus / Grok)

This section is the source of truth for which model runs which stage of the
GitHub mega-issue → implement → PR → merge flow in Sume repos. Every coding
delegation must pick the model and **transport** explicitly according to these
rules.

**Chase lock (2026-08-23) — default author is Opus.** Coding models are only
**Fable / Opus / Grok**. If Chase does **not** name a model, launch **Opus**
(`claude-human-stream`, default `--model opus`). Use **Fable** only when Chase
says Fable / `--model fable`. **Grok** is land/ops (and explicit Grok author
asks). Composer remains explore-only.

| Role | Model | Transport (from a Cursor main agent) |
|------|-------|--------------------------------------|
| Opus (default author: design / RCA / mega-issue / **code → MQ enqueue**) | Claude Opus via Claude Code subscription | **`claude-human-stream`**. Do **not** use Cursor `Task` with `claude-opus-*`. |
| Fable (author only if Chase named Fable) | Claude Fable via same wrapper | **`claude-human-stream --model fable`**. Same Graphite enqueue path as Opus. |
| Grok (**MQ land babysit / deploy / ops**; author only if Chase said Grok) | Grok Build CLI (`grok` on PATH) | **`agent-human-stream --backend grok`**. Do **not** use Cursor `Task` with `cursor-grok-*`. |
| Composer (explore only) | Composer | Cursor `Task` with `composer-*` / `explore` |

**MQ babysit is always Grok** after **Opus or Fable** enqueue. Do **not** leave
Opus/Fable watching MQ draft CI / `main` tip / restack-while-merging unless
Chase explicitly said that session owns land (`merge까지` / `landing까지`).

### Worker reasoning effort (Chase lock 2026-08-24)

Pass `--effort` from the **job lane**. Cursor rule:
`~/.cursor/rules/worker-reasoning-effort.mdc`.

| Lane | Opus | Fable | Grok |
|------|------|-------|------|
| **Code** (implement, PR, land, deploy, RCA that edits) | `medium` | `high` | `xhigh` |
| **Research** (조사 / open-source scan / no code change) | `low` | `low` | `medium` |

**Default research owner is Grok.** Most 조사 goes to
`agent-human-stream --backend grok … --effort medium`. Opus/Fable research
only when Chase names them — still `--effort low`.

Claude Code CLI enum is `low|medium|high|xhigh|max` (Fable / Opus 4.7+).
When Chase names **max** or **xhigh**, pass that string through —
**do not** remap Fable `max` → `high`. Wrapper aliases: `maximum` → `max`,
`mid` → `medium`, `x-high` → `xhigh`.

Grok CLI enum is `xhigh|high|medium|low` (no `max` / `mid`). The wrapper
maps `mid` → `medium` and `max`/`maximum` → `xhigh` (Grok ceiling).
Codex has no `--effort` flag; the wrapper writes `-c model_reasoning_effort`
(`none|minimal|low|medium|high|xhigh`, same alias mapping, default `high`).

Wrapper default when `--effort` is omitted = **code lane** (Opus
`medium`, Fable `high`, Grok `xhigh`, Codex `high`). Named `max` is not that default.
Research **must** pass `--effort`. Mixed research-then-implement in one
worker → code lane.

**Default split (Chase lock, 2026-08-05 + 2026-09-01):** The author (Opus, or
Fable if named) owns PR authoring **through the tip `merge-queue` label**
(**fresh clone** → code → local green → `gt create` → **`gt submit`** →
**`cstack-gt-wait-merge`** labels the tip now — **never** wait for PR CI /
`gt` Ready, **never** `gh pr create` on `sume-com`). Label = enqueue
evidence (Graphite MWR if CI is still running). Then **STOP** and hand
**land babysit** (+ deploy) to Grok.

### Opus transport — Claude Code CLI (required)

When the main agent needs an **Opus** worker/subagent:

1. Run **Claude Code CLI** on the local machine (`claude` on PATH). On the
   Sume desk that binary is the **tokenmaxxing supervisor**
   (`~/.config/tokenmaxxing/bin/claude`), which wraps npm
   `@anthropic-ai/claude-code` and swaps Chase/dev Max accounts near quota.
   Desk write-up: `chasehuh/cstack` → `docs/TOKENMAXXING.md`.
   `tokenmaxxing doctor` must keep the supervisor ahead of the real CLI.
   Do not set `ANTHROPIC_API_KEY` to bypass the pool.
   Default local config already targets Opus
   (`~/.claude/settings.json` → `"model": "opus[1m]"`, `"effortLevel": "medium"`).
   `claude-human-stream` / `agent-human-stream --backend claude` injects
   `--effort` when omitted: **Opus → medium**, **Fable → high**
   (code lane). Named `--effort max` / `xhigh` pass through to Claude
   Code (do not remap to `high`). Research → pass `--effort low`. See
   § "Worker reasoning effort".
2. Prefer the human-readable wrapper (stream-json under the hood, printable lines).
   Canonical launcher: `agent-human-stream` (Claude + Grok Build).
   Opus/Fable alias: `claude-human-stream` → `--backend claude`.
   Path: `~/.agents/skills/sume-main-agent-orchestration/bin/agent-human-stream.sh`
   PATH: `~/.local/bin/agent-human-stream` and `claude-human-stream`.
   Optional: `--name <slug>` before the prompt (shown in Claude `/resume`
   picker). **Required naming:** 2–4 kebab tokens that describe the *job*,
   not just the issue number — see § "Worker slug naming" below. Pass extra
   `claude` flags **after** the prompt if needed (e.g. `--model opus`).
   On completion, parse only the `—— final ——` block for the user summary —
   do not dump the whole progress log into main-agent context.
   Also capture `📎 session_id=<uuid>` (printed early and again just above
   `—— final ——`) so the session can be resumed later — same ergonomics as
   Cursor `Task` `resume` + `agent_id`.
   Do **not** expose bare `--output-format stream-json` to user-watched
   terminals, and do not default long Opus workers to plain `--output-format text`.
3. **Resume (shared):** to continue a prior Opus Claude session with a
   follow-up prompt (not a fresh worker), use:
   `claude-human-stream --resume <session_id> "<follow-up prompt>"`
   or `CLAUDE_RESUME_SESSION=<uuid> claude-human-stream "<follow-up>"`.
   Prefer explicit `--resume <uuid>` over `--continue` (continue = most
   recent session in **this cwd** only — easy to grab the wrong one).
   Use `--fork-session` with resume/continue when you want a new session id
   that copies history (parallel branch) instead of appending to the original.
   Wrong cwd / project slug → Claude cannot find the session; resume from the
   same working directory (or project) the original worker used.
4. **Cursor-only launch + monitor** (see next subsection). Other harnesses:
   background the process with that harness's native mechanism; do not poll.
   Resume recipe above still applies whenever you shell out via the wrapper.
5. Worker prompts stay in **English**; include context, constraints, and done
   criteria exactly as for other workers.
6. Do **not** route Opus work through Cursor `Task` / `claude-opus-5-thinking-high`
   anymore — that burns Cursor-side Opus routing; Claude Code subscription is
   the Opus path.

### Agent human stream — Claude + Grok Build + Codex

Canonical wrapper for **headless** Claude Code, **Grok Build** (`grok` CLI)
and **Codex** (`codex exec --json`):

```bash
agent-human-stream --name <job-slug> "…" --model opus          # auto → claude
agent-human-stream --backend grok --name <job-slug> "…"        # Grok Build
agent-human-stream --backend codex --name <job-slug> "…"       # Codex (only if Chase named Codex)
agent-human-stream --resume <uuid> "Follow-up …"               # backend from registry
```

- `claude-human-stream` stays the Opus/Fable command. It execs
  `agent-human-stream --backend claude`. Do not break existing recipes.
- `--backend auto` (default): `grok*` model → grok; `gpt-*`/`o3*`/`o4*`/`codex*`
  → codex; opus/fable/sonnet/haiku → claude; `--resume` uses the last
  `backend` recorded for that session.
- Claude: `stream-json` + tokenmaxxing `claude`. Grok: `streaming-messages-json`
  (`--permission-mode bypassPermissions --always-approve`). The formatter also
  reads Grok native ACP `streaming-json`.
- Codex: `codex exec --json --skip-git-repo-check
  --dangerously-bypass-approvals-and-sandbox "<prompt>" </dev/null` via the
  tokenmaxxing `codex` shim (**Codex pool**, separate from the Claude pool —
  `docs/TOKENMAXXING.md` § Codex pool). Resume id = Codex `thread_id`;
  `--resume <id>` → `codex exec resume <id> "…"`; `--continue` →
  `resume --last`; no `--fork-session`. `--effort` → `-c
  model_reasoning_effort="…"` (`mid` → medium, `max` → xhigh; omitted →
  `high`). Claude-only `--verbose` / `--permission-mode` / `--output-format`
  are dropped with a note. Account swaps apply on the next `codex` start.
- Same live log dir (`~/.cstack/state/opus-live/`) and registry (`~/.cstack/state/opus-sessions.jsonl`)
  with a `backend` field. Resume hint prints `agent-human-stream --backend …`.
- **Land and explicit Grok author use this wrapper.** Do **not** launch
  Cursor `Task` / `cursor-grok-*` for land babysit or Grok-authored trains.
  Composer explore stays Cursor `Task`.

### Grok transport — Grok Build CLI (required)

When the main agent needs a **Grok** worker (default **land babysit**, or
author only if Chase named Grok):

1. Run **Grok Build** on the local machine (`grok` on PATH, currently
   `~/.grok/bin/grok` via `~/.local/bin/grok`). Not Cursor `Task`.
2. Launch with the same human-stream wrapper:
   `agent-human-stream --backend grok --name <job-slug> "<prompt>"`
   Extra `grok` flags go **after** the prompt (`--model grok-4.6`, `--effort`,
   `--max-turns`, …). Omitted `--effort` → **`xhigh`** (code/land).
   Research → **`--effort medium`**.
3. **Cursor-only:** same monitor as Opus — Shell `block_until_ms: 0`,
   `description`: `Grok : <job-slug> (#N)`, capture `📎 session_id=`, read
   only `—— final ——`. Resume:
   `agent-human-stream --backend grok --resume <uuid> "…"`.
4. Prompt file: write it **in the same Shell** as the launch (heredoc).
   Do **not** `Write` the file and `$(cat)` it from a parallel Shell — that
   exits 2 (`missing prompt`) before Grok starts. Pass `--prompt-file`.
   Same job slug stem as the Opus train when this is land babysit.
5. Do **not** route Grok land/author through Cursor `Task` / `cursor-grok-*`.
6. Steer / second `--resume`: use `sume-bg-launch` so the previous wrapper
   on that uuid is stopped first (two `grok -p --resume` = empty live log).

Copy-paste:

```bash
mkdir -p /tmp/sume-grok-prompts
cat > /tmp/sume-grok-prompts/<job-slug>.md <<'EOF'
# Grok Build: land #<issue>
Work in **English**.
Issue: <url>
PRs: <urls>
HANDOFF: grok-land
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md
EOF
# Shell description: Grok : <job-slug> (#N)
cd /path/to/repo && sume-bg-launch --backend grok --name <job-slug> \
  --prompt-file /tmp/sume-grok-prompts/<job-slug>.md -- --effort xhigh
```

### Cursor-only — Opus / background-worker monitoring

Applies only when the **main agent is Cursor**. Codex / Claude Code main
agents: skip this whole subsection (but may still use the shared resume
recipe in "Opus transport" above).

Goal: Opus (and other long workers) stay visible to the user without turning
main into a polling loop. Resume should feel like Cursor `Task` `resume`,
and humans must be able to **watch live progress** (especially on resume).

Cursor also installs a detailed always-apply cookbook at
`~/.cursor/rules/opus-background-terminal.mdc` — keep that file in sync when
this recipe changes. Active workers board policy lives at
`~/.cursor/rules/active-workers-canvas.mdc` (see subsection below).
Status board (lanes + confirm + 24h backlog):
`~/.cursor/rules/status-board.mdc`. Chat reprint:
`~/.cursor/rules/end-of-turn-worker-brief.mdc`.

#### Copy-paste Cursor Shell recipe

```bash
# 1) Prompt file IN THIS SHELL (English). Do not Write + parallel $(cat).
mkdir -p /tmp/sume-opus-prompts
cat > /tmp/sume-opus-prompts/<job>.md <<'EOF'
# Opus: …
Work in **English**. Context, constraints, done criteria…
EOF

# 2) Background Shell: block_until_ms MUST be 0.
#    Shell tool `description` (terminal title) REQUIRED:
#      Opus : <job-slug> (#<issue>)
#    Same string as Active workers board Job column. Resume/steer: identical.
#    There is NO --cwd flag — cd first. Same cd path required for --resume.
cd /path/to/repo && sume-bg-launch --backend claude --name <job-slug> \
  --prompt-file /tmp/sume-opus-prompts/<job>.md

# Resume / steer (kills older wrappers on this uuid first):
# description = same "Opus : <job-slug> (#N)" as the live job
cd /path/to/repo && sume-bg-launch --backend claude --name <job-slug> \
  --resume <session_uuid> \
  --prompt-file /tmp/sume-opus-prompts/<follow-up>.md
```

`<job-slug>` = § "Worker slug naming" (e.g. `format-uifix-pdp`, not `2000`).
Terminal/board title = `Opus : <job-slug> (#N)` — see § "Worker slug naming".

After spawn: **required one-shot** read of the terminal file. Alive =
`📎 session_id=`. Dead = `exit_code` in ~1s (`missing prompt` / not found).
Dead → fix and relaunch this turn; do not tell Chase it is up. Then
**return control**. Do **not** poll.

On Cursor **completion notification** for that Shell: read only
`📎 session_id=` + `—— final ——`, brief user update, then run any standing
follow-up already authorized (do not re-ask).

#### Checklist

1. **Launch:** Shell with `block_until_ms: 0` for `claude-human-stream`.
   `--name` must be a descriptive job slug (§ "Worker slug naming"), e.g.
   `--name format-uifix-pdp` — never issue-only like `--name 2000`.
   Shell tool **`description`** (Cursor terminal title) must be
   `Opus : <job-slug> (#<issue>)` — same string as the Active workers board
   Job column. Grok Build Shell uses `Grok : <job-slug> (#N)`. Composer
   `Task` uses `Explore : <job-slug>` the same way.
2. **After spawn — make progress human-visible:** briefly tell the user what
   started **and** where to watch. The wrapper tees the human stream to
   `~/.cstack/state/opus-live/<stamp>-<name>.log`
   and updates `…/opus-live/LATEST.log`. Always surface in chat:
   - `session_id` (when printed)
   - `live_log` path (wrapper stderr banner + registry `live_log` field)
   - watch hint: `tail -f …/opus-live/LATEST.log`
   As soon as the terminal shows `📎 session_id=<uuid>`, **remember that id**
   in-thread (analogous to Task `agent_id`) for later "resume that Opus".
   Then **return control** — continue other useful work or idle. Do **not**
   `AwaitShell`-poll, do **not** write custom `sleep`/tail watchers, do **not**
   block the user turn "just to watch." The live log is for **humans** (and
   for a one-shot status peek when the user asks).
3. **On completion notification:** that is the monitor. Open the finished
   shell/task output, read `📎 session_id=…` (near the top and again above
   `—— final ——`) plus only the `—— final ——` block (or the Task final
   report), give the user a short status, and **immediately run any standing
   follow-up** the user already authorized in this thread (e.g. "when the
   mega-issue is filed, attach Grok → PR → merge"). Do not re-ask for that
   permission. **Same turn:** refresh the Active workers Canvas (see
   § "Cursor-only — Active workers Canvas" and
   `~/.cursor/rules/active-workers-canvas.mdc`).
4. **Resume that Opus:** when the user (or a standing follow-up) says to
   continue the same Claude session — e.g. "resume the Opus that audited
   #1708" — do **not** start a new `claude-human-stream` without `--resume`.
   Launch background Shell again with:
   `claude-human-stream --resume <session_id> --name <label> "<follow-up in English>"`
   Same cwd as the original worker when possible. Again tell the user the
   **new** `live_log` / `tail -f LATEST.log` path (each launch gets a fresh
   live file; Claude session history is what resume continues).
5. **User asks "how's it going?" / status:** one-shot `tail` of the live log
   (or the background terminal file) — ~20–40 lines — and summarize. Do not
   start a polling loop.
6. **Recover a forgotten session_id** (in order):
   - Finished terminal log: grep `📎 session_id=`
   - Wrapper registry (prompt_head + cwd + live_log, no secrets):
     `claude-human-stream --sessions`
     or `~/.cstack/state/opus-sessions.jsonl`
   - On-disk Claude transcripts under
     `~/.claude/projects/<cwd-slug>/*.jsonl` — filename / `sessionId` field;
     match by mtime + first user `prompt` text (e.g. rg `1708` / `Audit`).
   - Weaker: `claude-human-stream --continue "…"` only if you are in the same
     cwd and that session is still the most recent there.
   - Interactive listing: `claude -r` (picker) or named sessions via `-n/--name`
     (also visible in `/resume`). `--bg` / `claude agents --json` is for
     background agents, not a full history of every `-p` print session.
7. **Wait only when:** the user's next requested action is blocked on that
   exact result, or the user explicitly says to wait / check now.
8. **Bad patterns (forbidden):**
   - Cursor `Task` + `claude-opus-*` for Opus work
   - Cursor `Task` + `cursor-grok-*` for Grok land / Grok author
   - Shell with default/long `block_until_ms` (job looks stuck / times out)
   - `claude-human-stream --cwd …` (flag does not exist — `cd` first)
   - inventing a second watcher / `AwaitShell` poll loop / `sleep` until done
   - dumping the full Opus tool log into chat
   - claiming completion before the notification / final block exists
   - spawning a **new** Opus session when the user asked to resume an existing one
   - hiding the `live_log` path so the human cannot watch a resume

### Cursor-only — Status board

Applies only when the **main agent is Cursor**. One board, three surfaces:

- **Definition:** `~/.cursor/rules/status-board.mdc`
- **Canvas:** `canvases/active-workers-board.canvas.tsx`
  (`~/.cursor/rules/active-workers-canvas.mdc`)
- **Chat:** self-contained **work report** + board reprint
  (`~/.cursor/rules/end-of-turn-worker-brief.mdc`). Chase must
  understand the turn without Slack.
- **Slack:** `#coding-agents` (`~/.cursor/rules/slack-coding-agents.mdc`)
  — new Job = thread; updates = replies; reactions `loading` / `eyes` /
  `white_check_mark`. Team mirror only — not a substitute for the chat
  report.

Lanes: `지금` → **`스테이징`** → **`백로그`** (≥24h). Chase confirm =
resolve (Job drops off chat/canvas; Slack gets the check). Never
auto-resolve.

`지금` rows must include **`진행`**: one-shot from the Job’s
`opus-live` tail / last tool / in-progress todo (≤12 words, a noun).
Not a poll. Do not print live Jobs as session_id-only. Definition:
`status-board.mdc` § 진행 (Chase lock 2026-08-28).

Refresh canvas the same turn the set changes. Link the `.canvas.tsx`
path. Read `~/.cursor/skills-cursor/canvas/SKILL.md` before create/edit.
One-shot reconcile — no poll loops.

### Chase work loop — discuss → lock → mega-issue → Opus → Grok

**Chase lock (2026-08):** Default product/engineering session shape when this
chat is the Sume **main agent** talking to Chase.

Cursor also installs a detailed always-apply cookbook at
`~/.cursor/rules/sume-chase-work-loop.mdc` — keep that file in sync when this
loop changes.

#### Worker slug naming (Chase lock)

When launching Opus (`--name`), Grok/Composer `Task` slug stems, or prompt
filenames under `/tmp/sume-opus-prompts/`, use a **short kebab slug that says
what the job is** — not the issue number alone.

| Rule | Detail |
|------|--------|
| Shape | **2–4** lowercase kebab tokens (aim for **3**), ASCII `[a-z0-9-]+` |
| Content | Area + intent + surface/outcome, e.g. `format-uifix-pdp`, `format-float-request`, `sched-rename-merge` |
| Issue id | Optional **suffix** only: `format-uifix-pdp-2000` — never `2000` / `issue-2000` alone |
| Prompt file | Same stem: `/tmp/sume-opus-prompts/format-uifix-pdp.md` |
| Uniqueness | If two jobs share a stem, add a 4th token (`-merge`, `-smoke`) or the issue suffix |

**Good:** `format-uifix-pdp`, `format-float-request`, `format-thumb-video`, `agent-completions-api`  
**Bad:** `2000`, `issue-2000`, `opus`, `work`, `fix` (number/role alone — no area+intent)

##### Terminal title = board Job (Chase lock 2026-08-07)

Cursor’s “N Terminals Running” list shows the Shell tool **`description`**
(terminal `title`), **not** `--name`. The Active workers board Job column
must use the **same string** so Chase can map UI ↔ board without a lookup
table.

| Kind | Exact title |
|------|-------------|
| Opus Shell | `Opus : <job-slug> (#<issue>)` |
| Opus, no issue yet | `Opus : <job-slug>` |
| Grok Build Shell | `Grok : <job-slug> (#<issue>)` |
| Composer explore | `Explore : <job-slug>` |

Examples: `Opus : dashboard-ui-chrome (#2819)`,
`Grok : dashboard-ui-chrome (#2819)`.

**Forbidden:** prose titles (“Create arch mega-issue…”, “Relaunch dead…”),
command-comment leaks that become `Cursor (# Reopen…)`. Resume/steer keeps
the **identical** title as the live job.

#### Roles in the loop

| Who | Does |
|-----|------|
| **Chase (user)** | Product intent, locks, approvals ("그렇게 가자", merge 여부) |
| **Main agent** (usually Cursor Grok) | Discuss in Chase’s language; survey code; draft/file issues; launch workers; status; never silently steal Opus’s implementation |
| **Opus** (`claude-human-stream`) | BP when needed; implement in **fresh clone**; **`gt create` → `gt submit` → tip `merge-queue` (MWR)**; **STOP** after the label with `LANDED: no` / `NOT 완료`. Never `gh pr create`. Never tell Chase 완료. |
| **Grok** (`agent-human-stream --backend grok`) | After enqueue: MQ draft CI → **`origin/main` `(#N)`** (re-enqueue on eject; do not STOP at enqueue) → issue comment → authorized deploy/ops. Fallback: CI → label enqueue → land if Opus could not enqueue. Also author if Chase named Grok. |
| **Composer** | Explore only |

#### Canonical steps

1. **Discuss** — Main clarifies goal with Chase (Korean in ↔ Korean out unless asked otherwise). Peek code/docs as needed; do not jump to a giant silent implement.
2. **Lock** — Restate Chase locks in the issue / BP (nouns, defaults, non-goals, stage boundary: stop-at-MQ-enqueue vs Opus owns land). Uncertain items → "Needs verification", not invented product.
3. **Mega-issue** — Prefer `/github-mega-issue` (or equivalent) so a context-free worker can execute. Clear/small: main may write the issue. Heavy/ambiguous design: Opus may draft the issue (Pipeline 1), then implement.
4. **Opus handoff** — English prompt file → background `claude-human-stream` (`block_until_ms: 0`). Include issue URL, locks, worktree, done report, `HANDOFF: grok-land` (or `HANDOFF: grok-ci-merge` only if Opus must stop before enqueue). See `opus-background-terminal.mdc`.
5. **Brief user** — job slug (`--name`), `session_id`, issue/PR links. Do not
   poll Opus.
6. **On Opus completion** — Read `—— final ——` only; if MQ enqueued (or PRs open) and land was not assigned to Opus, **immediately** launch Grok land babysit (already authorized — do not re-ask). **Do not tell Chase 완료.** Enqueue / green CI / “Your changes” is not landed.
7. **Close the loop** — Short status in Chase’s language. Say **완료** only after `origin/main` has `(#N)`. Leave residuals explicit (smoke, docs defer, etc.).

#### Triggers (treat as this loop)

- "mega-issue → opus", "/github-mega-issue", "BP → PR", "그렇게 가보자", "플로우 타자"
- Product naming / defaults / API tone decisions that need a durable issue before code

#### Anti-patterns

- Main implements the full feature while Chase expected Opus
- Opening PRs with no issue/locks when the ask was the mega-issue flow
- Using MCP as a diagnostic substitute for `curl`/api.dev when Chase forbade it
- Leaving Opus on **land** babysit after MQ enqueue (default)
- Grok land STOP at enqueue / `HANDOFF: grok-land` from the land session
- Telling Chase 완료 on enqueue, green PR checks, or Graphite “Your changes”
- Grok re-enqueuing / clone-thrash when Opus already reported MQ queued **and still in MQ**
- Re-asking "merge 할까요?" after the loop already implies Grok land (unless Chase deferred)

### Pipeline 1 — heavy / ambiguous work

Use when the task is difficult, ambiguous, cross-surface, or design-sensitive:
incidents/RCA, product-direction changes, multi-surface refactors, risky
migrations, "figure out why and design the fix" asks.

1. **Opus 5** — design **and** implementation through MQ enqueue
   (**via Claude Code CLI**):
   - investigate / RCA; write the GitHub mega-issue when needed
     (`github-mega-issue` skill);
   - then (same or resumed session) **`cstack-clone`** → code → local green →
     **`gt create` → `gt submit`** (single or stack) →
     **`cstack-gt-wait-merge`** (label the **tip** `merge-queue` now;
     do **not** wait for PR CI / dry-run Ready);
   - fallback if the binary cannot label:
     `gh pr edit <N> --add-label merge-queue`;
   - **STOP after enqueue confirmed** — do not babysit MQ draft / land;
     **never** fall back to `gh pr create`.
2. **Grok Build** — land ops (**via `agent-human-stream --backend grok`**,
   same background-Shell recipe as Opus), as soon as Opus reports
   MQ enqueued (or on Opus completion notification):
   - babysit **MQ draft CI → land on `main` → deploy babysit** (and
     authorized flags / Railway checks);
   - Confirm land via `main` tip `(#N)` (Graphite FF may leave
     `mergedAt: null` / `CLOSED`);
   - **Fallback** (`HANDOFF: grok-ci-merge`): if Opus stopped before enqueue,
     Grok labels the tip now if missing (no clone) → land;
   - Never mid-stack GitHub-only squash that breaks the stack.

Main agent wires this handoff by default — do **not** re-ask. Only keep
Opus on land if the user explicitly said so for that task.

### PR trains and Graphite (`gt`) — default for *all* PR authoring

**Operational enqueue / land playbook SoT (read before any `gt submit` /
`gt merge` / MQ unstick):**  
[`sume-gt-mq`](~/.agents/skills/sume-gt-mq/SKILL.md)  
(`~/.agents/skills/sume-gt-mq/SKILL.md`). Includes exit-before-enqueue ban,
stack ownership, and CI-missing-after-restack unstick. **Do not fork** those
rules here — update `sume-gt-mq` instead.

When a mega-issue / BP locks a **PR-A / PR-B / PR-C** (or similar) train:

**Prefer one implementer session that builds the whole train, then land once
via Graphite MQ — not ping-pong "open A → babysit merge → resume for B".**

**Chase lock (2026-08-04, #2383 incident):** On `sumelabs/sume-com`, treat
**`gt` as first-class like `gh`**. Agents must follow the BP / this SoT /
ops gotchas **literally**. A green commit opened only with `gh pr create`
is a **failed handoff**, even if GitHub shows a PR URL.

#### Use Graphite CLI (`gt`) — mandatory author path (Sume default)

Chase lock (2026-08-04, #2242): native GitHub stacked PRs + GH merge queue
are **not** reliable on `sumelabs/sume-com`. **Graphite** is the product
path: CLI stacks + Graphite Merge Queue + CI Optimizations.

Install / auth once (human or ops):

```bash
brew install withgraphite/tap/graphite   # or npm i -g @withgraphite/graphite-cli@stable
gt auth --token <from https://app.graphite.com/settings/cli>
# in EACH fresh clone used for authoring:
gt init --trunk main
```

Canonical author → land flow (**do not skip `gt submit`**):

```text
fresh clone → gt init → gt create → commit(s) → gt submit
         → cstack-gt-wait-merge (tip merge-queue now; MWR if PR CI pending)
         → STOP
         → Grok: PR CI / MQ draft → land on main → ops
```

`gt submit` **publishes** the PR and binds it to Graphite. Without it,
MQ enqueue fails / `gt merge` says “branch has no associated PR” even if
`gh pr` exists. Enqueue does **not** replace submit.

**Chase lock (2026-09-01) — Opus default enqueue = tip `merge-queue` label
right after `gt submit`.** Do not wait for PR CI or dry-run Ready. If the
PR is not mergeable yet, Graphite treats the label as Merge when ready
and moves it into MQ when `validate` is green. **Grok default** after the
label = land babysit (PR CI + MQ draft → `main` tip). Grok labels only if
the author never got the label on (`HANDOFF: grok-ci-merge`).

#### Hard rule — fresh clone only for `gt` (never shared-checkout worktrees)

**Why #2383 burned:** Opus ran `git worktree add` under the Cursor
checkout. The branch tip was fine (`origin/main`), but Graphite reads the
**shared `.git` trunk `main`**, which was poisoned (stale / shallow /
hundreds of local-only commits). `gt submit` aborted “trunk out of date”;
Opus then illegally used `gh pr create`.

**Locked (2026-08-04) — for every PR author (Opus / Grok / anyone):**

1. **Do all `gt create` / `gt submit` / `gt restack` / `gt sync` in an
   isolated clone** from `cstack-clone <job-slug>` →
   `/tmp/sume-com-<job-slug>` (objects from
   `~/.cstack/mirrors/sume-com.git`). Not `$REPO/_wt/…` under the Cursor
   tree. After enqueue / land: `cstack-clone-rm <slug>`.
2. **Forbidden for `gt`:** `git worktree add` under the shared Cursor /
   agent checkout (they share poisoned trunk metadata). Full
   `git clone --depth=100` when the mirror exists — use `cstack-clone`.
3. **Forbidden:** `gh pr create` / `gh pr create --head` as the author
   path on `sume-com` — single PR or stack. Same for “submit failed so
   I’ll just open with gh”.
4. **Allowed `gh` uses (not authoring):** `gh pr view`, `gh pr comment`,
   `gh pr edit --add-label merge-queue`, issue tools. **`gh pr checks` is
   not an author wait.** After submit, **`cstack-gt-wait-merge`** labels
   the tip now (see “Enqueue at submit”).
5. Always follow the **BP / mega-issue locks** for slice order, stop-at-PR
   vs merge, and non-goals. Do not invent a parallel land path.

#### `gt` cookbook (as natural as `gh`)

Single PR (default):

```bash
CLONE="$(cstack-clone <job-slug>)"   # stdout = dest only; objects from mirror
cd "$CLONE"
gt init --trunk main   # once per clone
git fetch origin main && git checkout -B main origin/main
gt create -m "$(cat <<'EOF'
fix(area): short why (#NNNN)

EOF
)"
# edit files in $CLONE only; commit with gt modify -c or git commit
gt submit --no-interactive --no-ai --publish
cstack-gt-wait-merge --rm <job-slug>   # label tip merge-queue now (MWR if CI pending)
# Done report MUST include: clone path + Graphite URL + GitHub PR URL
#   + enqueue evidence (QUEUED / label / Graphite activity) + STOP
# HANDOFF: grok-land
# then: cstack-clone-rm <job-slug>
```

PR train (A/B/C in one session):

```bash
# same fresh clone
gt create -m "…"   # A
# …implement A…
gt create -m "…"   # B on top of A
# …implement B…
gt create -m "…"   # C
gt submit --stack --no-interactive --no-ai --publish
cstack-gt-wait-merge --rm <job-slug>   # enqueue whole train via Graphite MQ
# STOP — HANDOFF: grok-land (do not babysit draft CI / main tip)
```

Common ops (same clone):

| Intent | Command |
|--------|---------|
| New branch + first commit prompt | `gt create -m "…"` |
| Amend / add commit on current | `gt modify -c` / `git commit` then stay tracked |
| Publish / update PRs | **`gt submit`** (always required) |
| Restack after trunk moves | `gt sync` / `gt restack` → **`gt submit` again** |
| Enqueue after submit | **`cstack-gt-wait-merge`** (tip `merge-queue` now) |
| Enqueue MQ (**Opus default**) | tip `merge-queue` label (MWR if PR CI pending) |
| Enqueue MQ (manual / Grok fallback) | `gh pr edit <N> --add-label merge-queue` |

#### Recovery — `gt submit` fails (trunk out of date / poisoned)

**Do this:**

1. Keep the commit SHA (branch tip).
2. **Abandon** the bad checkout for Graphite (do not “fix” shared `main`
   with force-reset in the Cursor checkout).
3. New **fresh clone** → `gt init` → fetch branch or cherry-pick tip onto
   `origin/main` → `gt track --parent main` (1 commit / clean stack) →
   **`gt submit`**.
4. If a mistaken `gh pr` already exists for that head: still
   `gt track` + `gt submit` (update / bind Graphite). Do **not** open a
   second PR with `gh`.

**Never do this:**

- `gh pr create` after `gt submit` fails
- `gt track` claiming “includes N00 commits” against a divergent local
  `main` — that means the checkout is poisoned; fresh clone instead
- Long unshallow / merge-base archaeology in the shared repo to “save”
  the worktree

#### Hard rules for stacks

- **No sibling `main` PRs** on overlapping paths — stack them.
- **No mid-stack GitHub-only squash-merge** of lower layers outside Graphite
  MQ (breaks upstack bases). Enqueue the **whole train** by labeling the
  **tip** `merge-queue` — never A-only then resume B.
- **Do not** habitually `git rebase` / “update branch” for stack hygiene —
  use `gt restack` / `gt sync`; the MQ restacks at merge time.
- Single-PR landings still use Graphite MQ (`merge-queue` label), not
  `gh pr merge --squash`, unless Chase explicitly asks for a non-MQ land.
- Workflow files under `.github/workflows/` need a credential with the
  `workflow` scope (SSH or refreshed `gh` token); Graphite’s OAuth push
  alone may reject workflow updates.

#### Operator gotchas (Chase lock lessons, 2026-08-04)

Lessons from the first Graphite MQ rollout + #2383 — agents re-hit these
without this list. Keep in sync with the ops doc.

**Clone / auth**

- **`gt` = fresh clone only.** Shared Cursor checkout + `git worktree add`
  is **not** a Graphite-ready tree.
- Before `gt submit`, verify trunk is clean:
  `git rev-parse main` == `git rev-parse origin/main` (after
  `git fetch origin main`). If not → new clone, do not invent history.
- `gt auth` once per machine; each clone still needs `gt init --trunk main`.

**Submit vs merge**

- Always author with **`gt create` → `gt submit`**. **`gh pr create` is
  forbidden** as the publish path on `sume-com` (single or stack).
- After `gt restack` / `gt sync` rewrites commits: **`gt submit` again**
  before enqueue (local tip must match what Graphite will land).
- `gt submit` aborting “trunk out of date”: **fresh clone recovery**
  (above) — not `gh pr create`, not thrash-reset of the shared checkout.

**Enqueue at submit (Chase lock 2026-09-01)**

Ops detail: **`sume-gt-mq`** § Enqueue at submit.

After **`gt submit`**, the author labels the **tip** `merge-queue` via
**`cstack-gt-wait-merge`**. That is Graphite’s official
enqueue-from-anywhere path
([use the merge queue](https://graphite.com/docs/get-started-merge-queue)).
If the PR is not mergeable yet, the label is
[Merge when ready](https://graphite.com/docs/merge-when-ready):
`validate` green → enters MQ → MQ draft CI still runs.

Do **not** wait for PR CI. Do **not** poll `gt merge --dry-run`.
Do **not** `gt merge` as the author wait path. `Cannot determine` is
irrelevant — label anyway.

**Forbidden as the author path on `sume-com`:**

- `gh pr checks` / dry-run poll loops after submit
- Sleeping until Ready / `(Waiting on CI...)`
- `gt merge` while waiting for CI
- **Endless `gh run rerun --failed`** — land / § F: ≤2 reruns → minimal
  CI unblock → or `HANDOFF: grok-ci-merge`

**Enqueue (Opus default = tip label)**

- **Opus default:** after `gt submit`, **`cstack-gt-wait-merge`** labels
  the tip. Evidence = `merge-queue` on the tip (MWR counts). Then **STOP**.
- **Grok fallback only:** same **label** if the author never got it on
  (`HANDOFF: grok-ci-merge`). Do **not** invent a clone just to `gt merge`.
  Label present + CI still running is **not** eject.
- Independent labeled PRs may each enter MQ when mergeable. Authors do
  **not** rebase while labeled / queued.
- Graphite “already merging” / `QUEUED_TO_MERGE` means **in the queue**.
  After the label, **Grok** watches; do not thrash restack+submit unless
  Graphite asks or the entry failed.

**Grok land babysit** (after Opus enqueue)

When Opus already reported **MQ enqueued** (QUEUED / label / Graphite
activity) + PR URL(s):

1. **Do not re-enqueue** unless the entry failed / was evicted.
   Evicted / empty labels / leftover “Your changes” → re-enqueue **now**.
2. Confirm MQ draft CI / Graphite merge activity; surface draft URL.
3. **Stay in session** until `origin/main` has `(#N)` — not GitHub
   `mergedAt`. Do **not** STOP at enqueue.
4. Issue landed comment + authorized deploy/ops **only after** that
   proof. Then the land session may STOP. That is when main may say
   완료 to Chase.
5. **Do not:** `gt track` recovery, poisoned-worktree `gt merge`, or
   clone-the-monorepo loops.
6. If Opus reported only a `gh pr create` URL with no Graphite submit:
   **reject the handoff** — repair in a fresh clone with `gt track` +
   `gt submit` → enqueue before land babysit.
7. If Opus stopped at `gt submit` without a tip label
   (`HANDOFF: grok-ci-merge`): **label the tip now** → then land steps
   above. Do not wait for PR CI first.

**What MQ CI actually is**

- MQ opens a temporary **`[Graphite MQ] Draft PR`** (`gtmq_*` branch). Same
  repo `ci.yml` on **our** runners (heavy jobs → Railway; `optimize_ci` /
  `validate` → `ubuntu-latest`). Graphite only orchestrates.
- Watch: Graphite merges UI, draft PR Checks, or the original PR’s
  `graphite-app` “Merge activity” comment.
- UI: blue badge = active (CI running **or** “Creating temporary PR”);
  gray = queued waiting.
- `graphite-ci-action` **never skips** while a PR is in the MQ (product
  behavior). Merge-time cost is controlled by Graphite MQ UI (**topmost of
  stack** + **parallel stacks** + FF), not mid-stack review skip.
- Touching `.github/workflows/ci.yml` triggers **full** `test:pnpm` via
  `shouldRunEverything` — MQ drafts for those PRs look “slow” (~minutes);
  docs-only drafts stay short.

**Landed status quirks**

- Graphite FF often closes the GitHub PR as **`CLOSED` with `mergedAt:
  null`**. Treat **`main` history** / Graphite “Merged” as truth, not
  `gh pr view --json mergedAt`.
- After a lower PR lands, upstack/siblings may need `gt sync` + resubmit;
  MQ usually restacks speculative drafts — prefer waiting over manual
  rebase storms.

**Grok land babysit**

- Do not “observe forever” once Graphite says queued/already merging and
  draft CI is running — report the draft URL and only act on red CI /
  failed MQ eviction / Chase ask.
- Confirm land by `main` tip SHA containing `(#N)`, not by GitHub
  `mergedAt`.
- Do not re-run Opus’s enqueue unless the MQ entry failed.

#### Fallbacks (only when Graphite product/CLI is unavailable)

1. **`gh stack`** — only if Graphite CLI/app is down **and** Chase
   approves for that task.
2. **Manual `--base` chains** — last resort; document in the done report;
   Chase must approve.
3. **Sequential onto `main`** — only when the user asks for one-PR-at-a-time.

**Not a fallback:** `gh pr create` because `gt submit` failed in a bad
checkout. That is always **fresh-clone recovery** (above).

Do **not** default back to `gh stack` on `sume-com` while Graphite MQ is on.

#### Delegation checklist (main agent → worker)

Every **Opus** implement prompt on `sume-com` **must** include this block
(verbatim intent; wording may match). Full ops: **`sume-gt-mq`**.

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

When the BP has a PR train, also say:

- Implement **all** locked slices in one session, then **`gt submit --stack`**.
- Do not open only PR-A then stop.
- Report Graphite + GitHub PR URLs for every layer.
- **`cstack-gt-wait-merge`** labels the **tip** (whole train) → **STOP** — Grok owns
  land babysit unless the user said otherwise.
- Do not invent extra slices beyond the BP train.

The **Grok** land prompt must say: MQ already enqueued → watch draft CI →
**stay until** `origin/main` has `(#N)` (re-enqueue on eject; do **not**
STOP at enqueue; do **not** write `HANDOFF: grok-land`) → issue
close/comment if acceptance met → brief deploy watch if authorized; fix
only if land CI red needs a tiny push (otherwise bounce code back to
Opus). Forbidden: re-enqueue when already queued **and still in MQ**;
local `gt track` / clone thrash. If Opus used `HANDOFF: grok-ci-merge`
(label rejected / missing): `gh pr edit <N> --add-label merge-queue` now
→ then stay until main tip. If the PR was not Graphite-bound, repair with
fresh-clone `gt submit` before labeling.

Docs: https://graphite.com/docs/cli-overview · MQ: https://graphite.com/docs/graphite-merge-queue  
Repo ops (sume-com): `docs/operations/pr-stack-and-merge-queue.md` · lock [#2242](https://github.com/sumelabs/sume-com/issues/2242)

### Pipeline 2 — clear / well-scoped work

Use when the work is already clear: obvious bug fix, small feature, mechanical
change, well-understood follow-up.

Default still follows the same split when a PR is expected:

1. **Opus** — implement → `gt submit` → tip `merge-queue` → STOP
   (preferred for anything non-trivial).
2. **Grok** — land babysit → ops.

**Exception:** truly tiny / mechanical one-file follow-ups may stay
**Grok end-to-end** (issue optional → implement → PR → enqueue → land) so
Opus is not spent on noise. When unsure, prefer Opus through enqueue and
Grok for land.

### Hard model rules

- **Opus workers run via `claude-human-stream`, not Cursor Task.** From a Cursor
  main agent, never spawn Opus via `Task`/`claude-opus-*`; use the wrapper
  (not bare `stream-json` / not plain `text` for long jobs).
- **Grok workers run via `agent-human-stream --backend grok`, not Cursor Task.**
  From a Cursor main agent, never spawn land/author Grok via `Task` /
  `cursor-grok-*`. Composer explore stays `Task`.
- **Opus owns PR authoring through MQ enqueue by default** (design/RCA when
  needed, then code through **fresh-clone `gt create` → `gt submit` →
  tip `merge-queue`**). Do **not** default Opus onto MQ draft / land /
  deploy babysit after the label.
- **Grok owns post-enqueue land ops by default:** MQ draft CI → `main` tip
  confirm → deploy/flag babysit, release watches, and other mainly
  non-coding ops. Fallback: **label the tip now** → land when Opus
  could not label. If land CI needs a real code fix, either push a tiny
  fix **or** bounce implementation back to Opus — do not silently start a
  parallel redesign.
- **Composer is exploration-only.** Composer may be used only for read-only
  codebase exploration / search / survey (e.g. `explore`-type subagents:
  "where is X handled", "map this flow"). Composer must NOT write issues,
  implement code, open/merge PRs, mutate ops state, or babysit releases.
- When unsure whether a task is "heavy" or "clear", ask: would a context-free
  implementer need a design document to avoid building the wrong thing? If
  yes → Pipeline 1 (Opus designs, then Opus implements through MQ enqueue).
  If tiny/mechanical → Pipeline 2 exception (Grok e2e OK).
- The delegation prompt must state the model choice and the stage boundary
  (e.g. "Opus: gt submit → tip merge-queue → STOP" vs
  "Grok: land babysit → close issue"; fallback
  "Grok: label tip now → land").

## Worker Status Checks

When the user asks for status:

1. Read active worker threads in parallel when possible.
2. Group results by worker.
3. Distinguish:
   - `active`: currently running.
   - `idle/completed`: worker final report exists. This is **not**
     Chase 완료 unless `origin/main` has `(#N)`.
   - `blocked`: needs user input or external access.
   - `merged`: `origin/main` has `(#N)` and, if relevant, production
     workflow status. Enqueue / green checks / “Your changes” ≠ merged.
   - `bad state`: final report drifted, wrong task, or thread context mixed.
4. State the next action for each worker.

For **active** Jobs, also state **진행** (same rule as the status
board): last real step, not “still running.”

Keep user-facing status concise. Do not paste long worker logs unless requested.

## Compacting Workers

Ask a worker to compact when:

- Its task is done and final report should be preserved.
- Its context got long or mixed.
- The main agent is about to reuse the thread for a new task.
- The user explicitly says to compact finished workers.

The compact prompt should say what to preserve and whether the worker should stay
idle after compacting.

## Linear Issues

When the user asks to add work to Linear:

- Use the Linear connector/skill directly from the main agent.
- Read team, status, and assignee identifiers before creating/updating.
- Create implementation-ready descriptions when the issue will seed future agents.
- Put status and assignee exactly as requested when possible.

## Safety Rules

- Never delegate secrets. If env/log access is needed, instruct the worker to
  sanitize output.
- Do not let workers perform broad production mutations without explicit scoped
  authorization.
- Do not manually deploy `sume_so`; production rollout should follow repo rules.
- Do not override user work in dirty worktrees.
- If a worker thread produces a result for the wrong task, mark that thread as
  mixed/bad state, compact it, and reassign the task to an idle worker.

## Final Updates To User

Summaries should answer:

- What was delegated or completed.
- Which worker owns it.
- Current state and next action.
- Any PR/Linear/thread links or IDs.

Avoid pretending a worker completed a task when it only started, explored, or
produced a mismatched final answer.

## Harness Wiring

All three harnesses read *this* file. Only the entry point differs.
**Cursor-only** sections above are ignored when Codex or Claude Code is main.

| Harness | Entry point | Mechanism |
|---------|-------------|-----------|
| Codex | `~/.codex/AGENTS.md` | "Sume Orchestration" section points here; skill dir symlinked into `~/.codex/skills/` |
| Claude Code | `~/.claude/CLAUDE.md` | imports `~/.codex/AGENTS.md`; skill dir symlinked into `~/.claude/skills/` |
| Cursor | Pointer rule(s) below | `alwaysApply` pointer only; skill dir symlinked into `~/.cursor/skills/` |

### Cursor pointer locations

1. **User-global (preferred):** `~/.cursor/rules/main-agent-orchestration.mdc`
   — applies across projects when Cursor loads user-level `.cursor/rules`
   (Agents Window / newer Cursor builds). Also keep a one-line **User Rules**
   (Settings → Rules) pointer if a given Cursor build ignores that folder:
   `Sume main-agent SoT: ~/.agents/skills/sume-main-agent-orchestration/SKILL.md (ignore Cursor-only sections unless main agent is Cursor).`
2. **Per-repo fallback:** `<repo>/.cursor/rules/main-agent-orchestration.mdc`
   — still required for Editor Agent when user-global rules are not loaded.

Install or refresh pointers with:

```bash
# user-global + one or more repos
~/.agents/skills/sume-main-agent-orchestration/install-cursor-rule.sh --user
~/.agents/skills/sume-main-agent-orchestration/install-cursor-rule.sh <repo-path>...
```

The pointer template is `cursor-rule-template.mdc` in this directory. It must
stay a pointer: role split, language, model routing, and monitoring policy
belong in this SKILL.md only (never fork into the `.mdc`).

To verify the wiring end to end:

```bash
~/.agents/skills/sume-main-agent-orchestration/check-wiring.sh
```
