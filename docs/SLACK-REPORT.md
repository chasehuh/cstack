# Worker completion report → Slack #coding-agents

Every worker that `sume-bg-launch` / `agent-human-stream` starts posts **one**
Korean report to `#coding-agents` (`C0A9L7AU5HS`) when it finishes. This is
the default. Main agents do not add it to job prompts; the wrapper appends it.

**SoT for the words the worker sees:**
[`sume-desk/skills/sume-main-agent-orchestration/references/slack-report-tail.md`](../sume-desk/skills/sume-main-agent-orchestration/references/slack-report-tail.md).
The format, the skip rules, and the `SLACK_TEXT:` fallback live there only.
Edit that file, then run `./install.sh`. This page explains when it applies
and how the post is made.

## The format (as the desk already posts it)

- **Thread (Chase lock 2026-10-13, 2026-11-03):** every launch, including a
  `--resume` steer with a new instruction, reports as a **new top-level
  message**. Parent text is ``<short what> — `<Lane> : <slug> (#N)` ``
  (Lane = Opus, Fable, Sonnet, Haiku, Codex or Grok, from the worker's
  model; `cstack-slack-post` fills it in) and the
  report is that message. Replies in an old thread confused Chase. A reply
  happens only when the launch says so (`--same-thread`, for a poke, restart
  or effort change on the same ask), or for a second note right after the
  parent you just posted.
- **DM is extra, never a replacement (Chase 2026-11-03):** a job asked to DM
  its result sends the DM **and** posts the report to `#coding-agents`.
  "DM only" / "not in the channel" does not cancel the channel report, and
  nothing in the wrapper turns the report off because of a DM request.
  Amounts and other financial figures are fine in the channel.
- **Report:** Korean, 600 characters or fewer, mrkdwn. A bold title line with
  issue/PR/SHA links, then `•` lines (cause or what was done, check with
  numbers, what remains), then one evidence link. Clips and images go on
  the same message.
- **Final block:** the usual report (what was done, PR / SHA / issue /
  `SHOTS:` links, `LANDED: yes|no`), then `SLACK: <permalink>`. If the
  worker cannot post, it writes `SLACK_TEXT:` with the exact Korean text
  and `SLACK: not posted — <reason>`. The **main agent posts that text** as
  a new channel message.

## When the tail is added

| Launch | What the wrapper adds |
|---|---|
| fresh launch (`sume-bg-launch`, `agent-human-stream`, `claude-human-stream`) | the full tail, after the task text |
| `--resume <id> --fork-session` | the full tail (a fork is a new Job) |
| `--resume <id>` / `--continue` (steer) | one steer line: when this turn finishes new work, post a **new top-level message**; a status answer posts nothing |
| steer with `--same-thread` (launcher or wrapper), or the prompt marker `<!-- slack-report:same-thread -->` | the same-thread line: reply in the job's existing thread (`cstack-slack-post --same-thread`). For a poke, restart or effort change with no new instruction. A fork ignores it (a fork is a new Job) |
| `sume-cron-job` | nothing: cron prompts post their own result. `--slack-report` turns it on for one entry |
| prompt contains `<!-- slack-report:off -->` | nothing |
| prompt already contains `<!-- slack-report:tail` | nothing more (no second copy) |
| `--no-slack-report` (launcher or wrapper) or `CSTACK_SLACK_REPORT=0` | nothing, including the steer line |

`--host mini` sends the opt-out to the Mini as a flag (the laptop's env does
not cross ssh) and records `SLACK_REPORT=0` in the Mini `job.env`.

Research jobs that report elsewhere, or a job whose prompt has its own Slack
step, opt out with the flag or the marker. A prompt with its own Slack step
that keeps the tail is fine too: the tail tells the worker that the task's
Slack step and the report are the same post.

**No post** for: session or usage limit stops ("You have hit your session
limit"), work cut off midway, status-only steer turns, a result already
posted in this session. A killed job (exit 143) never reaches the post. The
worker posts in-band before it ends, so nothing posts after a kill.

## Dry run

```bash
sume-bg-launch --print-prompt --backend claude --name <slug> --prompt-file /tmp/job.md -- --model opus
agent-human-stream --print-prompt --name <slug> --prompt-file /tmp/job.md
```

It prints the exact prompt (worker preamble + task + tail) and launches
nothing. It also works inside a worker session (it is a read).

## How the worker posts: `cstack-slack-post`

Desk Macs have no Slack bot token. Workers post as Chase through the
**ego-browser** Slack web client: the same `localConfig_v2` token +
`/api/*` calls that workers already used by hand.

```bash
cstack-slack-post --job <slug> [--issue N] [--title "<short what>"] \
  --text-file /tmp/<job>/slack.txt [--file clip.mp4]… [--same-thread] [--dry-run]
```

- It refuses text over 600 characters or text that looks like a credential (exit 2).
- `auth.test` must say `chase`.
- Default (every completion report): one new top-level message, the parent line ``<title> — `<Lane> : <slug> (#N)` `` with the
  report under it (`chat.postMessage`, or one `files.completeUploadExternal`
  with up to 10 files and that text as its comment). Prints
  `SLACK: <permalink>`.
- `--same-thread` (only when the launch said so): it scans
  `#coding-agents` parents (up to 600, newest first) for the slug, `#N`, or
  the title, falls back to `search.messages`, and posts one reply there
  (with no match it posts the short parent first).
- `--new-thread` is accepted and does nothing (it is the default).
- `--dry-run` shows what it would post and posts nothing.
- The token stays in the page. It is never printed.

A worker with a Slack MCP tool may use that instead; the format and the
one-post rule are the same.

## Wrapper-side safety net: not built

A post-exit hook that posts `SLACK_TEXT:` when the worker could not would
need a Slack bot token on the desk. There is none, and adding one is out of
scope. The fallback is the main agent: it reads `SLACK_TEXT:` from the
final block and posts it.

## Main agent

- Workers post their own completion report, so the main agent does not post
  a second "done" message for that Job.
- Look for `SLACK:` in the final block. `SLACK_TEXT:` means post it yourself.
- Opt out per job: `--no-slack-report`, or the marker in the prompt.
