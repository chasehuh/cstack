## Sume Orchestration

When this harness is the Sume **main agent**, read and follow:

`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

Workers run on the M5 Mac Mini (`sume-bg-launch --host mini`): Opus by
default, Fable when Chase names it. Before any `gh stack submit` on
`sume-com`, read `~/.agents/skills/sume-gt-mq/SKILL.md`. After
`gh stack submit --auto --open` run `cstack-gt-wait-merge` (waits for
`validate`, then queues the whole stack in GitHub's merge queue) — do not
write a sleep/grep loop. Do not use `gt` or the `merge-queue` label on sume.
