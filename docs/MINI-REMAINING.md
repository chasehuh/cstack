# Mac Mini worker host — remaining bootstrap (agent runbook)

**Audience:** an agent sitting **on the Mac Mini** (or Chase at the Mini).
Work in **English**. Do not copy tokens from the laptop. Do not move the
Cursor workspace root. Do not run dest / ego-browser from the Mini (v1).

**Parent:** [cstack#10](https://github.com/chasehuh/cstack/issues/10) (CLOSED —
launcher landed as `8772611`). **Tracking leftover:**
[cstack#12](https://github.com/chasehuh/cstack/issues/12).

**Laptop SoT page:** `docs/MINI-WORKER-HOST.md` (this repo).
**Desk check (2026-09-13 11:26 KST):** laptop Tailscale is up; Mini is **not**
on the tailnet; `CSTACK_WORKER_HOST` is still unset on purpose.

---

## What is already done (do not redo)

### Laptop (Chase MacBook Pro) — DONE except the last env flip

| Item | State |
| --- | --- |
| Tailscale.app + CLI | Installed. Logged in `chasehuh@github`. Backend `Running`. |
| This machine on tailnet | `macbookpro` · `100.106.70.0` · MagicDNS `macbookpro.tail7af029.ts.net` |
| SSH pubkey to authorize on Mini | `~/.ssh/id_ed25519.pub` |
| Fingerprint | `SHA256:x27sa1A9cPtTWvCOle729t7GgdP4Jbp6ikAozzz8A2Y` |
| Public key (paste into Mini `authorized_keys`) | `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICRNLcpYnA3MQRV1qhTZjakxDIRu69Ia5I5thsVxVkj4 huhchaewon@heochaewon-ui-MacBookPro.local` |
| `sume-bg-launch` / `sume-bg-remote` | Linked from cstack `8772611` (`~/.local/bin/sume-bg-launch`) |
| `~/.cstack/mini-ssh.env.example` | Present. Real `mini-ssh.env` **not** created yet |
| `~/.zshrc` `CSTACK_MINI_SSH` / `CSTACK_WORKER_HOST` | **Commented out** until BatchMode SSH works |
| Offline launcher tests | Already in `sume-bg-launch.test.sh` (fake ssh). Not a live Mini test |

### Not done anywhere

- Mini Tailscale join (no peers besides `macbookpro` as of 2026-09-13 11:26 KST)
- Mini Remote Login + laptop pubkey
- Mini `~/.cstack/src` clone + `install.sh`
- Mini `gh` / `gt` / Claude / Codex / Grok logins
- Laptop `ssh -o BatchMode=yes $CSTACK_MINI_SSH true`
- Laptop uncomment `CSTACK_WORKER_HOST=mini`
- Live `--host mini` smoke job

---

## Roles (do not invert)

| Who | Does |
| --- | --- |
| **Mini agent / Chase at Mini** | Everything in § Mini checklist. Print `whoami` + Tailscale MagicDNS name back to Chase chat. |
| **Laptop main agent** | After that name exists: BatchMode SSH, write `~/.cstack/mini-ssh.env`, uncomment zshrc, one `--host mini` smoke. dest/ego stays `--host local`. |
| **Cursor chat** | Stays on the laptop forever. Never install Cursor-as-main on the Mini for this flow. |

---

## Mini checklist (do in this order)

You are on the Mini. Use a login zsh (`zsh -lic`). Fail closed: if a step
needs a human (Apple ID, Tailscale menu, `gh auth login` browser), **stop
and say which step is blocked**. Do not invent accounts. Do not copy
`ghp_`, `sk-ant-`, `xox`, Claude/Codex cookies from the laptop.

### 0) Facts to print first

```bash
whoami
hostname
uname -m
echo "HOME=$HOME SHELL=$SHELL"
sw_vers
echo "PATH=$PATH"
```

If `whoami` is not a normal user (you are root), switch to the desktop
user before continuing.

### 1) Tailscale — same account as the laptop

Laptop account: **`chasehuh@github`** (Chase Huh). Tailnet MagicDNS
suffix seen from laptop: **`tail7af029.ts.net`**.

```bash
# app
ls /Applications/Tailscale.app || echo "NEED: install Tailscale.app (brew install --cask tailscale-app)"
command -v tailscale || echo "NEED: Tailscale CLI on PATH"
```

If the app is missing, install it (needs sudo / GUI as appropriate):

```bash
brew install --cask tailscale-app
# open the app → Log in → GitHub as chasehuh (same tailnet as macbookpro)
open -a Tailscale
```

Human must click Log in if the agent cannot. After login:

```bash
tailscale status
tailscale ip -4
# Expect: this Mini as a peer, AND macbookpro / 100.106.70.0 visible.
# MagicDNS name looks like: <mini-host>.tail7af029.ts.net
```

**Done when:** `tailscale status` shows **this Mini + `macbookpro`** both
online. Write down:

- Mini Tailscale hostname (first column)
- Mini MagicDNS (`….tail7af029.ts.net`)
- Mini tailnet IPv4
- Mini macOS username (`whoami`)

Those four strings are what the laptop needs for `CSTACK_MINI_SSH`.

### 2) Remote Login (SSH) — key only

System Settings → General → Sharing → **Remote Login** = On.
Allow the desktop user. Prefer “only these users”.

```bash
sudo systemsetup -getremotelogin   # if permitted
# or:
systemctl 2>/dev/null; launchctl print system/com.openssh.sshd 2>/dev/null | head
```

Install the **laptop** pubkey (do not generate a new Mini-only trust as
the only path — the laptop must BatchMode in):

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
# append exactly this line if missing:
PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICRNLcpYnA3MQRV1qhTZjakxDIRu69Ia5I5thsVxVkj4 huhchaewon@heochaewon-ui-MacBookPro.local'
grep -Fqx "$PUB" ~/.ssh/authorized_keys 2>/dev/null || echo "$PUB" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Password SSH is not the acceptance path. Do not enable agent forwarding.

### 3) Homebrew / Xcode CLT / git / gh / Node (if missing)

```bash
command -v brew git gh node zsh
# If brew missing: https://brew.sh install (interactive).
# Then:
brew install git gh
```

`gt` (Graphite) must exist for sume-com author jobs that land on the Mini:

```bash
command -v gt || echo "NEED: Graphite CLI (https://graphite.dev) + gt auth"
```

### 4) Clone cstack and install the desk pack

```bash
mkdir -p ~/.cstack
if [ ! -d ~/.cstack/src/.git ]; then
  git clone git@github.com:chasehuh/cstack.git ~/.cstack/src
fi
cd ~/.cstack/src && git fetch origin && git checkout main && git pull --ff-only
# expected tip at last laptop land: 8772611 (ops Mini host). Newer main is OK.
./install.sh
# If this Mini also has a sume-com checkout you will author from:
#   ./install.sh --sume-com /path/to/sume-com
```

`install.sh` must put these on `~/.local/bin` and login PATH:

- `sume-bg-launch`
- `sume-bg-remote`  ← laptop `scp`/`ssh` target; **required**
- `agent-human-stream`
- `claude-human-stream`
- `cstack-clone` `cstack-clone-rm` `cstack-mirror-sync` `cstack-gt-wait-merge`

```bash
zsh -lic 'command -v sume-bg-remote sume-bg-launch agent-human-stream cstack-clone'
# all four must print paths under $HOME/.local/bin
```

Add to `~/.zshrc` if missing:

```bash
export PATH="$HOME/.local/bin:$HOME/.config/tokenmaxxing/bin:$PATH"
```

`sume-bg-remote` captures **login** PATH (`$SHELL -lic`). Interactive-only
PATH edits will look “installed” in a GUI terminal and fail over ssh.

### 5) Logins — on the Mini only (never scp tokens)

Interactive. Stop and ask Chase if a browser is required.

| Tool | Why | Command (typical) |
| --- | --- | --- |
| GitHub `gh` | issues, `gh pr`, CI | `gh auth login` (same `sumelabs` / `chasehuh` access as laptop) |
| SSH to GitHub | `cstack-clone`, `gt submit` | `gh auth setup-git` and/or Mini’s own `~/.ssh` key in GitHub |
| Graphite `gt` | sume-com PRs | `gt auth` / `gt config` |
| Claude Code / tokenmaxxing | Opus / Fable | tokenmaxxing init **on Mini** |
| Codex | Astra | Codex login **on Mini** |
| Grok Build | only if Chase names Grok | `grok` CLI login **on Mini** |
| Vercel / Railway | only if a Mini job needs them | login **on Mini**; do not forward laptop env |

Prove:

```bash
gh auth status
git ls-remote git@github.com:sumelabs/sume-com.git HEAD | head
command -v gt && gt --version
command -v claude; command -v codex; command -v grok
```

### 6) Sleep / power (worker lifetime)

Laptop lid must not kill Mini jobs. On the Mini:

- Energy: prevent idle sleep while plugged in (Chase preference).
- `sume-bg-remote start` already wraps the worker in `caffeinate -i`.
- Do not enable iCloud / Syncthing / SSHFS on `~/.cstack/state`.

### 7) Local self-test on the Mini (no laptop yet)

```bash
# offline unit tests (fake ssh) — should already pass after install.sh
~/.agents/skills/sume-main-agent-orchestration/bin/sume-bg-launch.test.sh

# local wrapper smoke (this is --host local ON the Mini, not the laptop)
mkdir -p /tmp/sume-opus-prompts
cat > /tmp/sume-opus-prompts/mini-self-smoke.md <<'EOF'
Work in English. Reply with one line: MINI_SMOKE_OK and hostname. No code.
EOF
# Only if Claude/Codex is logged in. Otherwise skip and report BLOCKED: auth.
# sume-bg-launch --host local --backend claude --name mini-self-smoke \
#   --prompt-file /tmp/sume-opus-prompts/mini-self-smoke.md -- --model fable --effort low
```

Do **not** run ego-browser or dest shots here.

### 8) Report back to Chase (required strings)

Post in the laptop Cursor chat (or the GitHub issue comment) **exactly**:

```text
MINI_USER=<whoami>
MINI_TAILSCALE_HOST=<first column of tailscale status for this machine>
MINI_MAGICDNS=<name>.tail7af029.ts.net
MINI_IP4=<100.x.x.x>
REMOTE_LOGIN=on
PUBKEY_INSTALLED=yes
CSTACK_SRC=<git rev-parse --short HEAD of ~/.cstack/src>
SUME_BG_REMOTE=<path from command -v>
GH_AUTH=<ok|blocked>
GT_AUTH=<ok|blocked>
CLAUDE_AUTH=<ok|blocked>
CODEX_AUTH=<ok|blocked>
GROK_AUTH=<ok|skipped>
```

Until those exist, the laptop **must not** set `CSTACK_WORKER_HOST=mini`.

---

## Laptop leftover (main agent / Chase — after §8)

Do this **only** after Mini §8.

```bash
# 1) BatchMode (no password prompt)
export CSTACK_MINI_SSH='<MINI_USER>@<MINI_TAILSCALE_HOST>'
# prefer MagicDNS host, not *.local
ssh -o BatchMode=yes -o ConnectTimeout=10 "$CSTACK_MINI_SSH" true
ssh -o BatchMode=yes "$CSTACK_MINI_SSH" 'command -v sume-bg-remote'

# 2) persist
cp ~/.cstack/mini-ssh.env.example ~/.cstack/mini-ssh.env
# edit the two export lines to the real user@host
# uncomment the same two lines in ~/.zshrc

# 3) live smoke from laptop (Cursor Shell description = "Astra : mini-host-smoke")
# sume-bg-launch --host mini --backend …   expect session_id in replica log
# sume-bg-launch --host mini --status <job>
```

Fail closed: unreachable Mini → launcher **exit 3**, no silent local run.

dest / ego / Composer explore: keep `--host local`.

---

## Non-goals

- Cursor IDE as the Sume main agent on the Mini
- Sharing dirty `sume-com` worktrees / SSHFS
- Copying API keys or `SUME_PROD_TEST_API_KEY` to the Mini unless a later
  Chase lock says so
- Changing sume-com Graphite / MQ policy
- Treating offline `sume-bg-launch.test.sh` as a live Mini acceptance test

## Acceptance

- [ ] Mini on the same tailnet as `macbookpro`
- [ ] Laptop `ssh -o BatchMode=yes $CSTACK_MINI_SSH true` (exit 0)
- [ ] Mini `sume-bg-remote` on login PATH
- [ ] Mini `gh` + git SSH to `sumelabs/sume-com` work
- [ ] One laptop-launched `--host mini` job prints `📎 session_id=` locally
- [ ] Kill laptop attach (or sleep lid): Mini job still alive (`--status`)
- [ ] `CSTACK_WORKER_HOST=mini` enabled on laptop only after the above
