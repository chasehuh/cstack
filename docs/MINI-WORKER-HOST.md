# Mac Mini worker host — `sume-bg-launch --host mini`

Locks: `chasehuh/cstack#10` (desk 2026-09-12), `chasehuh/cstack#14` (Mini
ego + dest evidence, 2026-09-13), Chase 2026-10-08 (the M5 is the default
Mini; the M4 only on Chase's word).

Workers (Opus through `agent-human-stream`) and ego-browser / dest shots run
on the **M5** Mac Mini. The main agent (Claude Code), Chase's chat and the
prompt files stay on the laptop.

## Hosts (single SoT: `sume-desk/hosts.env`)

| Name | ssh target | Use |
|---|---|---|
| M5 | `CSTACK_MINI_SSH_M5` (`chasehuh@chases-mac-mini-m5`) | default: `--host mini` |
| M4 | `CSTACK_MINI_SSH_M4` | only when Chase says M4: `--host m4` |

`sume-bg-launch` resolves `--host mini` in this order: `CSTACK_MINI_SSH` in
the environment, then `~/.cstack/mini-ssh.env`, then `hosts.env`
`CSTACK_MINI_SSH_M5`. If that value is the M4, the launcher prints a note
and uses the M5 instead. `install.sh` rewrites the `CSTACK_MINI_SSH` line of
`~/.cstack/mini-ssh.env` from `hosts.env` (the old file is kept as
`mini-ssh.env.bak.<stamp>`), so a laptop that sources that file follows the
repo.

## What runs where

| Piece | Laptop | M5 |
| --- | --- | --- |
| Main agent chat, prompts (`~/.cstack/state/prompts/`) | yes | — |
| `sume-bg-launch` (control plane) | yes | — |
| `agent-human-stream` worker | `--host local` (escape hatch) | `--host mini` (detached) |
| `~/.cstack/state/opus-live/`, `opus-sessions.jsonl` | **replica** (attach writes) | **writer** |
| `cstack-clone` trees | own | own (never synced back; code SoT = `origin/main`) |
| ego-browser / dest shots | yes | **allowed** |
| `gh` / Claude / Vercel / Railway logins | own | own (never passed over ssh) |

## One-time setup

**M5**

```bash
git clone git@github.com:chasehuh/cstack.git ~/.cstack/src && ~/.cstack/src/install.sh
# log in on the M5 itself: gh auth login, tokenmaxxing init
~/.cstack/src/sume-desk/tokenmaxxing/install-tokenmaxxing-desk.sh --mirror   # docs/TOKENMAXXING.md
# Remote Login on (System Settings → General → Sharing), key auth only
```

The worker inherits the M5's zsh login PATH (`sume-bg-remote` captures
`$SHELL -lic 'echo $PATH'` and puts `~/.config/tokenmaxxing/bin` and
`~/.local/bin` first).

**Laptop**: `~/.cstack/src/install.sh` (writes `~/.cstack/mini-ssh.env`),
then in `~/.zshrc`:

```bash
source ~/.cstack/mini-ssh.env
export CSTACK_WORKER_HOST=mini
```

`ssh $CSTACK_MINI_SSH true` must work in BatchMode (key only). The launcher
uses `ConnectTimeout=10` + `ServerAliveInterval=15`.

## Launch

```bash
P="$(sume-bg-launch --prompt-dir)/<job-slug>.md"     # ~/.cstack/state/prompts/
cat > "$P" <<'EOF'
…English prompt: issue URL, facts, locks, done criteria. No tokens.…
EOF
sume-bg-launch --host mini --backend claude --name <job-slug> \
  --prompt-file "$P" -- --model claude-opus-5-5 --effort high
```

Prompts live in `~/.cstack/state/prompts/`: a `/tmp/sume-*-prompts` dir
vanished mid-day on 2026-11-01 and the next launch failed with
`--prompt-file not found`. A missing prompt file now prints the durable dir.

What happens:

1. `ssh mini sume-bg-remote prep` — reachability probe + job dir. Unreachable
   → **exit 3, nothing runs locally** (fail closed). `--host local` is the
   deliberate escape hatch.
2. `scp` the prompt → `~/.cstack/state/remote-jobs/<job>/prompt.md` on the
   M5. Prompt text is **never** on the ssh command line.
3. `ssh mini sume-bg-remote start …` — starts `caffeinate -i sume-bg-launch
   --host local …` under `nohup` in its **own process group** and returns at
   once. It records `pid`, `pgid` and `pid_start` (the process start time).
4. `ssh mini sume-bg-remote attach` streams the M5's `worker.log` into the
   local replica `~/.cstack/state/opus-live/<job>.log` (+ `LATEST.log`) and
   appends `host: "mini"` rows to the local `opus-sessions.jsonl`
   (`start` / `session` / `end`).

Laptop sleep, lid close or an ssh drop end **only the attach** (exit 255,
registry row `attach-lost`). The job keeps running.

## Control plane

