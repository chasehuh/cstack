# Desk changelog

Newest first. What changed in how the desk runs, and what was removed, so a
stale habit can be traced to the day it stopped being true.

## 2026-11-01 — cleanup to match the real desk (cstack-cleanup)

Derived from the M5 job history (`~/.cstack/state/remote-jobs/*`,
`opus-sessions.jsonl`, 2026-10-18 → 2026-11-01): ~2,200 worker starts,
all Claude Opus; 86% resume or fork; ~314 `STEERING UPDATE` steers;
effort high 48% / medium 27% / xhigh 19% / max 5% / low 1%; 6 Grok runs,
none since 2026-10-30; every job ran on the M5 through `sume-bg-remote`.

### The desk now

- Main agent: Claude Code on the laptop. Workers: Opus
  (`claude-opus-5-5`) on the **M5** via `sume-bg-launch --host mini`;
  fresh / fork (`--resume --fork-session`) / steer (`--resume`,
  `STEERING UPDATE`). Prompts in `~/.cstack/state/prompts/`.
- Land: `gh stack` + `cstack-gt-wait-merge` until `origin/main` `(#N)`.
- Slack: one Korean report per ask, as a new channel message (lock
  2026-10-13).
- Release: release-only job on Chase's word (lock 2026-10-18).

### Removed

| What | Why | Leftover on a machine |
|---|---|---|
| Cursor main-agent mechanics: SKILL sections "Cursor-only — Opus / background-worker monitoring", "Cursor-only — Status board", Shell `block_until_ms` recipes, canvas board, Cursor pointer wiring | Cursor is not the main agent | `~/.cursor/rules/{opus-background-terminal,status-board,active-workers-canvas,end-of-turn-worker-brief,graphite-ci-ready,main-agent-orchestration,sume-chase-work-loop,worker-reasoning-effort,slack-coding-agents}.mdc` and `<sume-com>/.cursor/rules/{main-agent-orchestration,opus-via-claude-cli,…}.mdc` stay until deleted by hand; install no longer writes or refreshes them |
| `cursor-rule-template.mdc`, `install-cursor-rule.sh`, the Cursor checks in `check-wiring.sh` | same | — |
| Grok routing: Grok land babysit, Grok author, Grok research default, `grok-agents-snippet.md`, `~/.grok/AGENTS.md` sections, `~/.grok/skills` links | Chase: "grok 은 일단 필요 없고"; no Grok job since 2026-10-30 | `~/.grok/AGENTS.md` and `~/.grok/skills/*` stay as they are; the wrapper keeps `--backend grok` code |
| `HANDOFF: grok-land` wording | the author owns land (2026-09-06); now phrased as "never hand land to another worker" | — |
| `gt submit` / `gt merge` as the land path in FLOW / AGENTS / README | Graphite retired for sume 2026-10-30 (`gh stack` + GitHub merge queue) | `cstack-gt-wait-merge` and `GRAPHITE-HARD-LOCK.md` keep their old names (snippets on every machine point at them) |
| Old `merge` / `audit` / `propose` copies note | removed long ago; the note itself is gone | — |
| M4 as a default target | the M5 is the default Mini (lock 2026-10-08); M4 only with `--host m4` | — |
| `/tmp/sume-*-prompts` in recipes | a `/tmp` prompt dir vanished mid-day and broke a launch | — |
| Default `--backend grok` in `sume-bg-launch` / `sume-bg-remote` | a launch without `--backend` started Grok | default is now `claude` |

### Kept (still used, or not sure)

- `agent-human-stream --backend codex|grok` code and its self-tests.
- Cursor rules that still hold when Cursor is an editor
  (`no-code-comments`, `no-feature-flags`, `release-lock`,
  `origin-main-sot`, `aside-browser-verify`, `canvas-user-language`,
  `chat-title-folder-prefix`) and the `cursor-rules/sume-com/` repo rules.
- Skill links into `~/.cursor/skills`.
- The Codex pool in `docs/TOKENMAXXING.md`.

### Fixed (2026-11-01 incidents)

- **Liveness trusted a bare pid.** After the reboot, `--jobs` showed
  `mini-plug-unlock` alive on macOS `mapssyncd` and `google-ko-sitelinks`
  on another job's wrapper; `--kill` would have killed that process group.
  `sume-bg-remote start` records `pid_start`; a job is `running` only when
  the pid still has that start time (older jobs: its command names the
  job). New `state=` column (`running|exited|lost|pid-reused`); `--kill`
  refuses `pid-reused` (exit 6).
- **A steer did not stop the older wrapper.** The steer kill matched
  `pgrep -af` output; on macOS `-a` means "include ancestors", not "print
  arguments", so nothing ever matched and two wrappers ran on one session.
  The M5 start step now stops every running job holding the session (by its
  `📎 session_id=` line or a non-fork `RESUME`) before it starts; the local
  path reads `ps -axo pid=,command=` plus the registry's wrapper pid.
- **Prompt dir vanished.** Prompts live in `~/.cstack/state/prompts/`
  (`sume-bg-launch --prompt-dir`); a missing prompt names that dir.
- **`~/.cstack/mini-ssh.env` pointed at the M4.** `sume-desk/hosts.env` is
  the single SoT; install writes `CSTACK_MINI_SSH` = M5 into
  `mini-ssh.env` (old file kept as `.bak.<stamp>`); the launcher resolves
  env → `mini-ssh.env` → `hosts.env`, and a stale M4 value under
  `--host mini` goes to the M5.
- **Slack tail v2 never split.** The v2 tail (new ask = new thread, lock
  2026-10-13) sat uncommitted on the M5 since 2026-10-14, and
  `agent-human-stream` split it on a hard-coded `steer v1` marker, so every
  prompt got the full tail plus the steer line. The marker is now read from
  the file; the tail, `SLACK-REPORT.md` and `cstack-slack-post --new-thread`
  (report in the parent message) are committed.
- **Network:** documented the M5 Wi-Fi limit (≤4 media probes, byte
  ranges) after an 84-probe scan starved every `git fetch`.

### Laptop dirt (`35cff43` + uncommitted, copied 2026-11-01)

- `docs/FLOW.md` status-board row "chat prints 지금 only" → kept as the
  status rule in the orchestration skill; the Cursor status-board row is
  gone with the Cursor rules.
- Orchestration SKILL "M5 default, M4 only on Chase's word" (2026-10-08)
  → kept, now `sume-desk/hosts.env` + `--host m4`.
- Orchestration SKILL status board "지금 only" (2026-10-17) → kept
  (§ Status checks); the Cursor canvas / lanes text is dropped.
- `references/slack-report-tail.md` v2 → identical to the M5 copy;
  committed.
