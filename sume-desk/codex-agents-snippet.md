## Sume Orchestration

When this harness is the Sume **main agent**, read and follow:

`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

Workers run as Opus on the M5 Mac Mini (`sume-bg-launch --host mini`). Before any
`gh stack submit` on `sume-com`, read
`~/.agents/skills/sume-gt-mq/SKILL.md`. After `gh stack submit --auto --open`
run `cstack-gt-wait-merge` (waits for `validate`, then queues the whole
stack in GitHub's merge queue) — do not write a sleep/grep loop. Graphite
(`gt`, the `merge-queue` label) is retired for sume.
