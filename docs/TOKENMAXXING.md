# Local Claude + Codex — tokenmaxxing

This desk does **not** run bare `claude` or bare `codex` against a single
login. On Chase’s machine, **`claude` and `codex` on PATH are tokenmaxxing
supervisors** (`~/.config/tokenmaxxing/bin/{claude,codex}`).
`claude-human-stream` / `agent-human-stream --backend claude` (Fable/Opus
workers) go through the `claude` shim; `agent-human-stream --backend codex`
goes through the `codex` shim. Grok Build is a different CLI (`grok`) with
no tokenmaxxing pool and uses `agent-human-stream --backend grok`.

The **Claude pool and the Codex pool are separate** (different accounts,
different quotas, different `tokenmaxxing … --codex` commands). See
§ "Codex pool" below.

Repo (SoT for this desk): **[chasehuh/tokenmaxxing](https://github.com/chasehuh/tokenmaxxing)**,
run as a **source checkout** at `~/.local/src/tokenmaxxing` (the shim in
`~/.config/tokenmaxxing/bin` execs bun on that checkout's `src/main.ts`).
It is a fork of [anaclumos/tokenmaxxing](https://github.com/anaclumos/tokenmaxxing)
that carries the Grok Build pool and the managed-headless auto-swap
(`docs/auto-swap-long-sessions.md` in that repo). Upstream has since moved
to a per-session-store architecture (1.50.0: `switch`/`ls` removed, no grok
supervisor); **never `bun add -g tokenmaxxing`** on this desk — the npm
package is upstream and would shadow the fork with different semantics.
Subscription accounts only — not API keys.

If this file and `tokenmaxxing doctor` disagree, **doctor + live `status` win**.
Fix this doc after.

## Why it is here

Opus / Fable workers burn Claude Code Max quota (5h session + weekly).
Two Max 20x logins share the load. Near quota, tokenmaxxing swaps the
live credential at a turn boundary. The wrapper session is **not** restarted.

`agent-human-stream --backend claude` must keep seeing **the supervisor**
as `claude`, not the raw npm CLI.

## PATH (hard)

This order is required (already in Chase’s `~/.zshrc` / launchd PATH):

```text
~/.config/tokenmaxxing/bin   ← supervisor named `claude`
~/.local/bin                 ← `agent-human-stream`, `claude-human-stream`, `tokenmaxxing`
real @anthropic-ai/claude-code
```

Checks:

```bash
which claude
# expect: /Users/<you>/.config/tokenmaxxing/bin/claude

tokenmaxxing doctor
# must say: tokenmaxxing/bin is ahead of the real claude on PATH
```

`./install.sh` does **not** install tokenmaxxing. It only assumes `claude`
is already the supervisor. If doctor is red, fix tokenmaxxing before
launching workers.

## This desk’s pool (Chase machine)

| Account | Typical role | Plan |
|---|---|---|
| `chase@sume.com` | often **active** | Claude Max 20x |
| `dev@sume.com` | often **parked** | Claude Max 20x |

Switch thresholds (current): **5h 95%**, **weekly 98%**.
Confirm with `tokenmaxxing status` — do not hard-code bars into issues.

Parked access tokens **expire** even when live cred is fine. `doctor` may
say “parked identity unverifiable (access token expired)” and still be
`all good` if the **active** live credential matches. Reauth parked
accounts before a switch, or the next swap will fail.

```bash
tokenmaxxing status          # 5h / week / fable bars
tokenmaxxing ls              # ● active / ○ parked
tokenmaxxing switch          # best account, or `switch chase@sume.com`
tokenmaxxing auth <email>    # isolated /login — one account at a time
```

`auth` opens a dedicated Claude TUI. Sign in as **that exact email**.
Two `auth` windows at once overwrite the same onboard folder — **serial only**.

Do **not** paste access tokens, cookies, or `accounts.json` into git,
issues, or chat.

## What agents should do

- Launch Fable/Opus as today: `cd <repo> && claude-human-stream …`
  (or `agent-human-stream --backend claude …`).
- Grok Build headless: `cd <repo> && agent-human-stream --backend grok …`.
  Do not set `ANTHROPIC_API_KEY` to bypass the pool.
- Headless workers (`claude -p`, `codex exec`, `grok -p`) are **managed jobs**
  since the fork's managed-headless change: the shim gates the seat before
  launch and, on a quota refusal, swaps and resumes the **same** session by
  itself. A worker that still exits **75** is *parked* (every account at its
  limit): its record under `~/.config/tokenmaxxing/jobs/` names the session
  to resume once a reset passes. Only if the shim did **not** recover: run
  `tokenmaxxing status`; if the active account is exhausted and another is
  fresh, `tokenmaxxing switch`. If both parked tokens are expired, **stop**
  and tell Chase to `/login` via `tokenmaxxing auth` — do not invent a second
  Claude install.
- `status --force` pings every account (tiny haiku). Use only when Chase
  asked; it spends quota.
- Codex has its **own** tokenmaxxing pool (§ "Codex pool"). This desk’s
  Fable/Opus path is the **Claude** pool; `--backend codex` is the Codex pool.
  A Claude quota swap never helps a Codex worker and vice versa.

## Codex pool (this desk)

Codex (`codex` CLI, ChatGPT Pro subscription) is pooled by the same
tokenmaxxing install, but as a **separate** account list. Check with
`tokenmaxxing status` (the `codex (N accounts)` block at the bottom) or
`tokenmaxxing ls --codex`.

| Account | Role | Plan |
|---|---|---|
| `dev@dooilabs.com` | **active** Codex account on this desk (confirmed by Chase) | ChatGPT Pro |
| `chase@sumelabs.com` | parked, **needs re-auth** (dead refresh token) | ChatGPT Pro |

Live percentages are not recorded here — read `tokenmaxxing status`.

```bash
which codex                          # expect ~/.config/tokenmaxxing/bin/codex
tokenmaxxing status                  # Claude bars, then the codex block
tokenmaxxing add --codex             # isolated `codex login` for one more account
tokenmaxxing switch --codex <email>  # make that account active
tokenmaxxing switch --codex dev@dooilabs.com
```

Differences from the Claude pool:

- A running `codex exec` keeps the credential it started with (codex
  cannot hot-adopt). The fork's `codex` shim covers this: it picks the seat
  **before** every `codex exec` launch, and when the server refuses a turn
  on a quota limit it swaps and relaunches `codex exec resume <thread_id> ""`
  on the fresh account — no manual relaunch. Exit 75 = parked (see above).
- Codex has no `--effort` flag. The wrapper turns `--effort` into
  `-c model_reasoning_effort="…"` (`none|minimal|low|medium|high|xhigh`;
  `mid` → `medium`, `max`/`maximum` → `xhigh`). Omitted → `high`.
- The resume id is Codex’s **thread_id** (printed as `📎 session_id=…
  backend=codex`). Resume = `codex exec resume <id>`; no `--fork-session`.
- Do not re-auth `chase@sumelabs.com` unless Chase asks; do not add
  Codex API keys to bypass the pool.

### Agent stream recipe (Codex)

```bash
cd /path/to/repo && agent-human-stream --backend codex --name <job-slug> "…" --model gpt-5.5
# or the launcher (prompt file, steer-safe):
cd /path/to/repo && sume-bg-launch --backend codex --name <job-slug> \
  --prompt-file /tmp/sume-codex-prompts/<job-slug>.md -- --effort high
# resume / steer
agent-human-stream --backend codex --resume <thread_id> "Follow-up …"
```

Under the hood the wrapper runs
`codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox "<prompt>"`
with stdin closed (`codex exec` would otherwise wait for piped stdin in a
background Shell), and humanizes the JSONL (`thread.started`, `item.*`,
`turn.completed`) into the same `🤖 / 🔧 / 📎 / —— final ——` lines as
Claude and Grok. Same live log dir and registry (`backend=codex`).

Codex stdout goes to a regular `.codex.jsonl` file beside the live log,
not a pipe. The formatter follows that file in chunks until Codex exits,
then drains the remaining bytes; the wrapper waits and preserves Codex's
exit status. This avoids Rust `println!` panics from EAGAIN (`os error 35`,
wrapper rc=101) when a fat `item.completed.aggregated_output` fills the
pipe. Lines over 4 MiB are skipped with only the session id scraped, so a
large tool result does not require JSON parsing or unbounded buffering.

If `~/.config/tokenmaxxing/bin/codex` exists but PATH resolves `codex`
elsewhere, the wrapper exits 127 (PATH order bug — run `tokenmaxxing
doctor`). `TOKENMAXXING_REQUIRE_SUPERVISOR=1` hard-fails on any machine
without the shim; `=0` bypasses on purpose.

## Install / repair (human)

```bash
git clone git@github.com:chasehuh/tokenmaxxing.git ~/.local/src/tokenmaxxing
cd ~/.local/src/tokenmaxxing && bun install
bun run src/main.ts init   # first account + supervisor + hooks; the shim runs THIS checkout
# restart shell
tokenmaxxing add           # second Max login, isolated
tokenmaxxing doctor
tokenmaxxing status
```

Update = `git -C ~/.local/src/tokenmaxxing pull` (the shim runs the working
tree; nothing to reinstall). Do **not** `bun add -g tokenmaxxing`: that is
upstream's npm package, not this fork.

LaunchAgent `com.tokenmaxxing.check` (≈180s) runs `tokenmaxxing check`
and swaps when over threshold. Idle + last exit 0 is healthy.

Codex pool: `tokenmaxxing init --codex` (or `add --codex` when the Claude
pool already exists), then `tokenmaxxing switch --codex <email>`.

## Not in git

- `~/.config/tokenmaxxing/accounts.json` and keychain items
- Live usage percentages (they change every hour)
- `tokenmaxxing.log` / `check.stderr.log`
