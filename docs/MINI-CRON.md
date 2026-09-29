# Cron one named job on the Mac Mini — `sume-cron-job`

Start a worker job (default: Claude Opus 5.5, effort medium) on a schedule,
with no laptop attached. Same detached job as
`sume-bg-launch --host mini` ([MINI-WORKER-HOST.md](MINI-WORKER-HOST.md)):
`sume-cron-job` stages the prompt and calls `sume-bg-remote start` **locally**
on the Mini. There is no second agent runner, no ssh-to-self, no attach.

## One job = one slug

| Piece | Where |
| --- | --- |
| crontab | user **`chasehuh`** on the Mini (`crontab -e`), never root |
| prompt | `~/.cstack/cron/<slug>.md` (English; issue URL + locks; no tokens) |
| fire log | `~/.cstack/state/cron/<slug>.log` (`started` / `skip` / `error`, one line per fire) |
| job | `~/.cstack/state/remote-jobs/<utc-stamp>-<slug>/` (same files as a `--host mini` job) |

## The crontab line

```cron
# m  h  dom mon dow  command
30 18 *   *   1-5  /Users/chasehuh/.local/bin/sume-cron-job --name <slug> >/dev/null 2>&1
```

- Times are the Mini's local time zone.
- Only the slug is on the line. No prompt text, no tokens, no env secrets.
  The worker uses the Mini's own logins (tokenmaxxing `claude`, `gh`, `gt`).
- Other backend / flags: `… --name <slug> --backend grok -- --effort high`.
  With no flags after `--` and `--backend claude` (default) it passes
  `--model claude-opus-5-5 --effort medium`.
- `--cwd <dir>` sets where the job starts (default `$HOME`).
- cron runs `/bin/sh`; `sume-cron-job` sets `SHELL` to the user's login shell
  so the worker gets the same zsh login PATH as an ssh launch.

## Guards

- **One live job per slug.** A fire while `<stamp>-<slug>` is still alive
  logs `skip` and exits 0. A per-slug lock (`remote-jobs/.cron-<slug>.lock`)
  covers two fires in the same second. Two crontab lines for one slug are
  still a mistake — keep one.
- **Never from a worker.** Inside `SUME_WORKER_SESSION` /
  `AGENT_HUMAN_STREAM_PID` / `SUME_BG_REMOTE_JOB` it exits **5**
  (sume#7839). Workers do not install crontab lines either.
- **No laptop.** Nothing here needs `CSTACK_MINI_SSH` or an attach.
- **No secrets.** Same credential grep as `sume-bg-launch`; a prompt that
  looks like it holds a token is refused (exit 2).
- A job that should resume a session is not a cron job. Cron always starts a
  fresh session.

## Is it alive?

```bash
tail ~/.cstack/state/cron/<slug>.log            # did the fire start or skip?
sume-bg-remote jobs | grep -- '-<slug> '         # on the Mini
sume-bg-launch --host mini --jobs                # from the laptop
sume-bg-launch --host mini --attach <job>        # watch from the laptop
sume-bg-launch --host mini --kill <job>          # stop it
```

Liveness is the Mini pid (`alive=yes`), not a log file.

## Before you add a line

1. The Mini must be awake at fire time. cron does not wake a sleeping Mac;
   `caffeinate -i` only holds it awake while a worker runs.
2. Run it once by hand: `sume-cron-job --name <slug>`, then `sume-bg-remote jobs`.
3. Add exactly one line. Remove it (`crontab -e`) when the job is done.

## Tests

`sume-desk/skills/sume-main-agent-orchestration/bin/sume-cron-job.test.sh`
(offline; real `sume-bg-remote`, fake launcher). `install.sh` runs it.