```bash
sume-bg-launch --host mini --jobs                 # job=… alive=yes|no state=… pid exit_code
sume-bg-launch --host mini --status <job>
sume-bg-launch --host mini --attach <job>         # re-attach; rewrites the replica from line 1
sume-bg-launch --host mini --kill <job>           # TERM → KILL the job's process group
```

`state`:

| state | meaning |
|---|---|
| `running` | no `exit_code`, the pid is alive **and** still has the start time recorded in `pid_start` (jobs from before `pid_start`: its command line names the job) |
| `exited` | `exit_code` written |
| `lost` | no `exit_code`, pid gone (killed hard, or the M5 rebooted) |
| `pid-reused` | the pid is alive but belongs to another process |

A bare pid is not liveness: after the 2026-11-01 reboot, pids came back on
other processes (`mini-plug-unlock` showed alive on macOS `mapssyncd`,
`google-ko-sitelinks` on another job's wrapper), and `--kill` would have
killed that process group. `--kill` now refuses a `pid-reused` job (exit 6)
and touches nothing. Never count the replica file as liveness.

## Resume / steer / fork — same host only

```bash
sume-bg-launch --host mini --backend claude --name <job-slug> \
  --resume <session_uuid> --prompt-file "$P"                    # steer
sume-bg-launch --host mini --backend claude --name <new-slug> \
  --resume <session_uuid> --fork-session --prompt-file "$P"     # fork
```

- The launcher looks the session up in the local registry replica. A Mini
  session with `--host local` (or the reverse) → **exit 4**, host printed.
- **Steer:** before it starts the new job, `sume-bg-remote start` stops every
  running M5 job that holds the session: the job whose `worker.log` printed
  `📎 session_id=<uuid>`, or a non-fork job that resumed `<uuid>`. Their
  `exit_code` becomes 143. On 2026-11-01 this did not happen: the old code
  matched `pgrep -af` output, and on macOS `-a` means "include ancestors",
  not "print arguments", so nothing ever matched and two wrappers ran on one
  session. `sume-bg-launch --host local` now reads `ps -axo pid=,command=`
  plus the registry's wrapper pid for the session.
- **Fork** leaves the parent running.
- **Slack:** a steer's report is a new top-level message. `--same-thread`
  (a poke, restart or effort change) crosses ssh as a flag, is recorded as
  `SAME_THREAD=1` in `job.env`, and makes the report reply in the job's
  thread.
- The original job's M5 cwd is reused (from the registry). Unknown session →
  `--cwd <remote dir>`.

## Unrelated activity never stops a job

Incidents: 2026-11-04 12:53 KST (7 jobs) and 2026-11-05 12:58 KST (11 jobs)
ended with rc=143 in the same second. Each time, one worker ran
`pkill -f cstack-gt-wait-merge` to stop its own merge-queue wait. The full
prompt sat in the argv of `claude -p` and of the tokenmaxxing supervisor, and
every prompt that names `cstack-gt-wait-merge` matched. macOS `pkill` never
signals its own ancestors, so the worker that ran it lived on. On 2026-11-05
07:51 KST a steer of session `9614dd9d` also stopped its fork
`lost-payments-audit`: the local steer matched every process whose argv held
the id, and a fork's argv holds `--resume <parent> --fork-session`.

Rules the launcher enforces:

- **No prompt text in argv.** `agent-human-stream` writes the composed prompt
  to `<live log>.prompt.md` (mode 600) and feeds it on stdin: `claude -p`
  with no prompt argument, `codex exec … -`. Argv holds flags, the session
  id and `--name` only.
- **A steer stops holders only.** Local steer matches `resume <uuid>` without
  `--fork-session` (or `codex exec resume … <uuid>`), plus the registry
  wrapper pid. A fork or a prompt that only names the id is left alone. The
  M5 path (`sume-bg-remote start`) already skipped forks.
- **`pkill` and `killall` spare other live jobs.** `install.sh` links
  `~/.local/bin/pkill` and `~/.local/bin/killall` to `cstack-kill-guard.sh`,
  which is ahead of `/usr/bin` on desk and worker PATHs. It runs the same
  match with `/usr/bin/pgrep`, then signals only processes outside the
  process group of every other live job in `remote-jobs/`. It prints what it
  left alone. The caller's own job (`SUME_BG_REMOTE_JOB`) is not protected.
  Workers stop what they started with `kill <pid>` or a pattern unique to
  their job (its `/tmp` path); a job is stopped with
  `sume-bg-launch --host mini --kill <job>`, never with a signal by hand.
- **`--kill` marks intent.** `kill_job` writes `<job>/stopped` before it
  signals; a steer stops the old job through `kill_job` too.
- **Unexpected death auto-resumes and alerts.** When the wrapper exits on a
  signal (rc 129–159) with no `stopped` marker, or with a usage-limit result
  ("hit your … limit"), and no other live job holds the session,
  `sume-bg-remote run` starts `<stamp>-<name>-resume-<sid8>` on the same
  session with an `AUTO-RESUME:` prompt (check what already happened, restart
  needed watchers). Delay: 5 s after a signal, 120 s after a usage limit (time
  for the tokenmaxxing swap). Cap: 2 resumes after signals, 3 after limits,
  counted by `AUTO_RESUME_DEPTH` in `job.env`. Every death also writes one
  line to `~/.cstack/state/job-alerts/`; the first dying job holds
  `job-alerts/.lock`, waits 20 s for the rest, and posts one
  `#coding-agents` message, "Mini 워커 비정상 종료 N건", that lists each job
  with its auto-resume job or its `--resume <uuid>`. The full list is kept in
  `job-alerts/log`.
- **Account switch.** Workers run `claude -p`, which the tokenmaxxing
  supervisor passes through unmanaged (no in-session respawn). A swap only
  changes the credentials for the next request and kills nothing. A usage
  limit ends `claude -p` with rc=1 (2026-11-05 11:08 KST: 4 jobs); the
  auto-resume above brings it back on the swapped account.

Deploy: the launcher runs straight from the `~/.cstack/src` checkout, and a
running bash reads its script as it goes. Update with `git pull` (git writes a
new file, so running jobs keep the old inode), never with an in-place edit of
a live script.

## Network on the M5

The M5 shares 2.4 GHz Wi-Fi (~43 Mbps). Workers keep media probes to 4 at a
time and use byte ranges: on 2026-11-01 one scan with 84 parallel ffprobes
starved every other job's `git fetch` and a `gh stack submit` preflight
(see `sume-gt-mq` playbook E).

## Dest / ego evidence (hard lock, Chase 2026-09-13)

Ego verification on the M5 is allowed. When dest/prod browser verification is
in scope, stay after main land until dest `/api/build` reports the land
commit or a descendant. Verify under **sumelabs** with compose model
**Auto**, then post **one** `gh issue comment` with 2–4 screenshots + host,
workspace, Auto, SHA, pass/fail, URL. Final report: `SHOTS: <comment URL>`;
no URL ⇒ no `DEST: pass`. Prod needs Chase's explicit authorization.
Recipe: [references/dest-verify-issue-shots.md](../sume-desk/skills/sume-main-agent-orchestration/references/dest-verify-issue-shots.md).

## Nested launches are refused (sume#7839)

A worker that reads launcher flags quoted in its prompt can decide it is the
main agent and start another worker; that child dies with the parent's turn
or duplicates the job. Guards:

- `agent-human-stream` exports `SUME_WORKER_SESSION`; `sume-bg-remote run`
  exports `SUME_BG_REMOTE_JOB`. `sume-bg-launch` (launch only) and
  `agent-human-stream` exit **5** inside such a session. Control-plane
  actions still work. Override on purpose only: `SUME_BG_ALLOW_NESTED=1`.
- Every wrapper-launched prompt gets the `[sume worker session]` preamble;
  `~/.codex/AGENTS.md` carries "Sume worker mode (always on)".
- Main-agent prompts: task only, no launcher flags in the body.

## Secrets

The M5 keeps its own logins. Nothing is forwarded. The launcher refuses a
prompt file that looks like a credential (`ghp_…`, `sk-ant-…`, `xox…`,
`AKIA…`, private keys).

## Files on the M5

```
~/.cstack/state/remote-jobs/<job>/
  prompt.md     scp'd prompt
  job.env       backend / name / cwd / resume / fork
  pid pgid      detached process (own process group)
  pid_start     start time of pid (ps lstart), the liveness check
  worker.log    wrapper stdout+stderr (what attach streams)
  exit_code     written when the worker exits (143 when stopped)
  stopped       written by --kill / steer before the signal (intent)
~/.cstack/state/job-alerts/          unexpected-death lines, batch lock, log
~/.cstack/state/opus-live/…          M5 live logs (writer)
~/.cstack/state/opus-sessions.jsonl   M5 registry (writer)
```

One writer per file; do not sync these.

## Cron (no laptop)

`sume-cron-job --name <slug>` from the M5 crontab calls `sume-bg-remote
start` locally. See [MINI-CRON.md](MINI-CRON.md).

## Tests

`sume-desk/skills/sume-main-agent-orchestration/bin/sume-bg-launch.test.sh`
runs offline (fake `ssh` / `scp` against a temp HOME standing in for the
M5, fake wrapper); `install.sh` runs it. Covers local regression, host
resolution (M5 default, stale M4 → M5, `--host m4`), fail-closed, the
prompt secret guard, launch → replica + registry, same-host resume, detached
survival, `--status` / `--jobs` / `--attach` / `--kill`, pid reuse (not
alive, `--kill` refuses), the M5 steer stopping the older job (fork does
not), the local steer (forks and id mentions left alone), the prompt dir,
the nested-launch guard, the `pkill` / `killall` guard (only dry-run
`killall` and unique markers, never a broad live kill), and auto-resume +
alert on an unexpected death (capped; `--kill` does neither).
`agent-human-stream --self-test` checks that the claude and codex prompt
reaches stdin and never argv.
