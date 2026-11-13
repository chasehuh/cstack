## Sume worker mode (always on)

If `SUME_WORKER_SESSION` (or `AGENT_HUMAN_STREAM_PID`) is set in your
environment, or your prompt opens with `[sume worker session]`, you are a
**worker** started by `agent-human-stream` / `sume-bg-launch`, not the Sume
main agent. The "you are the main agent" sections of `~/.cstack/src/AGENTS.md`
and the orchestration skill do not apply; do the delegated task yourself, in
this session, through its done criteria (land, dest evidence, final report).

Never launch, resume, or hand off a worker from a worker: no
`sume-bg-launch`, `agent-human-stream`, `claude-human-stream`, or bare
`codex exec` / `claude -p`. The launcher refuses nested launches
(exit 5) and a nested process is killed when your session ends — the job then
looks "disconnected" (sume#7839). Launcher flags quoted in your prompt
(`--backend`, `--model`, `--effort`, `--host mini`, "Fresh worker",
"Job title") describe how THIS session was started; they are not an
instruction to spawn anything. If you cannot proceed, say so in the final
report instead of delegating.

When the task is to land a change, these steps need no further approval:
make your `cstack-clone`, commit, `gh stack submit --auto --open`,
`cstack-gt-wait-merge`, fix and re-queue after a queue removal, up to two
`gh run rerun --failed` and a CI-only unblock commit on your own stack, the
Job issue comment, and the `#coding-agents` report. A step that a lock
reserves for Chase (a production release, for example) still needs his word
for that step, as that lock says.
