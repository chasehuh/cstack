# Local Claude — tokenmaxxing

This desk does **not** run bare `claude` against a single Anthropic login.
On Chase’s machine, **`claude` on PATH is the tokenmaxxing supervisor**.
`claude-human-stream` / `agent-human-stream --backend claude` (Fable/Opus
workers) go through that same binary. **`grok` on PATH is also a tokenmaxxing
shim** (`__supervise-grok`, installed by `tokenmaxxing init --grok`); Grok
Build workers (`agent-human-stream --backend grok`) run through it — see
§ Grok Build pool below.

Upstream: [anaclumos/tokenmaxxing](https://github.com/anaclumos/tokenmaxxing)
(Bun global, `tokenmaxxing` on PATH). Subscription accounts only — not API keys.

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
- If a worker dies with quota / 429 / “usage limit”: run `tokenmaxxing status`.
  If the active account is exhausted and the other is fresh, `tokenmaxxing switch`.
  If both parked tokens are expired, **stop** and tell Chase to `/login`
  via `tokenmaxxing auth` — do not invent a second Claude install.
- `status --force` pings every account (tiny haiku). Use only when Chase
  asked; it spends quota.
- Codex can have its own tokenmaxxing pool (`init --codex`). This desk’s
  Fable/Opus path is the **Claude** pool.

## Grok Build pool (SuperGrok seats)

`~/.config/tokenmaxxing/bin/grok` → `bun run ~/.local/src/tokenmaxxing/src/main.ts
__supervise-grok` → the binary named by `config.json` **`grokBin`** (a pinned
`~/.grok/downloads/grok-<ver>-macos-aarch64`). That pin is the **only** Grok
that desk workers run. `~/.grok/bin/grok` (what `grok --version` from that
path reports) and `~/.grok/version.json` can be newer; they are not what
runs. `install.sh` prints both; `tokenmaxxing config get grokBin` is the
check. Bumping the pin = editing `grokBin` (then re-run the desk probes in
sumelabs/sume#5706, the wire shapes were captured on 1.0.11).

Facts that shape `agent-human-stream --backend grok` (2026-09-02):

- The supervisor ignores SIGINT/SIGHUP and has **no SIGTERM handler**: killing
  it orphans the raw grok child with its stdout still on the pipe. The desk
  steer (`sume-bg-launch --resume`) therefore kills the **process group and
  the raw child** (`agent-holders kill <uuid>`), never the supervisor alone.
- The child pid lives in `~/.config/tokenmaxxing/grok-live/<supervisorId>`
  (`{accountId, pid, startedAt}`); stale files self-heal by pid + start time.
- Three SuperGrok seats rotate on the **weekly** bar; a swap hot-reloads
  `auth.json` on the next API call (no restart). The `StopFailure rate_limit`
  respawn path relaunches `grok --resume <sid>` **without** the headless
  flags (`-p`, `--output-format`) — latent (never fired on this desk); the
  wrapper aborts if a non-NDJSON line shows up. Upstream fix belongs in
  tokenmaxxing, not cstack.
- Hooks: `~/.grok/hooks/tokenmaxxing-grok.json` (`Stop`, `StopFailure
  rate_limit`) is the pool's; `~/.grok/hooks/sume-desk.json` (installed by
  `install.sh`) is the desk registry hook. Both are silent, exit 0.

```bash
tokenmaxxing status          # grok seats: weekly bars
tokenmaxxing switch --grok   # running sessions hot-reload on their next call
tokenmaxxing config get grokBin
```

## Install / repair (human)

```bash
bun add -g tokenmaxxing
tokenmaxxing init          # first account + supervisor + hooks
# restart shell
tokenmaxxing add           # second Max login, isolated
tokenmaxxing doctor
tokenmaxxing status
```

LaunchAgent `com.tokenmaxxing.check` (≈180s) runs `tokenmaxxing check`
and swaps when over threshold. Idle + last exit 0 is healthy.

## Not in git

- `~/.config/tokenmaxxing/accounts.json` and keychain items
- Live usage percentages (they change every hour)
- `tokenmaxxing.log` / `check.stderr.log`
