# pstack in cstack

[pstack](https://github.com/cursor/plugins/tree/main/pstack) is Lauren Tan's
(poteto) Cursor plugin of engineering workflow skills, MIT-licensed. cstack
carries the pieces that fill a real gap on the Sume desk, adapted to it.

Upstream pin: `cursor/plugins@23e4138daa01c42d4969f7a5465f82704e64f798`
(pstack 0.15.6, 2026-10-03).

## What we took

| cstack skill | From pstack | Desk changes |
|---|---|---|
| `sume-principles` | the 24 `principle-*` skills and `benchmark-checklist` | One skill (index plus `references/`) instead of 25 catalog entries. Leaves are verbatim except that `sync-from-pstack.sh` drops the frontmatter (and the blank line after it) and rewrites links between them. An "On this desk" section ties them to the orchestration locks. |
| `sume-architect` | `architect`, plus arena's pick-a-base-and-graft step | Runs inside one session: design twice yourself or with in-process subagents. No Cursor Task model map. The rationale goes in the mega-issue or a Job issue comment. `references/design-red-flags.md` is verbatim. |
| `sume-blast-radius` | `blast-radius` | Lists the places grep misses on this desk (API and stream payloads, DB columns, dest vs prod env, billing). The proof goes in the PR body under `## Blast radius`. |
| `sume-automate-me` | `automate-me` | Mines desk sources (Claude memory, cstack locks, Cursor / Claude / Codex / Grok sessions), drafts `chase-mode` in this repo with `gh` (not `gt`). A worker run stops at the open PR for Chase's review. User-invoked only: `disable-model-invocation` for Claude Code, Cursor, and Grok, and `agents/openai.yaml` `policy.allow_implicit_invocation: false` for Codex. |

None of the four picks a model or an effort. Roles, routing, transport
(`sume-bg-launch`), effort lanes, Graphite, land, and dest evidence stay in
`sume-main-agent-orchestration` and `sume-gt-mq`. A worker never launches a
nested worker (sume#7839), so every fan-out these skills mention is an
in-process subagent.

## What we skipped, and why

| pstack piece | Why not |
|---|---|
| `poteto-mode`, its 23 playbooks, `poteto-agent` | A second orchestrator: its own router, Cursor Task subagents on its default model map, PR babysit and ship through `gh pr merge`. It would fight `sume-bg-launch` and Graphite MQ. |
| `setup-pstack` (`pstack-models.mdc`) | A per-role model map. Chase's lane table is the lock. |
| `arena`, `swarm` | Cross-model fan-out through Cursor Task or cloud agents, which a worker cannot do. Arena's pick-and-graft lives inside `sume-architect`. |
| `interrogate` | Same fan-out problem. Claude Code ships `/code-review`, and cstack removed its old review skill on purpose. |
| `how`, `why`, `teach`, `recall` | `how`'s trace and `why`'s git / `gh` anchor are inlined in `sume-architect` and `sume-blast-radius`. `why` fans out one investigator per evidence category (seven of them) through the MCPs Cursor discovers, and `recall` reads Cursor transcript paths. The status board and session registry already cover recall. A cited-history `why` for RCA is a candidate follow-up. |
| `unslop`, `technical-writing`, `no-comments` (and Comment Sicko) | poteto's prose and comment taste (no em dashes, no comments), which conflicts with the desk's own style. `sume-automate-me` is how Chase's real taste gets written down. |
| `bro` | A one-line "restate that plainly" prompt. Chase can just ask, in his own language. |
| `tdd`, `typescript-best-practices` | Covered by `test-behavior-not-implementation` and `type-system-discipline` in `sume-principles`. sume-com's own AGENTS.md and lint own TypeScript style. |
| `reflect`, `show-me-your-work`, `figure-it-out` | Overlap with Claude memory, the opus-live logs and final reports, and orchestration Pipeline 1. Candidate follow-ups. |
| `create-verification-skill`, `maintain-verification-skill` | Browser proof is `ego-browser` plus the dest-verify recipe. A sume-com verify skill would be a sume-com PR. |
| `make-bot-ui`, `automations/benny` | Grok Bot webhook pages and dormant Cursor automations for Slack issue triage. Neither is part of the desk flow. |
| poteto-mode's scripts (`orch`, `watch-pr`, `check-plan`, `worktree-audit`) | The orchestrate store CLI, a GitHub PR watcher, the multi-phase plan linter, and a Cursor worktree audit. They serve the skipped playbooks. The Graphite flow has `cstack-gt-wait-merge`, and jobs use `cstack-clone` / `cstack-clone-rm`. |
| `/add-plugin`, the plugin manifest, the logo | Cursor UI chrome with nothing to vendor. |
| `docs/guide/` | A tutorial for poteto-mode and the skills above. The desk equivalent is `docs/FLOW.md` plus this page. |

If the pstack Cursor marketplace plugin is also installed, its skills keep
their pstack names (`architect`, `blast-radius`, ...). On desk work use the
`sume-*` skills. The plugin's model map is not the desk lock.

## Resync

```bash
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/cursor/plugins.git /tmp/cursor-plugins
git -C /tmp/cursor-plugins sparse-checkout set pstack
sume-desk/skills/sume-principles/sync-from-pstack.sh /tmp/cursor-plugins/pstack
git diff --stat
```

Review the diff, then update the pin above. `sume-architect`,
`sume-blast-radius`, and `sume-automate-me` are adaptations: diff them by
hand against upstream `skills/architect/`, `skills/blast-radius/`, and
`skills/automate-me/` when pstack moves.

## License

Copies of pstack files: everything under
`sume-desk/skills/sume-principles/references/` and
`sume-desk/skills/sume-architect/references/design-red-flags.md`.
Adapted from pstack: the `sume-principles` index (from poteto-mode's
Principles section), the rest of `sume-architect`, `sume-blast-radius`, and
`sume-automate-me`. Each of those four skill folders carries a `NOTICE.md`
with this license, because each one is symlinked into the harness skill dirs
on its own:

```text
MIT License

Copyright (c) 2026 Lauren Tan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
