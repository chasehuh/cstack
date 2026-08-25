# Sume desk flow — file map

This is the catalog. **Policy text lives in the skills**, not here.
If this file and a skill disagree, the skill wins; fix this map.

## The loop (Chase, always)

Discuss (same language as Chase) → lock nouns/defaults/non-goals →
**GitHub mega-issue** (`github-mega-issue` skill) → **Fable/Opus**
(`claude-human-stream` = `agent-human-stream --backend claude`, job slug
2–4 kebab tokens) → fresh `/tmp` clone →
`gt create` → `gt submit` → poll `gt merge --dry-run` 15–30s →
`gt merge` (MQ) → **STOP** → **Grok** land (`main` tip `(#N)`).

Triggers: “그렇게 가보자”, “mega-issue → opus”, “플로우 타자”.

Stage: `STOP at MQ enqueue` unless Chase said “merge까지 / landing까지”.

## Layer 0 — SoT skills (install into `~/.agents/skills/`)

| Path in this repo | Installs as | When |
|---|---|---|
| `sume-desk/skills/sume-main-agent-orchestration/` | `sume-main-agent-orchestration` | Any main-agent turn: roles, language, Opus vs Grok vs Composer, Graphite hard lock, Cursor-only monitoring |
| `sume-desk/skills/sume-gt-mq/` | `sume-gt-mq` | **Before** every `gt submit` / `gt merge` / MQ unstick / land handoff |
| `sume-desk/skills/github-mega-issue/` | `github-mega-issue` | Filing the durable issue the worker will execute without the chat |
| `sume-desk/skills/mobidoo-live-commerce-update/` | `mobidoo-live-commerce-update` | **Before** any Code Storage `createCommit` / LC package push. Pull → conceive → lock diff → two-stage push (dest `mobidoo/live-commerce`, then prod Mobidoo **and** Sumelabs) |

`sume-main-agent-orchestration/state/` is **not** shipped (live logs).
The wrapper recreates it.

## Layer 1 — user-global Cursor rules (`~/.cursor/rules/`)

Pointers + cookbooks. They must stay **pointers** where noted — do not
duplicate the full SKILL into the `.mdc`.

| File | Role |
|---|---|
| `main-agent-orchestration.mdc` | Pointer at orchestration SKILL |
| `sume-chase-work-loop.mdc` | Discuss → issue → Opus enqueue → Grok land |
| `opus-background-terminal.mdc` | `claude-human-stream` recipe: prompt file, `cd` not `--cwd`, `block_until_ms: 0`, title = Job |
| `graphite-ci-ready.mdc` | Ready-signal = `gt merge --dry-run`, poll ≤30s, fail ≠ wait |
| `status-board.mdc` | Status board: `지금` / `스테이징` / `백로그` (24h). Confirm = resolve (drop; do not show `확인됨`) |
| `active-workers-canvas.mdc` | Canvas surface of the status board |
| `end-of-turn-worker-brief.mdc` | Every turn reprints the status board in chat |
| `chat-title-folder-prefix.mdc` | Rename chats `[workspace-folder] …` |
| `origin-main-sot.mdc` | Code Q&A reads `origin/main`, not dirty local main |
| `worker-reasoning-effort.mdc` | Code: opus medium / fable high / grok xhigh. Research: grok medium (opus+fable low) |

## Layer 2 — `sume-com` repo rules (install into `<sume-com>/.cursor/rules/`)

| File | Role |
|---|---|
| `stay-in-workspace.mdc` | Do not `move_agent_to_root` to a worktree |
| `dev-only-until-release.mdc` | Default `www.dev` / Railway development |
| `formats-api-dev-mobidoo.mdc` | Dest Formats fire: `api.dev` + `@mobidoo` / `live-commerce`, webhook.site, loose `full_video` |
| `prod-testing-sumelabs-only.mdc` | Prod smoke: Sumelabs + `chase@sume.com` + local env file only |
| `ci-local-preflight.mdc` | Changed-gate scripts before claiming CI-ready |
| `agents-ui-taste.mdc` | Agents chrome: sentence case, `/images` hover icons |
| `chat-title-prefix.mdc` | `[sume-com] …` |
| `opus-via-claude-cli.mdc` | Pointer: Opus transport = shared SoT |

## Layer 3 — local Claude (tokenmaxxing)

`claude` on this desk is **[tokenmaxxing](https://github.com/anaclumos/tokenmaxxing)**:
a supervisor in front of Claude Code that pools subscription accounts and
swaps near 5h / weekly limits. `claude-human-stream` /
`agent-human-stream --backend claude` uses that `claude`.
Local Grok Build (`grok` CLI) uses `agent-human-stream --backend grok`.

SoT: **`docs/TOKENMAXXING.md`**. Short version:

- PATH: `~/.config/tokenmaxxing/bin` **before** the real CLI
- Pool (Chase machine): `chase@sume.com` + `dev@sume.com`, Max 20x
- `tokenmaxxing doctor` / `status` before blaming the wrapper
- Do not commit tokens or paste `accounts.json`
- `./install.sh` does **not** install tokenmaxxing; it only checks if present

## Transport (Cursor main agent)

```text
cat > /tmp/sume-opus-prompts/<job-slug>.md <<'EOF'
Work in English.
…
Required skill: read ~/.agents/skills/sume-gt-mq/SKILL.md
GRAPHITE hard lock (fresh clone, no gh pr create, dry-run 20s → gt merge → STOP)
HANDOFF: grok-land
EOF
cd /path/to/sume-com && claude-human-stream --name <job-slug> \
  "$(cat /tmp/sume-opus-prompts/<job-slug>.md)" --model fable
```

Shell tool: `block_until_ms: 0`, `description`: `Fable : <job-slug> (#N)`.
One smoke for `📎 session_id=`. Then stop waiting. Completion notification
is the monitor.

## Graphite (sume-com only)

- Fresh clone e.g. `/tmp/sume-com-<slug>` — **not** `git worktree` under the
  Cursor checkout (`#2383`).
- Never `gh pr create` on `sumelabs/sume` / `sume-com`.
- Dry-run **Required checks failed** → break, ≤2 rerun or CI unblock.
- Landed = `main` commit `(#N)`. Graphite FF may show `CLOSED` + `mergedAt: null`.

## What is not in this pack (on purpose)

- API keys, Code Storage PEMs, Clerk cookies, Railway tokens
- `~/.sume/ops/*` secrets — policy files may name the **path**, never the value
- Live `opus-live` logs / session registries
- Product code (`sume-com` stays its own repo)

## Host binaries the flow assumes

- `gh`, `gt` (Graphite CLI), `git`, `pnpm`
- Claude Code CLI via **tokenmaxxing** (`claude` supervisor on PATH) for
  `claude-human-stream` / `agent-human-stream --backend claude` —
  see `docs/TOKENMAXXING.md`
- Grok Build CLI (`grok` on PATH) for `agent-human-stream --backend grok`
- Cursor `Task` = Composer explore only
- Grok land / Grok author = `agent-human-stream --backend grok` (not Task)

`./install.sh` links `agent-human-stream` and `claude-human-stream` to
`~/.local/bin`.
