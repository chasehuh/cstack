## Sume author completion (always on)

Fable/Opus authors, including Claude Code **workers**: stay in-process in
the same session until a fresh `git fetch origin main` and
`git log origin/main --oneline --fixed-strings --grep='(#N)'` show your
landed PR (replace N with the PR number). Enqueue is not done.
Forbidden: `ScheduleWakeup`, Monitor, or a background poll/watcher **then
exit** before that proof. Re-enqueue on MQ eject in the same session;
do not STOP at enqueue or hand off land to Grok. This overrides older
STOP/handoff wording, regardless of the main-agent gate above.

For sume-com, read `~/.agents/skills/sume-gt-mq/SKILL.md` and
`~/.cstack/src/sume-desk/GRAPHITE-HARD-LOCK.md` before authoring/submitting.
After `gt submit`, run `cstack-gt-wait-merge`, then **stay until main**;
the helper returning successfully is only enqueue evidence. Report
`LANDED: yes` with the PR URL and main SHA only after main proof.
