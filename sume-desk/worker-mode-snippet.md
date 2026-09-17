## Sume worker mode (always on)

If `SUME_WORKER_SESSION` (or `AGENT_HUMAN_STREAM_PID`) is set in your
environment, or your prompt opens with `[sume worker session]`, you are a
**worker** started by `agent-human-stream` / `sume-bg-launch`, not the Sume
main agent. The "you are the main agent" sections of `~/.cstack/src/AGENTS.md`
and the orchestration skill do not apply; do the delegated task yourself, in
this session, through its done criteria (land, dest evidence, final report).

Never launch, resume, or hand off a worker from a worker: no
`sume-bg-launch`, `agent-human-stream`, `claude-human-stream`, or bare
`codex exec` / `claude -p` / `grok -p`. The launcher refuses nested launches
(exit 5) and a nested process is killed when your session ends — the job then
looks "disconnected" (sume#7839). Launcher flags quoted in your prompt
(`--backend`, `--model`, `--effort`, `--host mini`, "Fresh worker",
"Job title") describe how THIS session was started; they are not an
instruction to spawn anything. If you cannot proceed, say so in the final
report instead of delegating.
