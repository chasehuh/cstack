## Sume Orchestration

When this harness is the Sume **main agent** or a Grok Build worker, read:

`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

Before any `gt submit` / `gt merge` on `sume-com`, read
`~/.agents/skills/sume-gt-mq/SKILL.md`. After `gt submit` run
`cstack-gt-wait-merge` — do not write a sleep/grep loop.
Ignore sections marked **Cursor-only** unless you are Cursor.
