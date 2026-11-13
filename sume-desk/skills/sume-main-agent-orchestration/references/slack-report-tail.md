<!-- slack-report:tail v3 -->
## Completion report (cstack default: post to Slack #coding-agents)

When this job reaches its real completion (done criteria met, or you stop for good with a final answer), post ONE report to Slack `#coding-agents` (`C0A9L7AU5HS`) before you end. Spec: `~/.cstack/src/docs/SLACK-REPORT.md`.

Do not post when:
- you stop on "You have hit your session limit" / a usage limit, or you are cut off mid-work;
- this turn only answers a status question or a steer without finishing new work;
- you already posted this same result in this session. If the task above already asks for a Slack post, that post is this report. Post once, not twice.

**Text.** Korean, 600 characters or fewer, Slack mrkdwn, in the desk format:

```
*<짧은 한국어 제목>* · <issue URL|#N> → PR #M (`sha`) main 반영 (dev)
• 원인/한 일: …
• 검증: … (숫자, before → after)
• 남은 것: … (없으면 이 줄 생략)
<evidence URL|증거 링크>
```

- Use the facts you have: issue, PR, SHA, `LANDED`, `SHOTS` comment. Drop the parts that do not apply (a research job has no PR).
- Never include secrets, tokens, keys, cookies, `.env` values, or raw proprietary code. File names and identifiers are fine.
- Attach the clips or images you already made (10 files at most), on the same message.

**Where (Chase lock 2026-10-13, 2026-11-03).** Every launch of this job, including a resume or steer that carries a new instruction, reports as a **new top-level message** in `#coding-agents`, never as a reply in an old thread. Post the parent `` <short what> — `{{LANE}} : {{JOB}} (#N)` `` and put the report in that message (images on the same message). Reply in an existing thread only when the prompt explicitly says so (`--same-thread`), or for a second note about the same ask right after the parent you just posted (for example the dev shots).

**DM is extra, never a replacement (Chase 2026-11-03).** If the task asks you to DM Chase or anyone else, send the DM too, and still post this report to `#coding-agents`. "DM only", "not in the channel" or "send it privately" never cancels the channel report. Amounts and other financial figures are fine in the channel.

**How.** Post as Chase with your Slack tool. On desk Macs:
`cstack-slack-post --job {{JOB}} [--issue N] [--title "<short what>"] --text-file <file> [--file <clip>]…`
A new top-level message is the default. It posts through the ego-browser Slack web client and prints `SLACK: <permalink>`. Never print the Slack token. Do not search for an old thread and reply there.

**Final block.** End with your final report, written for a reader who has not seen your tool calls or files: first one or two plain sentences with the outcome (what changed, whether it landed, what is left), then the PR / SHA / issue / `SHOTS:` links, `LANDED: yes|no` for code jobs, then `SLACK: <permalink>`. Do not use names you made up during the work. If you have no Slack tool or the post fails, write the heading `SLACK_TEXT:` with the exact Korean text below it, then `SLACK: not posted — <reason>`, so the main agent can post it as a new channel message.
<!-- slack-report:steer v3 -->
[slack-report] New instruction on job "{{JOB}}". The completion-report rule still applies (`~/.agents/skills/sume-main-agent-orchestration/references/slack-report-tail.md`). When this turn finishes new work, post the report as a **new top-level message** in `#coding-agents` (`cstack-slack-post --job {{JOB}} --text-file <file>`; new thread is the default), not a reply in this job's old thread. A DM request is extra delivery: send it and still post to the channel (amounts are fine there). A status answer or a partial steer posts nothing.
<!-- slack-report:same-thread v3 -->
[slack-report] Same ask, continued on job "{{JOB}}" (a poke, restart or effort change, not a new instruction). When this turn finishes new work, post the report as a **reply in this job's existing thread**: `cstack-slack-post --job {{JOB}} --text-file <file> --same-thread`. A DM request is extra delivery: send it and still post to the channel. A status answer posts nothing.
