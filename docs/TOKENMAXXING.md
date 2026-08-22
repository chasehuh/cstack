# Local Claude — tokenmaxxing

This desk does **not** run bare `claude` against a single Anthropic login.
On Chase’s machine, **`claude` on PATH is the tokenmaxxing supervisor**.
`claude-human-stream` (Fable/Opus workers) goes through that same binary.

Upstream: [anaclumos/tokenmaxxing](https://github.com/anaclumos/tokenmaxxing)
(Bun global, `tokenmaxxing` on PATH). Subscription accounts only — not API keys.

If this file and `tokenmaxxing doctor` disagree, **doctor + live `status` win**.
Fix this doc after.

## Why it is here

Opus / Fable workers burn Claude Code Max quota (5h session + weekly).
Two Max 20x logins share the load. Near quota, tokenmaxxing swaps the
live credential at a turn boundary. The wrapper session is **not** restarted.

`claude-human-stream` must keep seeing **the supervisor** as `claude`,
not the raw npm CLI.

## PATH (hard)

This order is required (already in Chase’s `~/.zshrc` / launchd PATH):

```text
~/.config/tokenmaxxing/bin   ← supervisor named `claude`
~/.local/bin                 ← `claude-human-stream`, `tokenmaxxing`
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

- Launch Fable/Opus as today: `cd <repo> && claude-human-stream …`.
  Do not set `ANTHROPIC_API_KEY` to bypass the pool.
- If a worker dies with quota / 429 / “usage limit”: run `tokenmaxxing status`.
  If the active account is exhausted and the other is fresh, `tokenmaxxing switch`.
  If both parked tokens are expired, **stop** and tell Chase to `/login`
  via `tokenmaxxing auth` — do not invent a second Claude install.
- `status --force` pings every account (tiny haiku). Use only when Chase
  asked; it spends quota.
- Codex can have its own tokenmaxxing pool (`init --codex`). This desk’s
  Fable/Opus path is the **Claude** pool.

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
