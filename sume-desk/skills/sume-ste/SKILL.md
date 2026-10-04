---
name: sume-ste
description: >-
  Simplified Technical English (ASD-STE100) for English technical docs that a
  human reads and that live in a codebase: procedures, manuals, instructions,
  warnings, reports, and error sentences. 53 writing rules, the 869-word
  approved list, substitutions, examples, and a checker script, vendored
  verbatim. Use only when the user asks for STE / Simplified Technical
  English, or the task names this skill for an English technical doc. Not for
  code comments, chat with Chase, agent handoffs, marketing, or Korean.
disable-model-invocation: true
---

# Sume STE

Simplified Technical English, vendored verbatim from
[0xpili/simplified-technical-english](https://github.com/0xpili/simplified-technical-english)
(MIT for the skill text and script; the word list is from the ASD-STE100
dictionary, property of ASD — see `NOTICE.md`). Pin, copied vs adapted, and
resync: `docs/STE.md` in chasehuh/cstack.

This file is only the desk wrapper. The instructions are upstream's.

## Use

1. Check the scope in **On this desk** below. If the text is out of scope,
   do not use STE.
2. Read `STE-SKILL.md` in full and obey it. It is the upstream `SKILL.md`,
   unchanged. Its paths (`references/…`, `examples/…`, `scripts/…`) are
   relative to this folder.
3. For a rewrite or an unclear rule, read `references/writing-rules.md`
   (53 rules, 4 recommendations). Check words against
   `references/word-list.md` (869 words) and `references/substitutions.md`.
   See `examples/before-after.md` for the target.
4. Check the result:
   `python3 ~/.agents/skills/sume-ste/scripts/ste_check.py --mode <procedural|descriptive|mixed> <file>`
   (standard library only; exit 1 = errors). The script cannot judge word
   meanings, so also compare against the word list.

## Files

| Path | What |
|---|---|
| `STE-SKILL.md` | Upstream instructions: scope, classify, verb / sentence / word / safety rules, check loop |
| `references/writing-rules.md` | All 53 rules and 4 recommendations, with examples |
| `references/word-list.md` | 869 approved words, parts of speech, forms (ASD-STE100 Issue 7) |
| `references/substitutions.md` | Replacements for frequent unapproved words; technical names and verbs |
| `examples/before-after.md` | Before / after rewrites |
| `scripts/ste_check.py` | Rule checker for text or Markdown |
| `NOTICE.md`, `LICENSE` | ASD copyright note, no-affiliation note, MIT |

## On this desk

Chase lock (2026-10-04). STE is for **English technical docs that a human
reads, written into a codebase**: procedures, manuals, runbooks,
instructions, warnings, reports, and user-facing error sentences.

Do **not** use STE for:

- code comments;
- chat with Chase (that stays Korean, per orchestration);
- agent-to-agent handoff text: worker prompts, final reports, status board,
  Slack mirror;
- marketing, brand, or product-voice prose;
- Korean docs.

Upstream's own exclusions also hold: no STE for marketing, poems, stories,
conversation, code blocks, identifiers, commands, file paths, quoted error
messages, quoted text, or official names. If the user asks for a different
style, the user wins.

STE is not the default voice of any agent on this desk. It applies only to
the doc in scope, only when asked or named. It never overrides roles,
routing, effort, Graphite, land, or dest evidence in
`sume-main-agent-orchestration` and `sume-gt-mq`.
