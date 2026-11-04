# Sume desk flow — file map

This is the catalog. **Policy text lives in the skills**, not here. If this
file and a skill disagree, the skill wins; fix this map.

## The loop (Chase, always)

Discuss (Chase's language) → lock nouns / defaults / non-goals →
**GitHub mega-issue** (`github-mega-issue`) when a context-free worker needs
it → **Opus** on the M5 (`sume-bg-launch --host mini`; Fable only if Chase
named it) → `cstack-clone <slug>` → `gh stack init` / `gh stack add` →
`gh stack submit --auto --open` → **`cstack-gt-wait-merge`** → the author
stays until `origin/main` `(#N)` → Korean report in `#coding-agents`.

Triggers: “그렇게 가보자”, “mega-issue → opus”, “플로우 타자”.

## Who runs what (2026-11-01)

| Role | Runs on | How |
|---|---|---|
| Main agent | Laptop, Claude Code | orchestration skill; prompts in `~/.cstack/state/prompts/` |
| Worker | M5 Mac Mini | `sume-bg-launch --host mini … -- --model claude-opus-5-5 --effort <Chase's pick>` |
| Fork | M5 | `--resume <uuid> --fork-session` (parent keeps running) |
| Steer | M5 | `--resume <uuid>`, prompt opens `STEERING UPDATE`; the older job on that session is stopped first |
| Land | worker | `gh stack` + `cstack-gt-wait-merge` → `origin/main` |
| Release | release-only job | only on Chase's word for that release |

## Layer 0 — SoT skills (symlinked into `~/.agents/skills/`)

| Path in this repo | When |
|---|---|
| `sume-desk/skills/sume-main-agent-orchestration/` | Any main-agent turn: launch / fork / steer, model + effort, status, Slack, dest evidence |
| `sume-desk/skills/sume-gt-mq/` | **Before** every `gh stack submit` / queue unstick / land |
| `sume-desk/skills/github-mega-issue/` | Filing the durable issue a worker executes without the chat |
| `sume-desk/skills/mobidoo-live-commerce-update/` | **Formats SoT**: LC package pull/push, catalog pin vs execute, dest fire |
| `sume-desk/skills/sume-architect/` | Before code that crosses a module boundary or adds an API / data model |
| `sume-desk/skills/sume-blast-radius/` | Before submitting a risky diff (`## Blast radius` in the PR body) |
| `sume-desk/skills/sume-principles/` | 24 engineering principles (vendored) |
| `sume-desk/skills/sume-automate-me/` | Only when Chase asks: refresh `chase-mode` from his corrections |
| `sume-desk/skills/sume-ste/` | Only when asked: Simplified Technical English for English technical docs (`docs/STE.md`) |

`sume-architect`, `sume-blast-radius`, `sume-principles` and
`sume-automate-me` are adapted from pstack (MIT, `docs/PSTACK.md`).

## Always-on rules (every harness)

| Rule | SoT | Where install.sh puts it |
|---|---|---|
| No code comments | `docs/CODE-COMMENTS.md` | `~/.codex/AGENTS.md` section (Claude Code imports it), Cursor `no-code-comments.mdc` |
| No feature flags | `docs/FEATURE-FLAGS.md` | same, `no-feature-flags.mdc` |
| Release lock | `docs/RELEASE-LOCK.md` | same, `release-lock.mdc`, the worker preamble, `GRAPHITE-HARD-LOCK.md` |
| Browser = ego-browser only | `docs/BROWSER.md` | `~/.codex/AGENTS.md` section, the worker preamble, `aside-browser-verify.mdc` (ego-only content) |
| Worker mode (no nested launches) | `docs/MINI-WORKER-HOST.md` § Nested | `~/.codex/AGENTS.md` section, the worker preamble |
| Author completion (stay until main) | `sume-gt-mq` | `~/.claude/CLAUDE.md` section |
| Slack report | `docs/SLACK-REPORT.md` | the launcher appends the tail to every prompt |

`check-wiring.sh` checks the Codex and Claude entries.

## Cursor rules (editor only)

Cursor is not the main agent now. `cursor-rules/user/` keeps rules that
still hold when Cursor is used as an editor: `no-code-comments`,
`no-feature-flags`, `release-lock`, `origin-main-sot`,
`aside-browser-verify`, `canvas-user-language`, `chat-title-folder-prefix`.
`cursor-rules/sume-com/` holds repo rules (`stay-in-workspace`,
`dev-only-until-release`, `formats-api-dev-mobidoo`,
`prod-testing-sumelabs-only`, `ci-local-preflight`, `agents-ui-taste`,
`chat-title-prefix`, `aside-browser-verify`, `canvas-user-language`).

## Local Claude (tokenmaxxing)

`claude` on the laptop and the M5 is the
[tokenmaxxing](https://github.com/anaclumos/tokenmaxxing) supervisor: pooled
Max 20x accounts, swapped near quota. SoT: **`docs/TOKENMAXXING.md`**.

- PATH: `~/.config/tokenmaxxing/bin` **before** the real CLI
- `tokenmaxxing doctor` / `status` before blaming the wrapper
- The M5 reads `~/.claude/.credentials.json` (keychain locked over ssh);
  the live file mirror keeps it in step (`--mirror`)

### Agent stream

`sume-bg-launch` runs `agent-human-stream --backend claude` (on the M5 under
`sume-bg-remote run`). Every launch prints `📎 session_id=<id>`, tees to
`~/.cstack/state/opus-live/`, and appends to `opus-sessions.jsonl`. The
wrapper still has `--backend grok|codex`; the desk does not use them now.

**Completion report (default on):** the wrapper appends the slack-report
tail (forks and fresh jobs get the full tail, steers a one-line reminder,
`sume-cron-job` none). Every report is a new top-level message, steers
included; `--same-thread` makes a poke reply in the job's thread. A DM
request adds a DM and never replaces the channel report. Opt out: `--no-slack-report`, `CSTACK_SLACK_REPORT=0`,
or `<!-- slack-report:off -->`. Dry run: `sume-bg-launch --print-prompt …`.

## Stacks and the merge queue (sume-com only)

Graphite is retired for `sume` since 2026-10-30: GitHub stacks (`gh stack`)
and GitHub's merge queue (ruleset `main-merge-queue`, squash).

- Isolated clone: `cstack-clone <slug>` → `/tmp/sume-com-<slug>` from
  `~/.cstack/mirrors/sume-com.git`; after land `cstack-clone-rm <slug>`.
- Never `gh pr create` on `sumelabs/sume`.
- Queue run red → fix, `gh stack sync`, run the helper again; ≤2 reruns for
  a flake.
- Landed = `main` commit `(#N)` for every layer.

## What is not in this pack (on purpose)

- API keys, Code Storage PEMs, Clerk cookies, Railway tokens
- `~/.sume/ops/*` secrets (policy may name the **path**, never the value)
- Live `opus-live` logs / session registries / prompts
- Product code (`sume-com` stays its own repo)
