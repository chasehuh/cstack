<!-- slack-report:tail v2 -->
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

**Where (Chase lock 2026-10-13).** A new ask from Chase is a **new channel message**, not a reply on an old thread. Post the parent `` <short what> — `{{LANE}} : {{JOB}} (#N)` `` and put the report in that message (images on the same message). Do not reply in an older thread for this job, even if one exists. A reply is only for a second note about the same ask in the same session (for example the dev shots after the parent you just posted).

**How.** Post as Chase with your Slack tool. On desk Macs:
`cstack-slack-post --job {{JOB}} [--issue N] [--title "<short what>"] --text-file <file> [--file <clip>]… --new-thread`
It posts a new parent through the ego-browser Slack web client and prints `SLACK: <permalink>`. Never print the Slack token. If the tool has no `--new-thread` flag, post a new channel message yourself. Do not search for an old thread and reply there.

**Final block.** End with your usual final report: what was done, PR / SHA / issue / `SHOTS:` links, `LANDED: yes|no` for code jobs, then `SLACK: <permalink>`. If you have no Slack tool or the post fails, write the heading `SLACK_TEXT:` with the exact Korean text below it, then `SLACK: not posted — <reason>`, so the main agent can post it as a new channel message.
<!-- slack-report:steer v2 -->
[slack-report] Steer turn on job "{{JOB}}". The completion-report rule still applies. Post only if this turn finishes new work. A new ask is a **new channel message**, not a reply on the old thread. A status answer or a partial steer posts nothing.
