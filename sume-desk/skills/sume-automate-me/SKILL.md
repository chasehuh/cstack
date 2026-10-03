---
name: sume-automate-me
description: >-
  Draft or refresh chase-mode, a personal working-style skill built from how
  Chase actually works on the Sume desk (his corrections, locks, and
  recurring preferences across Cursor, Claude Code, Codex, and Grok
  sessions), and land it in chasehuh/cstack so every harness reads it. Use
  only when the user asks: "/sume-automate-me", "automate me", "update my
  mode skill", "capture my working style as a skill".
disable-model-invocation: true
---

# Sume automate-me

Adapted from pstack `automate-me` (MIT, Lauren Tan; `docs/PSTACK.md` in
chasehuh/cstack). Turns the user's working conventions into one `-mode`
skill that agents follow. On this desk the user is Chase and the output is
`sume-desk/skills/chase-mode/` in chasehuh/cstack, installed like every
other desk skill.

The mode skill captures style and taste. For policy it points at the desk
skills and never restates or overrides them: `sume-main-agent-orchestration`
(roles, routing, transport, effort lanes, status board, dest evidence),
`sume-gt-mq` (Graphite land), `github-mega-issue`,
`mobidoo-live-commerce-update`, and `sume-principles`.

## 0. Check for an existing mode skill

Look for it on trunk:
`git show origin/main:sume-desk/skills/chase-mode/SKILL.md`. If it exists,
update it (the default). Start fresh only when Chase asks, and ask why
before you do.

Update mode changes the rest of the flow:

- Step 1 mines only evidence newer than the skill's last commit
  (`git log -1 --format=%cI -- sume-desk/skills/chase-mode`).
- Step 2 asks what changed or is missing, not what to capture from zero.
- Step 4 edits in place. Keep sections Chase has not contradicted, revise
  the ones with new evidence, and add a section only for a genuinely new
  rule.

## 1. Mine the evidence

State the scope back before reading anything: the window (default the last
three weeks), the topic if one was named, and the sources below. Read Sume
desk sessions only, never transcripts from unrelated projects.

Sources, strongest first:

1. Corrections Chase already made durable: the Claude memory files
   (`~/.claude/projects/*/memory/*.md`), the `Chase lock` lines in the cstack
   skills and Cursor rules, and the cstack commit history.
2. Chase's own words in main-agent sessions: Cursor transcripts under
   `~/.cursor/projects/<sume slug>/agent-transcripts/` and interactive Claude
   Code sessions under `~/.claude/projects/<slug>/*.jsonl`.
3. Worker sessions listed in `~/.cstack/state/opus-sessions.jsonl` (each
   row has `backend`, `cwd`, `session_id`, `live_log`), with their
   transcripts under `~/.claude/projects/`, `~/.codex/sessions/`, or
   `~/.grok/sessions/`, and the prompts in `~/.cstack/state/remote-jobs/`.
   A worker's user turns are the main agent's prompt, so treat them as
   Chase's rules at second hand.

Split the window into three slices. Give each slice to a read-only
in-process subagent when the harness has them (Claude Code Agent or
Explore). Otherwise read the slices yourself. Each slice returns a short list
of patterns with evidence pointers (file and line, or session id), never raw
transcript text. Chase often writes in Korean, so quote the original and
translate it.

Signals to hunt:

- Reply preferences: language, length, report shape, what he asks to cut.
- Engineering taste he corrects in code and design.
- Verification posture beyond what the desk skills already lock.
- Product and UI taste: copy, naming, layout.
- Delegation habits that orchestration does not already cover.
- Meta habits: when he wants a skill fixed, a memory saved, or a new skill.

A pattern seen in two or more slices is high confidence. A lone signal, or
one Chase later contradicted, is noise. Drop it.

## 2. Ask Chase directly

Mining misses intent that has not come up yet.

- Interactive session: one or two multiple-choice rounds (4 to 6 options,
  multi-select) in Chase's language, then one free-form question. Do not
  dump twenty questions.
- Worker session with no human: do not block. Draft from the evidence and
  put the open questions in the PR body under `## Questions for Chase`.

## 3. Cluster

Group the signals into sections, and keep only sections that hold a
specific, non-default rule: response style, autonomy, understand first,
subagents, code and prose discipline, review and verify, process, skills.
"Communicate clearly" is not a section. "Short paragraphs, tables when
comparing options" is.

A rule a desk skill already owns becomes a one-line pointer to that skill.
Skip any section with nothing Chase-specific in it.

## 4. Draft

- Path: `sume-desk/skills/chase-mode/SKILL.md` in a fresh clone of
  chasehuh/cstack. Never edit the shared desk checkout (`~/.cstack/src`).
- Frontmatter: `name: chase-mode`, and a `description` that triggers on
  "chase-mode", "/chase-mode", or "work in Chase's style", not on generic
  words like "write code". Keep `description` one YAML scalar (`>-` for
  wrapping). Set `disable-model-invocation: true` unless Chase wants the mode
  on every turn. Codex ignores that key, so also add
  `agents/openai.yaml` with `policy: { allow_implicit_invocation: false }`
  (copy this skill's own `agents/openai.yaml`).
- Write imperatives about "the user", not "Chase".
- Reference other skills by path. Do not paste their content.
- Add `link_skill chase-mode` to `install.sh` and a row to `docs/FLOW.md`.

## 5. Iterate on the prose

Cut every sentence that would not change an agent's decision. Use plain,
operational sentences: no metaphors, no restated skills, no filler. Show
Chase the draft when the session is interactive and expect several rounds.
A mode skill is not a manual.

## 6. Land

chasehuh/cstack is not sume-com, so there is no `gt`. From the fresh clone,
branch, commit, and `gh pr create`. Never push to `main` directly.

- Interactive session: once Chase approves the draft, `gh pr merge <N>
  --squash` and prove the land with `git fetch origin main && git log
  origin/main --oneline --fixed-strings --grep='(#N)'`.
- Worker session: stop at the open PR and report its URL. This is the one
  desk PR that waits for Chase, because a mode skill changes every agent's
  behavior and only Chase can say it reads like him.

After the merge, each desk machine links the skill with
`git -C ~/.cstack/src pull && ~/.cstack/src/install.sh`.

## Guardrails

- Don't overfit to one conversation. A preference stated once and
  contradicted later is noise. Require several instances.
- Don't be clever. Operational rules only.
- Reference, don't inline.
- Keep sections minimal. Skip a section with no Chase-specific rule.
- Never override a desk lock. Effort lanes, routing, Graphite, land, and dest
  evidence belong to their skills, and the mode skill points at them.
- chasehuh/cstack is public. No secrets, tokens, customer names or data, or
  private URLs.

Judge the result with Chase, not a benchmark: does it read like him, and did
it miss anything? Then ship.

## When not to use

- A task-specific skill rather than working conventions: write that skill
  directly, no mining.
- One narrow workflow, such as how Chase writes commit messages: a regular
  skill, not a mode skill.
