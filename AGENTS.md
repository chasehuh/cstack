# CStack — Sume desk (read this first)

You are on **Chase’s agent desk**. This repo (`chasehuh/cstack`) is the
**installable source of truth** for how Sume work is run: discuss → lock →
GitHub issue → Fable/Opus through Graphite MQ → Grok land.

Old `merge` / `audit` / `propose` copies that used to live here are
**deprecated**. Ignore them. Use `sume-desk/` only.

## After clone (human or agent)

```bash
git clone git@github.com:chasehuh/cstack.git
cd cstack
./install.sh
# optional: pin a sume-com checkout
./install.sh --sume-com /path/to/sume-com
```

Then **read**, in this order:

1. `~/.agents/skills/sume-main-agent-orchestration/SKILL.md` (policy SoT)
2. `~/.agents/skills/sume-gt-mq/SKILL.md` before any `gt submit` / `gt merge`
3. `docs/FLOW.md` (this pack’s map of files → when to apply)
4. `docs/TOKENMAXXING.md` — this machine’s `claude` is a **tokenmaxxing**
   supervisor (Chase/dev Max pool), not a single login and not an API key
5. Live-commerce Code Storage publish:
   `~/.agents/skills/mobidoo-live-commerce-update/SKILL.md` before any
   `createCommit` / CS push (dest first, then both prod repos)

Do **not** fork those skills into chat memory. Edit the files in this repo
and re-run `./install.sh`.

## You are the main agent unless told otherwise

- Reply to the user in **their language** (Korean in → Korean out).
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
- `sume-com` PRs: fresh clone + `gt create` + `gt submit`. **Forbidden:**
  `gh pr create`. After submit: `gt merge --dry-run` every 15–30s →
  `gt merge` → STOP. Grok owns land. Skill: `sume-gt-mq`.
- Dev-only until Chase says otherwise. Prod test = Sumelabs + desk SoT key
  only (never paste keys).
- Stay in the opened workspace; operate on worktrees/clones via paths.

## What “done” looks like

A coding train is done when Graphite MQ is **enqueued** (or `merge-queue`
label) and a Grok land babysit is running — not when a worker is still
polling `main`.
