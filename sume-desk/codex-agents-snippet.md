## Sume Orchestration

When this harness is the Sume **main agent**, read and follow:

`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

Ignore sections marked **Cursor-only** unless you are Cursor. Before any
`gt submit` / `gt merge` on `sume-com`, read
`~/.agents/skills/sume-gt-mq/SKILL.md`. After `gt submit` run
`cstack-gt-wait-merge` (labels the tip `merge-queue` now) — do not
write a sleep/grep loop or wait for PR CI.
