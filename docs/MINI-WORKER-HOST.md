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

Before step 3 starts anything, `sume-bg-remote start` checks Fable quota for a
Fable model and asks the [governor](#governor-load-admission-quota) for
admission. A busy Mini answers `queued: job … waits for Mini capacity`; the
launcher exits 0 without attaching. Launch flags for this:

- `--priority critical|high|normal|low` (default from the job name);
- `--now`: skip the admission queue;
- `--fable-downgrade` (or `SUME_BG_FABLE_DOWNGRADE=1`): when Fable quota is
  low, start on Opus 5.5 at the same effort instead of only warning.

## Control plane

```bash
sume-bg-launch --host mini --jobs                 # job=… alive=yes|no state=… pid exit_code
sume-bg-launch --host mini --status <job>
sume-bg-launch --host mini --attach <job>         # re-attach; rewrites the replica from line 1
sume-bg-launch --host mini --kill <job>           # TERM → KILL the job's process group
sume-bg-launch --host mini --status               # governor: load, running / paused / queued jobs, quota
sume-bg-launch --host mini --quota                # tokenmaxxing pool: Fable / 5 h / weekly per account, resets
sume-bg-launch --host mini --governor pause|resume|start|pin|unpin <job>
sume-bg-launch --host mini --governor mode observe|enforce|off
```

`state`:

| state | meaning |
|---|---|
| `running` | no `exit_code`, the pid is alive **and** still has the start time recorded in `pid_start` (jobs from before `pid_start`: its command line names the job) |
| `exited` | `exit_code` written |
| `lost` | no `exit_code`, pid gone (killed hard, or the M5 rebooted) |
| `pid-reused` | the pid is alive but belongs to another process |
| `paused` | alive, stopped by the governor (`governor-paused` marker); `alive=yes` |
| `queued` | admitted to the governor queue, not started yet (`queued` marker, no pid) |

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
  ("hit your … limit", "reached your Fable limit"), and no other live job
  holds the session,
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
- **Fable limit → swap, then Opus.** Until 2026-11-14 the Fable message
  ("You've reached your Fable limit. Switch to another model…") did not
  match the limit pattern, so a Fable worker that ran out just died: on
  2026-11-12 04:45–04:52 UTC four Fable jobs ended with rc=1, no resume, no
  alert, while tokenmaxxing logged `stopfailure.decision reason=all-depleted
  swapped=false`. Now, for a Fable worker (`--model fable…` /
  `claude-fable-*`) that dies on a usage limit, `auto_resume` asks
  `cstack-quota.py fable-plan` (reads `~/.config/tokenmaxxing`, see
  [TOKENMAXXING.md](TOKENMAXXING.md#fable-quota-on-workers)):
  - another account has Fable headroom → `tokenmaxxing switch <account>`,
    then resume on Fable (alert: "Fable 계정 전환 후 재개"). The worker's own
    session came over SSH and cannot read the login keychain, so its direct
    switch fails; it then asks the governor daemon (`sume-bg-governor swap
    <account>`, a GUI-session launchd agent that can) and waits up to 90 s
    (`SUME_BG_SWAP_WAIT_S`). If the plan still says swap after that, the
    resume falls back to Opus as below;
  - no account has Fable headroom but one has weekly headroom → resume the
    **same session** on `claude-opus-5-5` at the **same effort** (Fable max →
    Opus max). The `AUTO-RESUME` prompt gains a `MODEL FALLBACK:` paragraph,
    `job.env` records `MODEL_FALLBACK=fable→claude-opus-5-5 …`, and the alert
    line says "Fable 소진 → Opus 5.5 <effort>로 재개";
  - every account is out of weekly quota → no resume loop; the alert says
    "모든 계정 주간 한도 소진, 재개 안 함" with the `--resume <uuid>` to run
    after the reset.
  Non-Fable workers keep the plain 120 s resume.

Deploy: the launcher runs straight from the `~/.cstack/src` checkout, and a
running bash reads its script as it goes. Update with `git pull` (git writes a
new file, so running jobs keep the old inode), never with an in-place edit of
a live script.

## Governor (load, admission, quota)

`sume-bg-governor` is a launchd agent on the M5 (`com.cstack.sume-bg-governor`,
`RunAtLoad` + `KeepAlive`, so it survives a reboot or crash) that keeps many
workers running without overloading the Mini or burning the Fable pool. One
instance: the daemon holds `governor/daemon.lock`; a second one exits.

Every 30 s it samples 1/5-min load, `kern.memorystatus_level` (memory free
%), swap used and an sshd probe (TCP banner time on 127.0.0.1:22).

| setting (env on the agent) | default (18 cores) | meaning |
|---|---|---|
| `GOV_HIGH_LOAD5` | 22 (1.22 × cores) | high water: 5-min load ≥ this **and** 1-min ≥ 90 % of it |
| `GOV_LOW_LOAD5` | 12 (0.67 × cores) | low water: 5-min ≤ this and 1-min ≤ 1.2 × it, nothing else high |
| `GOV_LOW_HOLD_MIN` | 5 | low must hold this long before a resume |
| `GOV_COOLDOWN_S` | 180 | one pause / resume / start per cooldown |
| `GOV_START_LOAD5` | 17 (midpoint) | a queued job starts only below this |
| `GOV_SSH_SLOW_MS` | 3000 | sshd slower than this (or down) counts as high |
| `GOV_MEM_FREE_LOW` / `GOV_SWAP_HIGH_MB` | 10 % / 4096 | memory / swap pressure counts as high |
| `GOV_HEAVY_CPU` | 15 | only a job using ≥ this % CPU is worth pausing |
| `GOV_MAX_PAUSE_MIN` | 30 | longer pauses become a clean stop + resume |
| `GOV_FABLE_STAGGER_PCT` / `GOV_FABLE_HEAVY_MAX` | 25 / 2 | Fable stagger (below) |
| `GOV_NOTIFY_MIN` | 10 | Slack batch interval |

**Pause.** Above high water it pauses one job per cooldown: the lowest
priority first, newest first within a priority. A pause is `SIGSTOP` of every
process in the job's tree (descendants of the job pid plus its process
group), recorded in `governor/state.json` and a `governor-paused` marker.
After `GOV_LOW_HOLD_MIN` below low water it resumes one job per cooldown
(`SIGCONT`), highest priority first, oldest pause first. Between the marks
nothing changes (hysteresis). A pause longer than `GOV_MAX_PAUSE_MIN` becomes
a clean stop: `SIGCONT`, then `sume-bg-remote kill` (the `stopped` marker, so
no death alert and no auto-resume), and when the load is low again a new job
`<stamp>-<name>-resume-<sid8>` resumes the **same session** with the same
backend flags and a `PAUSED BY GOVERNOR, continue:` prompt.

**Never paused** (the `NOTE` column of `--status` says why):

- priority `critical` (release, hotfix, deploy, rollback, prod in the name);
- a pinned job (`--governor pin <job>`), or a job dir with a `critical`
  marker / `CRITICAL=1` in `job.env`;
- a process in the tree running `git push|commit|rebase|merge|cherry-pick|am`,
  `git tag v…`, `gh stack submit|merge|sync|push`, `gh pr merge|create|ready`,
  `gh release`, `gh workflow run`, `gh run watch`, `cstack-gt-wait-merge`,
  `cstack-gate`, `cstack-slack-post`, `vercel … deploy|--prod|promote`,
  `railway up|deploy|redeploy`, `npm|pnpm|bun publish`, a `/release-*`
  script or `sume-bg-remote start|kill` (read-only `git merge-base`,
  `git tag -l` and `git status` do not count);
- a job whose last 12 shell calls in `worker.log` include
  `cstack-gt-wait-merge`, `gh stack submit|merge`, `gh pr merge`, a release
  `gh workflow run`, `git push` or `git tag v…` (its merge-queue wait may be
  between polls).

If the Mini is high and nothing is pausable, it logs that once per 30 min and
waits.

**Account swaps.** The daemon also serves `sume-bg-governor swap <email>`
requests (`governor/swap/*.req` → `*.done`, checked every second, in every
mode): it runs `tokenmaxxing switch <email>` from the GUI session, where the
login keychain is readable, and logs `SWAP <email> rc=…`. Auto-resume uses
it after a Fable limit (above).

**Priority.** `--priority critical|high|normal|low` on `sume-bg-launch`
(`PRIORITY=` in `job.env`). Default from the name:

| priority | name contains |
|---|---|
| critical | `release`, `hotfix`, `deploy`, `rollback`, `prod` |
| high | `rca`, `sentry`, `incident`, `outage`, `sev`, `errors`, `alert(s)`, `money`, `security`, `signin` |
| low | `research`, `study`, `audit`, `ideas`, `explore`, `dogfood`, `survey`, `eval`, `loop`, `iter`, `sweep`, `polish`, `review`, `probe`, `bench`, `-100…`, `r<N>` |
| normal | everything else (features, fixes) |

**Admission queue.** `sume-bg-remote start` asks `governor admit`. When the
Mini is high, the job is queued: `job.env` and `extra.args` are written,
a `queued` marker is set, no process starts, and the launcher prints
`queued: job … waits for Mini capacity` and exits 0 without attaching. The
governor starts queued jobs (highest priority, then oldest) when nothing is
paused and the 5-min load is below `GOV_START_LOAD5`. Never queued: `--now`,
priority `critical`, a steer (`--resume` without `--fork-session`), and every
auto-resume / governor relaunch. Start one by hand with
`sume-bg-launch --host mini --governor start <job>`; drop one with `--kill`.
Attach after it starts with `--attach <job>`.

**Quota.** At launch a Fable worker (`--model fable…`) reads the pool
(`cstack-quota.py launch-check`): when no account has Fable headroom, or the
pool's projected headroom (pool % minus 3 % per running Fable worker) is below
10 %, the launch log prints a `quota:` warning. `--fable-downgrade` (or
`SUME_BG_FABLE_DOWNGRADE=1`) then starts it on `claude-opus-5-5` at the same
effort, records `MODEL_DOWNGRADE` in `job.env` and notifies "⬇️ …"; without
the flag it only warns ("launching on Fable anyway"). Nothing changes model
silently. **Fable stagger:** a heavy Fable job (effort `max` / `xhigh`) is
queued while `GOV_FABLE_HEAVY_MAX` heavy Fable workers already run and the
projected pool headroom is below `GOV_FABLE_STAGGER_PCT`. A Fable worker that
still hits its limit takes the swap → Opus path in
[auto-resume](#unrelated-activity-never-stops-a-job).

**Modes.** `observe` (the install default) logs `WOULD PAUSE|RESUME|CONVERT|
RELAUNCH|START|QUEUE …` and touches nothing; `enforce` acts; `off` does
nothing and admits everything. `sume-bg-launch --host mini --governor mode
enforce`. The mode lives in `governor/state.json` (`GOV_MODE` only seeds it).

**Notes.** Every pause, resume, clean stop, relaunch, queue, queued start and
launch downgrade writes a line to `governor/log` and one Korean line to
`governor/notify/`. The daemon posts them as one `#coding-agents` message
"Mini 거버너" at most every `GOV_NOTIFY_MIN` minutes (job `mini-governor`;
copy in `governor/notify.log`). In `observe` only launch downgrades produce
notes; the `WOULD …` lines stay in the log.

**Death alerts.** A paused job is alive (`state=paused`, `alive=yes`), so
`launcher-watch` never reports it. A governor stop goes through `--kill`, so
it is not an abnormal death either. A bare `kill -TERM` by hand still is
(17:46 KST 2026-11-14: `nav-shrink-hero` reported as a death); stop jobs with
`--kill`.

**Manual override.**

```bash
sume-bg-launch --host mini --governor pause <job> [--force]   # critical jobs refuse (exit 3) without --force
sume-bg-launch --host mini --governor resume <job>
sume-bg-launch --host mini --governor pin <job>               # never paused; unpin to undo
sume-bg-launch --host mini --governor start <job>             # start a queued job now
sume-bg-launch --host mini --governor mode observe|enforce|off
```

`<job>` may be a unique part of the id. On the M5 itself the same commands
are `sume-bg-governor <cmd>` and `sume-bg-remote overview|quota`.

**Install / deploy.** `sume-bg-governor install` (on the M5, in the console
user's session) writes `~/Library/LaunchAgents/com.cstack.sume-bg-governor.plist`
(`/usr/bin/python3 <checkout>/…/sume-bg-governor.py daemon`,
`AbandonProcessGroup` so jobs it starts outlive a daemon restart) and
bootstraps it in `gui/<uid>`. Jobs it starts still use the credentials file
store (`sume-bg-remote run` sets `CLAUDE_SECURESTORAGE_CONFIG_DIR`). The daemon exits when its script changes on disk, and launchd
starts the new version, so a `git pull` of `~/.cstack/src` is the deploy.
`sume-bg-governor uninstall` resumes every paused job, then removes the
agent. If the daemon dies, paused jobs stay paused until it comes back
(within 30 s, `KeepAlive`); state survives in `state.json`.

Python 3.9 stdlib only (`/usr/bin/python3` on the M5).

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
  extra.args    backend flags, one per line (queued start, relaunch, model fallback)
  queued        admitted to the governor queue, not started
  governor-paused   paused by the governor (SIGSTOP), JSON record
  governor-stopped  long pause turned into a clean stop; relaunch pending
~/.cstack/state/governor/            state.json (+ state.lock), log, notify/, notify.log,
                                     swap/, daemon.lock, daemon.pid, daemon.out
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

`sume-bg-governor.test.sh` (offline, fake wrapper / tokenmaxxing / Slack,
`GOV_FAKE_LOAD` and friends instead of the real machine) covers the quota
reader, `fable-plan`, the launch warning and `--fable-downgrade`, the Fable
limit death (swap, swap through the daemon when the keychain is unreadable,
Opus fallback at the same effort, all-exhausted), observe
mode, pause order and cooldown, critical phases (release name, merge-queue
wait), hysteresis, pin / manual pause / resume, the long-pause clean stop and
relaunch, the admission queue (manual start, `--now`, release bypass), Fable
stagger, pid reuse, `--status`, and the daemon (single instance, restart on
a code change). Run it with `~/.local/bin` off `PATH` inside a worker (the
kill guard protects the caller's own group).
