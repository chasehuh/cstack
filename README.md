# cstack

Chase’s **Sume desk pack**. Clone + `./install.sh` and any agent (Cursor,
Claude Code, Codex) can run the same flow we use on `sume-com`.

The old review/merge/audit skills that used to live in this repo are
**deprecated and removed**. Do not restore them.

## Install

```bash
git clone git@github.com:chasehuh/cstack.git
cd cstack
chmod +x install.sh
./install.sh --sume-com ~/sume/sume-com   # second arg optional
```

Requires: `git`, `rsync`, `gh`, Graphite `gt`, and **tokenmaxxing-wrapped**
`claude` on PATH for Opus/Fable workers (see `docs/TOKENMAXXING.md`).

**Never commit secrets.** Desk keys stay in `~/.sume/ops/` on the machine.
Tokenmaxxing credentials stay in `~/.config/tokenmaxxing/` + keychain.

## Layout

```
AGENTS.md                 # first file a raw agent reads
install.sh
docs/FLOW.md              # map of rules → when
docs/TOKENMAXXING.md      # local Claude = tokenmaxxing supervisor
sume-desk/
  skills/                 # SoT (orchestration, gt-mq, mega-issue, LC CS update)
  cursor-rules/user/      # ~/.cursor/rules
  cursor-rules/sume-com/  # <repo>/.cursor/rules
```

## Flow in one line

Discuss → lock → GitHub issue → `agent-human-stream` / `claude-human-stream`
(Fable/Opus; Grok Build via `--backend grok`) →
fresh clone `gt submit` → `gt merge` (MQ) → STOP → Grok lands `main`.

Details: `docs/FLOW.md` then the two SKILL.md files after install.
Local Claude quota: `docs/TOKENMAXXING.md`.
