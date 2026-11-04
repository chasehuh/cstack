# cstack

Chase’s **Sume desk pack**. **This repo is the SoT** (`chasehuh/cstack`).
Clone + install, and Claude Code (main agent on the laptop, Opus workers on
the M5 Mac Mini) and Codex resolve to the same tree, not an rsync fork.

What was removed and why: `docs/CHANGELOG.md`.

## One-click install

```bash
curl -fsSL https://raw.githubusercontent.com/chasehuh/cstack/main/bootstrap.sh \
  | bash -s -- --sume-com ~/sume/sume-com
```

That clones/updates **`~/.cstack/src`** then runs `install.sh`. An existing
checkout updates with:

```bash
git -C ~/.cstack/src pull --ff-only && ~/.cstack/src/install.sh
```

Requires: `git`, `gh` with the `gh stack` extension (install.sh adds it), and
the **tokenmaxxing-wrapped** `claude` on PATH (`docs/TOKENMAXXING.md`).

**Never commit secrets.** Desk keys stay in `~/.sume/ops/` on the machine.
Tokenmaxxing credentials stay in `~/.config/tokenmaxxing/` + keychain.

## What install does

- `~/.cstack/src` → this checkout
- `~/.agents/skills/<name>` → **symlink** into `sume-desk/skills/<name>`,
  same for `~/.claude/skills`, `~/.codex/skills`, `~/.cursor/skills`
- Host bins on `~/.local/bin`: `sume-bg-launch` + `sume-bg-remote` (the M5
  side, `docs/MINI-WORKER-HOST.md`), `agent-human-stream`,
  `claude-human-stream`, `sume-cron-job`, `cstack-slack-post`,
  `cstack-clone`, `cstack-clone-rm`, `cstack-mirror-sync`,
  **`cstack-gt-wait-merge`**, `cstack-gate`, `cstack-ego-reap`
- `~/.cstack/mini-ssh.env` → `CSTACK_MINI_SSH` = the M5 from
  `sume-desk/hosts.env`
- `~/.cstack/state/` (logs, registry, `prompts/`), never inside the git tree
- Sections in `~/.codex/AGENTS.md` (Claude Code imports it) and
  `~/.claude/CLAUDE.md`: orchestration pointer, worker mode, author
  completion, no code comments (`docs/CODE-COMMENTS.md`), no feature flags
  (`docs/FEATURE-FLAGS.md`), release lock (`docs/RELEASE-LOCK.md`),
  browser = ego-browser only (`docs/BROWSER.md`)
- Offline tests: launcher host routing, cron, Slack tail, wait-merge matcher

Edit files **here**, then `./install.sh`.

## Layout

```
AGENTS.md                 # first file a raw agent reads
bootstrap.sh / install.sh
docs/FLOW.md              # map of rules → when
docs/CHANGELOG.md         # what changed / was removed in the desk
docs/MINI-WORKER-HOST.md  # sume-bg-launch --host mini (M5 worker host)
docs/MINI-CRON.md         # scheduled jobs on the M5
docs/SLACK-REPORT.md      # worker completion report → #coding-agents
docs/TOKENMAXXING.md      # local Claude = tokenmaxxing supervisor
docs/RELEASE-LOCK.md / CODE-COMMENTS.md / FEATURE-FLAGS.md / BROWSER.md
docs/PSTACK.md / STE.md   # vendored engineering + STE skills
sume-desk/
  hosts.env               # M5 / M4 ssh targets (single SoT)
  GRAPHITE-HARD-LOCK.md   # STACKS paste block for every author prompt (old name)
  *-snippet.md            # sections install.sh writes into ~/.codex / ~/.claude
  worker.env              # load caps every worker inherits
  skills/                 # orchestration, gt-mq, mega-issue, Formats LC,
                          # sume-architect / -blast-radius / -principles /
                          # -automate-me, sume-ste
  cursor-rules/           # always-on rules for Cursor as an editor (no main-agent mechanics)
```

## Flow in one line

Discuss → lock → GitHub issue → `sume-bg-launch --host mini` (Opus on the
M5; fresh, fork or steer) → `cstack-clone` → `gh stack submit --auto --open`
→ **`cstack-gt-wait-merge`** → the author stays until `origin/main` `(#N)` →
Korean report in `#coding-agents` → `cstack-clone-rm`.
