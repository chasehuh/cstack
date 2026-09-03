## Sume Orchestration

When this harness is the Sume **main agent** or a Grok Build worker, read
in order:

`~/.cstack/src/AGENTS.md`
`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

Before any `gt submit` / `gt merge` on `sume-com`, read
`~/.agents/skills/sume-gt-mq/SKILL.md`. After `gt submit` run
`cstack-gt-wait-merge` (labels the tip `merge-queue` now) — do not
write a sleep/grep loop or wait for PR CI.
Ignore sections marked **Cursor-only** unless you are Cursor.
