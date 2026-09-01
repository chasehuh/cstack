# CStack — Sume desk (read this first)

You are on **Chase’s agent desk**. This repo (`chasehuh/cstack`) is the
**installable source of truth** for how Sume work is run: discuss → lock →
GitHub issue → Opus (Fable only if named) through Graphite MQ (`cstack-clone`,
not a Cursor worktree) → Grok land → `cstack-clone-rm`.

Old `merge` / `audit` / `propose` copies that used to live here are
**deprecated**. Ignore them. Use `sume-desk/` only.

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
2. `~/.agents/skills/sume-gt-mq/SKILL.md` before any `gt submit` / `gt merge`
3. `docs/FLOW.md` (this pack’s map of files → when to apply)
4. `docs/TOKENMAXXING.md` — this machine’s `claude` is a **tokenmaxxing**
   supervisor (Chase/dev Max pool), not a single login and not an API key
5. Formats SoT (LC package + dest fire + catalog pin):
   `~/.agents/skills/mobidoo-live-commerce-update/SKILL.md` before any
   `createCommit` / CS push / dest Format run create

Do **not** fork those skills into chat memory. Edit the files in this repo
and re-run `./install.sh`.

## You are the main agent unless told otherwise

- Reply to the user in **their language** (Korean in → Korean out).
- **Chat work report is SoT.** Slack `#coding-agents` is a team mirror.
  Chase must understand the turn without opening Slack. End every
  Cursor main-agent turn with the status board tables after that report
  (`end-of-turn-worker-brief.mdc`).
- Workers / Task / `agent-human-stream` / `claude-human-stream` always work
  in **English**.
- Do not silently implement what Chase expected on the Opus/Fable loop.
- Cursor main agent: Opus/Fable = `claude-human-stream` (=
  `agent-human-stream --backend claude`) in a **background**
  Shell (`block_until_ms: 0`). Grok land / Grok author =
  `agent-human-stream --backend grok` (same Shell recipe).
  Never Cursor `Task` + `claude-opus-*` or `cursor-grok-*`.
  Composer explore stays Cursor `Task`.
  That wrapper must hit **tokenmaxxing’s** `claude` (`~/.config/tokenmaxxing/bin`
  ahead of the real CLI). Quota swap is automatic; expired parked tokens are
  not — see `docs/TOKENMAXXING.md`.
- Terminal title / board Job = `Opus : <job-slug> (#N)` or `Fable : …`.
- `sume-com` PRs: `cstack-clone` + `gt create` + `gt submit`. **Forbidden:**
  `gh pr create`. After submit: **`cstack-gt-wait-merge`** (5–12s, default
  8s) → STOP. Grok owns land. Skill: `sume-gt-mq`.
- Same SoT for **Cursor, Claude Code, Codex, and Grok Build**. Edit files
  in this repo (`chasehuh/cstack`) and re-run `./install.sh`. Do not fork
  into `~/.agents/skills` copies — those are symlinks into this tree.
- Dev-only until Chase says otherwise. Prod test = Sumelabs + desk SoT key
  only (never paste keys).
- Stay in the opened workspace; operate on worktrees/clones via paths.

## What “done” looks like

A coding train is done when Graphite MQ is **enqueued** (or `merge-queue`
label) and a Grok land babysit is running — not when a worker is still
polling `main`.
