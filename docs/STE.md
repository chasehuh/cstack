# Simplified Technical English in cstack

`sume-ste` vendors [0xpili/simplified-technical-english](https://github.com/0xpili/simplified-technical-english),
an agent skill for ASD-STE100 Simplified Technical English.

Upstream pin: `0xpili/simplified-technical-english@1e148d670cba46685ad2b4c3f2354a637a7fdbbe`
(2026-08-15, based on ASD-STE100 Issue 7, 2017).

## Copied vs adapted

Copied byte for byte (`sync-from-upstream.sh`):

| Upstream | In `sume-desk/skills/sume-ste/` |
|---|---|
| `SKILL.md` | `STE-SKILL.md` |
| `references/writing-rules.md` (53 rules, 4 recommendations) | `references/writing-rules.md` |
| `references/word-list.md` (869 words) | `references/word-list.md` |
| `references/substitutions.md` | `references/substitutions.md` |
| `examples/before-after.md` | `examples/before-after.md` |
| `scripts/ste_check.py` (Python standard library only) | `scripts/ste_check.py` |
| `NOTICE.md`, `LICENSE` | `NOTICE.md`, `LICENSE` |

Adapted (desk-only, not upstream): `SKILL.md` (index, when to invoke, the
"On this desk" non-uses), `agents/openai.yaml`, `sync-from-upstream.sh`.
Upstream's `README.md` is not copied.

## Scope (Chase lock 2026-10-04)

For English technical docs that a human reads and that live in a codebase:
procedures, manuals, runbooks, instructions, warnings, reports, error
sentences.

Not for code comments, chat with Chase (Korean), agent-to-agent handoff
text, marketing / brand / product-voice prose, or Korean docs. Upstream's
own exclusions (code blocks, identifiers, commands, paths, quoted errors,
conversation, marketing) also hold, and a user's style request wins.

## Invocation

User-invoked only: `disable-model-invocation: true` for Claude Code, Cursor,
and Grok, and `agents/openai.yaml` `policy.allow_implicit_invocation: false`
for Codex. A prompt may name the skill for an in-scope doc. `install.sh`
still links the folder into every harness skill dir, so the skill name and
description are visible in skill lists; the "On this desk" scope is what
keeps it off comments, chat, and handoffs. It is never the default voice of
the main agent or a worker.

## Resync

```bash
git clone https://github.com/0xpili/simplified-technical-english /tmp/ste
sume-desk/skills/sume-ste/sync-from-upstream.sh /tmp/ste
git diff --stat   # review, then update the pin above
```

## License and copyright

The skill text and `ste_check.py` are MIT, Copyright (c) 2026 0xpili
(`sume-desk/skills/sume-ste/LICENSE`). The word list shows words from the
ASD-STE100 dictionary, which is the property of ASD (AeroSpace and Defence
Industries Association of Europe); ASD-STE100 is a registered trade mark of
ASD. The skill is not an ASD product and does not certify compliance. Full
note: `sume-desk/skills/sume-ste/NOTICE.md`. The official specification is
free from https://www.asd-ste100.org.
