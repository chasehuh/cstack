# Mac Mini worker host — `sume-bg-launch --host mini`

One page for Chase. Locks: `chasehuh/cstack#10` (desk 2026-09-12).

Only the **subagent handoff** runs on the Mini. Cursor main chat, canvas
board, Slack burst, Composer `Task` / explore, and **all ego-browser /
dest shots stay on the laptop**.

## What runs where

| Piece | Laptop | Mini |
| --- | --- | --- |
| Cursor main chat / board / Slack | yes | never |
| `sume-bg-launch` (control plane) | yes | — |
| `agent-human-stream` worker (Claude / Grok / Codex) | `--host local` | `--host mini` (detached) |
| `~/.cstack/state/opus-live/`, `opus-sessions.jsonl` | **replica** (attach writes) | **writer** |
| `cstack-clone` trees | own | own (never synced back; code SoT = `origin/main`) |
| ego-browser / CDP / `cua_repl` / dest shots | yes | **forbidden (v1)** |
| `gh` / `gt` / Claude / Grok / Codex / Vercel / Railway logins | own | own (never passed over ssh) |

## One-time setup

**Mini**

```bash
# same pack as the laptop; the launcher + sume-bg-remote come from this checkout
git clone git@github.com:chasehuh/cstack.git ~/.cstack/src && ~/.cstack/src/install.sh
# log in once, on the Mini itself: gh auth login, gt auth, tokenmaxxing init (claude/codex), grok
# Remote Login on (System Settings → General → Sharing) — key auth, no password
```

The worker inherits the Mini's **zsh login PATH** (`sume-bg-remote` captures
`$SHELL -lic 'echo $PATH'` and puts `~/.config/tokenmaxxing/bin` and
`~/.local/bin` first). Put `brew`, `grok`, node on the login PATH there.

**Laptop** (`~/.zshrc`)

```bash
export CSTACK_MINI_SSH=chase@<mini-tailscale-name>   # Tailscale name, not only .local
export CSTACK_WORKER_HOST=mini                        # default host once the Mini is configured
# optional: export CSTACK_MINI_CWD=/Users/chase       # where new Mini jobs start (default $HOME there)
```

`ssh $CSTACK_MINI_SSH true` must work in BatchMode (key only). The launcher
uses `ConnectTimeout=10` + `ServerAliveInterval=15`.

## Launch (Cursor Shell recipe, unchanged title)

```bash
# Shell tool: description = "Fable : <job-slug> (#N)"   ← stays the LOCAL Shell title
#             block_until_ms = 0
cat > /tmp/sume-opus-prompts/<job-slug>.md <<'EOF'
…English prompt: issue URL + locks only. No tokens.…
EOF
sume-bg-launch --host mini --backend claude --name <job-slug> \
  --prompt-file /tmp/sume-opus-prompts/<job-slug>.md -- --model fable --effort high
```

What happens:

1. `ssh mini sume-bg-remote prep` — reachability probe + job dir. Unreachable
   → **exit 3, nothing runs locally** (fail closed). Escape hatch on purpose:
   `--host local`.
2. `scp` the prompt file → `~/.cstack/state/remote-jobs/<job>/prompt.md` on
   the Mini. Prompt text is **never** on the ssh command line.
3. `ssh mini sume-bg-remote start …` — starts
   `caffeinate -i sume-bg-launch --host local …` under `nohup` in its **own
   process group** and returns at once. sshd is not the parent.
   `caffeinate -i` = the chosen idle-sleep guard: the Mini cannot idle-sleep
   while any worker is alive; it releases when the worker exits.
4. `ssh mini sume-bg-remote attach` streams the Mini's `worker.log` into the
   local **replica** `~/.cstack/state/opus-live/<job>.log` (+ `LATEST.log`)
   and appends `host: "mini"` rows to the local `opus-sessions.jsonl`
   (`start` / `session` on `📎 session_id=` / `end` with `exit_code`).
   The Cursor terminal shows the same lines, so the one-shot smoke
   (`📎 session_id=`) and the completion notification (`—— final ——`) work
   exactly as for local jobs.

Laptop sleep, lid close, or ssh drop end **only the attach** (exit 255,
registry row `attach-lost`). The Mini job keeps running.

## Control plane

```bash
sume-bg-launch --host mini --jobs                 # every Mini job: alive=yes|no pid exit_code
sume-bg-launch --host mini --status <job>         # liveness truth = Mini pid, not the replica file
sume-bg-launch --host mini --attach <job>         # re-attach; rewrites the replica from line 1
sume-bg-launch --host mini --kill <job>           # TERM → KILL the job's process group on the Mini
```

`<job>` = `<utc-stamp>-<name>` printed as `job:` in the launcher banner and
stored in the registry rows. The replica file can lag or stop when the
laptop sleeps — **never** count a replica file as liveness; use `--status`.

## Resume / steer — same host only

```bash
sume-bg-launch --host mini --backend claude --name <job-slug> \
  --resume <session_uuid> --prompt-file /tmp/sume-opus-prompts/<follow-up>.md
```

- The launcher looks the `session_id` up in the local registry replica.
  Mini session + `--host local` (or a local session + `--host mini`) →
  **exit 4, prints the host**. Rows without a `host` field are local.
- On the Mini, `sume-bg-launch --host local --resume` runs as usual, so
  older wrappers holding that uuid are killed **on the Mini**, not here.
- The Mini cwd of the original job is reused automatically (from the
  registry). Unknown session → pass `--cwd <remote dir>`.
- `--fork-session` passes through unchanged.

## dest / ego rule (hard, v1)

The Mini has no ego-lite, no CDP, no Chase Chrome. If a Job needs dest/prod
`SHOTS`:

- launch it with `--host local`, **or**
- let the Mini land the code, then run a **local** follow-up Shell (same
  issue, same title) that does ego + the issue comment.

The launcher prints a note when the prompt mentions `SHOTS:` / `ego-browser`.
Never claim `DEST: pass` from a Mini job without shots.

## Secrets

- The Mini keeps its own logins. Nothing is forwarded (no agent forwarding,
  no env, no tokens on argv).
- Prompt files carry issue URLs and locks only. The launcher refuses a
  prompt file that looks like it contains a credential (`ghp_…`,
  `sk-ant-…`, `xox…`, `AKIA…`, private keys).

## Files on the Mini

```
~/.cstack/state/remote-jobs/<job>/
  prompt.md     scp'd prompt
  job.env       backend / name / cwd / resume
  pid pgid      detached process (own process group)
  worker.log    wrapper stdout+stderr (what attach streams)
  exit_code     written when the worker exits
~/.cstack/state/opus-live/…        Mini's own live logs (writer)
~/.cstack/state/opus-sessions.jsonl Mini's own registry (writer)
```

Do **not** iCloud / Syncthing / SSHFS any of these. One writer per file.

## Non-goals (v1)

Cursor IDE on the Mini, custom RPC / sockets, sharing dirty worktrees, auto
dest verify on the Mini, changing sume-com Graphite / MQ policy.

## Tests

`sume-desk/skills/sume-main-agent-orchestration/bin/sume-bg-launch.test.sh`
runs offline (fake `ssh` / `scp` against a temp HOME standing in for the
Mini; fake wrapper). `install.sh` runs it. Covers: local regression, host
env / validation, fail-closed unreachable, prompt secret guard, mini launch
→ replica + registry, same-host resume, detached survival after attach
death, `--status` / `--jobs` / `--attach` / `--kill`.
