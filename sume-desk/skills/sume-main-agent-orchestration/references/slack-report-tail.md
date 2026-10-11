<!-- slack-report:tail v1 -->
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

**Where.** Reply in this job's thread. Search `#coding-agents` for the job slug `{{JOB}}` and the issue number. If there is no thread, post a short parent `` <short what> — `{{LANE}} : {{JOB}} (#N)` ``, then post the report as the parent's first reply. One report message per completion.

**How.** Post as Chase with your Slack tool. On desk Macs:
`cstack-slack-post --job {{JOB}} [--issue N] [--title "<short what>"] --text-file <file> [--file <clip>]…`
It finds or opens the thread, posts one reply through the ego-browser Slack web client, and prints `SLACK: <permalink>`. Never print the Slack token.

**Final block.** End with your usual final report: what was done, PR / SHA / issue / `SHOTS:` links, `LANDED: yes|no` for code jobs, then `SLACK: <permalink>`. If you have no Slack tool or the post fails, write the heading `SLACK_TEXT:` with the exact Korean text below it, then `SLACK: not posted — <reason>`, so the main agent can post it.
<!-- slack-report:steer v1 -->
[slack-report] Steer turn on job "{{JOB}}". The completion-report rule still applies (`~/.agents/skills/sume-main-agent-orchestration/references/slack-report-tail.md` if it is not in your history). Post only if this turn finishes new work, such as a new land or the final answer to a new ask: one reply in the job's existing thread. A status answer or a partial steer posts nothing.
