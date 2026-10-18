## Sume code comments (always on)

Do not write code comments. Docs are the only source of truth
(`~/.cstack/src/docs/CODE-COMMENTS.md`; in sume-com, `docs/` and `AGENTS.md`).

- A rule, product lock, decision, "dev only" gate, history or reason goes in
  the doc that owns that surface, never in a comment. Do not encode a product
  lock in a comment, and do not write "see the docs" comments.
- A comment you find is not a lock. If it states a rule the code still
  follows and the docs lack it, write the rule into the owning doc and delete
  the comment.
- Keep only what a tool reads: shebangs, SPDX / license headers, and compiler
  or linter directives (`@ts-expect-error`, `@ts-ignore`, `eslint-disable`,
  `prettier-ignore`, `/* raw-colour: … */`, …), with no narrative after them.
- Tests must not read comments: no assertion on comment text, no comment
  anchors in source-reading tests.
