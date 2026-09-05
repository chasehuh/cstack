# cstack

Chase’s **Sume desk pack**. **This repo is the SoT**
(`chasehuh/cstack`). Clone + install and Cursor, Claude Code, Codex, and
Grok Build all resolve to the same tree — not a rsync fork.

The old review/merge/audit skills that used to live here are
**deprecated and removed**. Do not restore them.

## One-click install

```bash
curl -fsSL https://raw.githubusercontent.com/chasehuh/cstack/main/bootstrap.sh \
  | bash -s -- --sume-com ~/sume/sume-com
```

That clones/updates **`~/.cstack/src`** then runs `install.sh`.

```bash
# already have a clone
git clone git@github.com:chasehuh/cstack.git ~/.cstack/src
~/.cstack/src/install.sh --sume-com ~/sume/sume-com
```

Requires: `git`, `gh`, Graphite `gt`, and **tokenmaxxing-wrapped**
`claude` on PATH for Opus/Fable workers (see `docs/TOKENMAXXING.md`).
Codex workers (`agent-human-stream --backend codex`) use the
tokenmaxxing-wrapped `codex` (separate Codex pool, same doc).
Grok Build (`grok` on PATH) uses the same skills via `~/.grok/skills`.

**Never commit secrets.** Desk keys stay in `~/.sume/ops/` on the machine.
Tokenmaxxing credentials stay in `~/.config/tokenmaxxing/` + keychain.

## What install does

- `~/.cstack/src` → this checkout
- `~/.agents/skills/<name>` → **symlink** into `sume-desk/skills/<name>`
- Same symlink for `~/.cursor|claude|codex|grok/skills`
- Host bins on `~/.local/bin`: `cstack-clone`, `cstack-clone-rm`,
  `cstack-mirror-sync`, **`cstack-gt-wait-merge`**, `agent-human-stream`
- Runtime logs at `~/.cstack/state/` (not inside the git tree)
- Pointers in `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.grok/AGENTS.md`

Edit files **here**, then `./install.sh`. Do not edit the skill copies
under `~/.agents` as if they were independent.

## Layout

```
AGENTS.md                 # first file a raw agent reads
bootstrap.sh              # one-click → ~/.cstack/src + install
install.sh
docs/FLOW.md              # map of rules → when
docs/TOKENMAXXING.md      # local Claude = tokenmaxxing supervisor
sume-desk/
  GRAPHITE-HARD-LOCK.md   # paste block for every author prompt
  skills/                 # SoT (orchestration, gt-mq, mega-issue, Formats LC)
  cursor-rules/user/      # ~/.cursor/rules
  cursor-rules/sume-com/  # <repo>/.cursor/rules
```

## Flow in one line

Discuss → lock → GitHub issue → `agent-human-stream` / `claude-human-stream`
(Opus; Fable only if named; Grok Build via `--backend grok`; Codex via
`--backend codex` only if named) →
`cstack-clone` → `gt submit` → **`cstack-gt-wait-merge`** (tip
`merge-queue` now; MWR if PR CI pending) → STOP →
Grok lands `main` → `cstack-clone-rm`.

Details: `docs/FLOW.md` then the skills after install.
Formats (LC package + dest fire): `mobidoo-live-commerce-update`.
Local Claude quota: `docs/TOKENMAXXING.md`.
