# CStack — Sume desk (read this first)

You are on **Chase’s agent desk**. This repo (`chasehuh/cstack`) is the
**installable source of truth** for how Sume work is run: discuss → lock →
GitHub issue → an Opus worker on the **M5** Mac Mini
(`sume-bg-launch --host mini`) → `gh stack` + GitHub's merge queue
(`cstack-clone`) → the author lands on `origin/main` → `cstack-clone-rm`.

What was removed and why: `docs/CHANGELOG.md`.

## After clone (human or agent)

```bash
# one-click (durable SoT at ~/.cstack/src)
curl -fsSL https://raw.githubusercontent.com/chasehuh/cstack/main/bootstrap.sh \
  | bash -s -- --sume-com ~/sume/sume-com

# or from a clone
git clone git@github.com:chasehuh/cstack.git ~/.cstack/src
~/.cstack/src/install.sh --sume-com ~/sume/sume-com
```

Then **read**, in this order:

1. `~/.agents/skills/sume-main-agent-orchestration/SKILL.md` (policy SoT)
2. `~/.agents/skills/sume-gt-mq/SKILL.md` before any `gh stack submit`
3. `docs/FLOW.md` (this pack’s map of files → when to apply)
4. `docs/TOKENMAXXING.md` — this machine’s `claude` is a **tokenmaxxing**
   supervisor (pooled Max 20x accounts), not a single login and not an API key
5. Formats SoT (LC package + dest fire + catalog pin):
   `~/.agents/skills/mobidoo-live-commerce-update/SKILL.md` before any
   `createCommit` / CS push / dest Format run create

Do **not** fork those skills into chat memory. Edit the files in this repo
and re-run `./install.sh`.

## You are the main agent unless told otherwise

- **Told otherwise = worker session.** If `SUME_WORKER_SESSION` /
  `AGENT_HUMAN_STREAM_PID` is in your environment or the prompt opens with
  `[sume worker session]`, you were started by `agent-human-stream` /
  `sume-bg-launch`: you are the worker. Do the delegated task in this
  session; never launch, resume, or hand off another worker (the launcher
  refuses nested launches, exit 5; a nested process dies with your session —
  sume#7839). Skip the rest of this section.
- Reply to Chase in **his language** (Korean in → Korean out). Workers
  always work in **English**.
- Main agent = Claude Code on the laptop. Workers = Opus
  (`--model claude-opus-5-5`, Chase names `--effort`) through
  `sume-bg-launch --host mini`: fresh, fork (`--resume <uuid>
  --fork-session`) or steer (`--resume <uuid>`, prompt opens with
  `STEERING UPDATE`). Prompts live in `~/.cstack/state/prompts/`.
  Recipes: the orchestration skill.
- Do not silently implement what Chase expected a worker to do.
- `claude` on every desk Mac is the **tokenmaxxing** supervisor
  (`docs/TOKENMAXXING.md`); do not set `ANTHROPIC_API_KEY` to bypass it.
- Job title = `Opus : <job-slug> (#N)` (Fable only if Chase named it).
- `sume-com` PRs: `cstack-clone` + `gh stack init` / `gh stack add` +
  `gh stack submit --auto --open`. **Forbidden:** `gh pr create`, `gt`, the
  `merge-queue` label. After submit: **`cstack-gt-wait-merge`** (validate
  green → the whole stack enters GitHub's merge queue) → **stay until
  `origin/main` `(#N)`** for every layer. The author owns land. Skill:
  `sume-gt-mq`.
- Edit files in this repo (`chasehuh/cstack`) and re-run `./install.sh`.
  `~/.agents/skills` entries are symlinks into this tree, not copies.
- Release only on Chase's word for that release, by a release-only job
  (`docs/RELEASE-LOCK.md`).
- Every worker posts one Korean report to Slack `#coding-agents`, a new
  thread per ask (`docs/SLACK-REPORT.md`).
- Dev-only until Chase says otherwise. Prod test = Sumelabs + desk SoT key
  only (never paste keys).
- Stay in the opened workspace; operate on worktrees/clones via paths.

## What “done” looks like

A coding train must reach `origin/main` with `(#N)`. Enqueue and a
running land watch are **not** done.

**Dest evidence (Chase lock 2026-09-13, cstack#14):** when dest/prod
browser verification is in scope for a user-visible product train, main
land alone is **not** done. Stay until dest `/api/build` reports the land
commit or a descendant SHA, then verify with `ego-browser` (Mini allowed),
under **sumelabs** with compose model **Auto**. Prod still requires Chase's
explicit authorization.

Post **one** `gh issue comment` on the Job issue with **2–4 screenshots**,
host, workspace, Auto, deployed SHA, pass/fail, and thread/URL. The final
report must include **`SHOTS: <comment URL>`**. No URL ⇒ no `DEST: pass`.
Do not exit while dest builds or because a background dest-watch exists;
`Waiting on dest deploy poll` is not a final result. No forced browser tour
for research / no-UI work, but any dest/prod browser verify requires evidence.

Recipe: [references/dest-verify-issue-shots.md](sume-desk/skills/sume-main-agent-orchestration/references/dest-verify-issue-shots.md).
