# Local Claude + Codex — tokenmaxxing

This desk does **not** run bare `claude` or bare `codex` against a single
login. On Chase’s machines, **`claude` and `codex` on PATH are tokenmaxxing
supervisors** (`~/.config/tokenmaxxing/bin/{claude,codex}`).
`claude-human-stream` / `agent-human-stream --backend claude` (Fable/Opus
workers) go through the `claude` shim; `agent-human-stream --backend codex`
goes through the `codex` shim. Grok Build is a different CLI (`grok`) with
no tokenmaxxing pool and uses `agent-human-stream --backend grok`.

The **Claude pool and the Codex pool are separate** (different accounts,
different quotas, different `tokenmaxxing … --codex` commands). See
§ "Codex pool" below.

Upstream: [anaclumos/tokenmaxxing](https://github.com/anaclumos/tokenmaxxing).
This desk runs **upstream 1.10.0 pinned, plus the cstack desk patch**
(`sume-desk/tokenmaxxing/`, § "Desk build"). Subscription accounts only —
not API keys.

If this file and `tokenmaxxing doctor` disagree, **doctor + live `status` win**.
Fix this doc after.

## Why it is here

Opus / Fable workers burn Claude Code Max quota (5h session + weekly).
Several Max 20x logins share the load (`tokenmaxxing ls` lists them). Near
quota, tokenmaxxing swaps the live credential at a turn boundary. The
wrapper session is **not** restarted.

`agent-human-stream --backend claude` must keep seeing **the supervisor**
as `claude`, not the raw npm CLI.

## PATH (hard)

This order is required (already in Chase’s `~/.zshrc` / launchd PATH):

```text
~/.config/tokenmaxxing/bin   ← supervisor named `claude`, desk `tokenmaxxing` wrapper
~/.local/bin                 ← `agent-human-stream`, `claude-human-stream`
real @anthropic-ai/claude-code
```

Checks:

```bash
which claude
# expect: /Users/<you>/.config/tokenmaxxing/bin/claude

tokenmaxxing doctor
# must say: tokenmaxxing/bin is ahead of the real claude on PATH
# first dim line: cstack desk patch <sha> on tokenmaxxing 1.10.0 (...)
```

`./install.sh` does **not** install tokenmaxxing or log anyone in. When the
global package is 1.10.0 it re-applies the desk patch
(`install-tokenmaxxing-desk.sh --if-pinned`), then runs `doctor`. If doctor
is red, fix tokenmaxxing before launching workers.

## Desk build (pinned 1.10.0 + cstack patch)

Source: `sume-desk/tokenmaxxing/` in this repo.

| File | What |
|---|---|
| `desk-1.10.0.patch` | diff against upstream `v1.10.0` `src/` |
| `desk.test.ts` | hermetic `bun test` suite: fake keychain dir, fake token/roles server, no real secrets, never calls `platform.claude.com` |
| `install-tokenmaxxing-desk.sh` | fetches the sha256-pinned 1.10.0 tarball, applies the patch, runs the suite on the staged tree, swaps `src/` into `~/.bun/install/global/node_modules/tokenmaxxing`, writes the desk wrappers |

```bash
~/.cstack/src/sume-desk/tokenmaxxing/install-tokenmaxxing-desk.sh --check   # current?
~/.cstack/src/sume-desk/tokenmaxxing/install-tokenmaxxing-desk.sh           # laptop
~/.cstack/src/sume-desk/tokenmaxxing/install-tokenmaxxing-desk.sh --mirror  # Mac Mini (SSH worker host)
```

The patch is upstream's own 1.18.x fixes, backported, plus what this desk
still needed (cstack#25):

- **Backported from upstream** (anaclumos/tokenmaxxing `a115b1d`, `4d72528`,
  `b4ea33b`, 1.18.0–1.18.1): the token endpoint's nested
  `{"error":{"type":…}}` body is parsed (1.10 printed `unparsable error body
  withheld`); a non-`invalid_grant` 4xx is `refresh_rejected`, not a crash;
  the bare `switch` and the check/hook decide loops skip a rejected
  candidate and try the next one; a dead-cleared blob (empty token) is dead
  without a request.
- **Desk additions**: a parked access token with more than 10 minutes left
  is owner-checked (roles endpoint) and installed **without** a refresh;
  refresh only runs when the parked token is expiring. `invalid_grant` still
  sets needs-reauth; `refresh_rejected` does not, it is stamped on the account
  (`lastRefreshRejected`: time, HTTP status, error code — never the body). A
  live credential that is dead-cleared, gets `invalid_grant`, or gets a 401
  from the roles endpoint is **not** parked back over its account's slot; one
  whose refresh is rejected (or that has no `expiresAt`) is parked only if its
  access token still verifies, and a newer parked grant is never overwritten
  by an older live one. A live item without `expiresAt` no longer makes every swap throw.
  `doctor` reports what a switch will actually do (below). Live file mirror
  for SSH (below).
- **Claude Code refresh fallback** (the idea of upstream `243ef37`, #238):
  when tokenmaxxing's own refresh of an expiring parked token is rejected,
  the switch installs that parked blob in a throwaway isolated store, runs
  the real `claude -p /usage --no-session-persistence --safe-mode` there so
  Claude Code refreshes it under its own lock, and parks the rotated pair
  before using it. If Claude Code dead-clears it, the account is marked
  needs-reauth; if nothing changed, the account is skipped as
  `refresh_rejected`.

**Why not upstream latest.** Upstream ≥1.37.0 dropped the shared live
credential, the Claude `switch`, and tokenmaxxing's own refresh: every
account gets its own credential store and each session is pinned to one at
launch. On macOS those stores are keychain items, which SSH workers on the
Mini cannot read, and upstream rebuilds the pool from fresh logins of every
account. Moving there means a file-store story for SSH plus a re-login of the
whole pool. That is a separate decision for Chase, not a drop-in upgrade.

Do **not** `bun update -g` or `bun add -g tokenmaxxing` without `@1.10.0`:
that installs upstream latest over the desk build. `doctor` stops printing
the desk-patch line when that happens; re-pin with
`bun add -g tokenmaxxing@1.10.0` and re-run the installer.

## This desk’s pool

`tokenmaxxing ls` lists the Claude accounts (● active / ○ parked).
Thresholds live in `~/.config/tokenmaxxing/config.json`; read them from the
first line of `tokenmaxxing status`. Do not hard-code bars or percentages
into issues or this doc.

```bash
tokenmaxxing status          # 5h / week / fable bars (first line: thresholds)
tokenmaxxing ls              # ● active / ○ parked
tokenmaxxing switch          # best account, or `switch <email>`
tokenmaxxing doctor          # what a switch will actually do, per account
tokenmaxxing sync-file       # macOS live file mirror: reconcile now
tokenmaxxing auth <email>    # isolated /login — one account at a time
```

`auth` opens a dedicated Claude TUI. Sign in as **that exact email**.
Two `auth` windows at once overwrite the same onboard folder — **serial only**.

Do **not** paste access tokens, refresh tokens, cookies, OAuth response
bodies, `.credentials.json`, or `accounts.json` into git, issues, PRs, logs,
or chat.

### Reading `doctor` per parked account

`identity matches` alone never meant "switch will work". The desk build
prints one of:

| Line | Meaning for `switch` |
|---|---|
| `✓ <email>: parked access token verifies (switchable without refresh, expires in …)` | installs that token as-is; the token endpoint is not called |
| `- <email>: parked access expired, refresh not verified` | a switch must refresh first; it may still work |
| `✗ <email>: parked access expired and last refresh_rejected (HTTP 400 …)` | not switchable; `tokenmaxxing auth <email>` |
| `⚠ <email>: last refresh_rejected …` (access still valid) | switchable until the access token expires; re-auth before then |
| `✗ <email> needs re-auth` | `invalid_grant` or a parked token owned by another account |

The summary line `switchable now without a refresh: …` is the list a bare
`switch` can land on even if the token endpoint rejects every refresh.

## Failure mode: switch stuck on an exhausted account (cstack#25)

What it looked like on 1.10.0 unpatched: the active account sat at 100% of
its 5-hour window; `tokenmaxxing switch` (bare and with every selector)
printed `token refresh failed (HTTP 400): (unparsable error body withheld)`
and left the active account in place; the check timer logged the same line
every minute; sampling other accounts failed with `cannot verify the live
credential's owner (roles check failed (HTTP 401))` because the live access
token was already dead. Causes, all fixed by the desk build:

1. `switch` always refreshed the parked credential, even with hours of
   access left, and any 400 that was not literally `invalid_grant` aborted
   the whole command instead of trying the next account. On 2026-10-01 the
   parked grants were minutes old (fresh `tokenmaxxing auth`) when their
   refresh was rejected, so the rejection may be about tokenmaxxing's own
   refresh request rather than the grants; the desk build logs the parsed
   error code and message (`swap.refresh_rejected … code=… detail=…`) and
   falls back to Claude Code's refresh.
2. The token endpoint's rejection body is nested
   (`{"error":{"type":"invalid_request_error",…}}`); 1.10 could not parse it,
   so `doctor` and the log could not say why.
3. A live keychain item with no `expiresAt` failed schema parsing, so every
   swap threw before choosing a target.
4. Two copies of one OAuth grant (keychain item + `~/.claude/.credentials.json`)
   with a one-way keychain → file copy every minute. A refresh on either side
   rotates the refresh token and revokes the old access token, so the other
   copy dies; the old copy was then parked back by the next swap. That is how
   every parked refresh token on the Mini ended up rejected.

If it happens again on the desk build:

1. `tokenmaxxing doctor` from the console (or Screen Sharing) session. Find
   the `switchable now without a refresh` line.
2. `tokenmaxxing switch` (or `switch <email>` from that list). It prints
   `switched to <email> (unexpired access token installed, refresh skipped;
   expires in …)` and skips rejected accounts with one `skipping …` line each.
3. That only buys time until the installed access token expires. Every
   account that doctor shows with `refresh_rejected` needs
   `tokenmaxxing auth <email>` (serial, as that exact email) before its
   access token runs out.
4. If no account is switchable, stop and tell Chase which accounts need
   `tokenmaxxing auth`. Do not copy keychain blobs by hand: a hand-installed
   blob is one more copy of a grant and lasts only until its `expiresAt`.

## SSH workers and the credentials file (macOS)

Mac Mini workers run over SSH (`sume-bg-launch --host mini`) or from cron.
Those sessions **cannot read the login keychain** (`security` exit 36,
`errSecInteractionNotAllowed`). There Claude Code uses
`~/.claude/.credentials.json` (mode 0600; the `claude` shim and
`sume-bg-remote` set `CLAUDE_SECURESTORAGE_CONFIG_DIR=$HOME/.claude`). A
Screen Sharing / Terminal `/login` or `tokenmaxxing auth` writes the
**keychain** only, never that file, so a GUI login alone does not log SSH
workers in.

The desk build treats the live credential as one store with two copies
(**live file mirror**, on when `~/.config/tokenmaxxing/live-file-mirror`
exists; the installer's `--mirror` creates it):

- Every live write (switch, refresh) writes the `claudeAiOauth` key to both
  the keychain item and the file, and leaves the other keys in each copy
  (for example MCP OAuth entries) alone.
- Reads pick the copy that changed since the last sync (a 16-hex hash of
  the last synced access token in `live-mirror.json`, never the token), else
  the usable one, else the later `expiresAt`. A refresh done by an SSH
  worker therefore wins over the stale keychain copy and is what gets parked.
- The check timer, `tokenmaxxing status`, and `tokenmaxxing sync-file`
  copy the current side to the other one under Claude Code's refresh lock.
  The timer fires every 60 s, so a refresh on either side reaches the
  other copy within about a minute.
- The old `~/.local/bin/tokenmaxxing-sync-claude-file.sh` (one-way keychain
  → file after every `tokenmaxxing` run) is retired by the installer. Do not
  bring it back: it overwrote a worker-refreshed file with the stale
  keychain copy.

From an SSH session:

- `tokenmaxxing switch` refuses with `the login keychain is not readable from
  this session` — parked credentials live in the keychain. The GUI check
  timer performs the switch (it runs in the console session); workers pick
  up the new file on their next request. A hook in an SSH worker logs
  `decide.keychain_unavailable` instead of an error.
- `tokenmaxxing sync-file` prints whether the file holds a usable
  credential; `tokenmaxxing doctor` checks the file (present, mode 0600,
  not dead-cleared) and skips the parked checks.
- `claude auth status` from SSH reads the file: `loggedIn: true` means the
  file is good.

Residual risk: a Claude process in the console session (keychain copy) and
an SSH worker (file copy) can still refresh the same grant within the same
minute; one of them then loses its refresh token. Keep pooled work on the
Mini in SSH/cron workers, not in console `claude` sessions.

## What agents should do

- Launch Fable/Opus as today: `cd <repo> && claude-human-stream …`
  (or `agent-human-stream --backend claude …`).
- Grok Build headless: `cd <repo> && agent-human-stream --backend grok …`.
  Do not set `ANTHROPIC_API_KEY` to bypass the pool.
- If a worker dies with quota / 429 / “usage limit”: run `tokenmaxxing status`,
  then `tokenmaxxing doctor`. If the active account is exhausted and doctor
  lists a switchable account, `tokenmaxxing switch` (console session; over
  SSH wait one check-timer minute and re-run `status`). If nothing is
  switchable, **stop** and tell Chase which accounts need
  `tokenmaxxing auth` — do not invent a second Claude install.
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

- A Codex swap applies on the **next `codex` start**. A running
  `codex exec` keeps the credential it started with; it is not swapped
  mid-turn the way Claude is. Finish or stop the worker, then relaunch
  (`agent-human-stream --backend codex --resume <thread_id> "…"`).
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
bun add -g tokenmaxxing@1.10.0       # pinned; never unpinned `bun add -g tokenmaxxing`
tokenmaxxing init                    # first account + supervisor + hooks
# restart shell
tokenmaxxing add                     # more Max logins, isolated
~/.cstack/src/sume-desk/tokenmaxxing/install-tokenmaxxing-desk.sh [--mirror]
tokenmaxxing doctor
tokenmaxxing status
```

`init` rewrites `~/.config/tokenmaxxing/bin/tokenmaxxing`; re-run the desk
installer after it.

LaunchAgent `com.tokenmaxxing.check` fires every 60 s and runs
`tokenmaxxing check --if-due`: the live file mirror syncs on every firing,
the swap evaluation only when due (1–3 min apart). Idle + last exit 0 is
healthy; `check.stderr.log` holds the failures.

Codex pool: `tokenmaxxing init --codex` (or `add --codex` when the Claude
pool already exists), then `tokenmaxxing switch --codex <email>`.

## Not in git

- `~/.config/tokenmaxxing/accounts.json`, keychain items, `~/.claude/.credentials.json`
- `~/.config/tokenmaxxing/live-mirror.json` (hash stamp only, still machine state)
- Live usage percentages (they change every hour)
- `tokenmaxxing.log` / `check.stderr.log`
