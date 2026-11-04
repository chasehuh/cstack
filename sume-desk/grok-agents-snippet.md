## Sume Orchestration

When this harness is the Sume **main agent** or a Grok Build worker, read:

`~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

Before any `gt submit` / `gt merge` on `sume-com`, read
`~/.agents/skills/sume-gt-mq/SKILL.md`. After `gt submit` run
`cstack-gt-wait-merge` (labels the tip `merge-queue` now) — do not
write a sleep/grep loop or wait for PR CI.
Ignore sections marked **Cursor-only** unless you are Cursor.

Land babysit (Grok Build worker): do **not** use `monitor` / `scheduler_*`
to wait — a background hand-off ends your headless turn with a snapshot.
Block in `run_terminal_command` (≤10 min slices, `sleep` between polls). Reply
`LANDED: yes` only when `git log origin/main --oneline --grep='(#N)'` hits;
otherwise end the turn with one status line — the desk wrapper re-prompts
this same session until the grep hits.
