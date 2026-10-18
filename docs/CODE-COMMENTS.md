# Code comments: none (docs are the source of truth)

Chase lock 2026-10-17. Applies to every harness on the desk (Cursor, Claude
Code, Codex, Grok Build) and to every repo the desk writes code in.

## The rule

Do not write code comments. Docs are the only source of truth.

- A rule, product lock, decision, default, "dev only" / "dest only" gate,
  history or reason goes in the doc that owns that surface, never in a
  comment. In `sume-com` that is `docs/` (index: `docs/README.md`) or the
  `AGENTS.md` that owns the directory.
- Do not encode a product lock in a comment. Do not write "see the docs"
  comments either: the doc is found from the docs index, not from the code.
- A comment you find is not a lock. Code comments kept creating fake locks
  (stale or over-general rules that steered later edits the wrong way). If a
  comment states a rule the code still follows and the docs do not have it,
  write the rule into the owning doc and delete the comment.
- Tests must not depend on comments: no assertion on comment text, and no
  comment used as an anchor in a test that reads source.

## Keep what tools read

These are not narrative; deleting them breaks a build, a lint or a guard:

- shebangs (`#!/usr/bin/env node`);
- SPDX / license headers, and third-party credit headers a license or a
  permission requires;
- compiler and linter directives: `@ts-expect-error`, `@ts-ignore`,
  `@ts-nocheck`, `@ts-check`, `/// <reference …>`, `eslint-disable*`,
  `/* global … */`, `prettier-ignore`, `@vitest-environment`,
  bundler hints (`/* @vite-ignore */`, `/* webpackIgnore: true */`,
  `/* turbopackIgnore: true */`, `/*#__PURE__*/`), Docker parser
  directives (`# syntax=`), JSDoc type tags in plain `.js` / `.mjs` files
  (`@type`, `@param {…}`, `@typedef`), and repo guard markers such as
  sume-com's `/* raw-colour: <reason> */` (read by `css-raw-colours.test.ts`).

A directive carries no narrative: `// @ts-expect-error`, not
`// @ts-expect-error — Chase lock: …`.

## sume-com

The repo-wide strip and the move of real locks into `docs/` is
sumelabs/sume-com job `comment-lock-strip`. The same rule is in the repo's
`AGENTS.md` (section "Code comments") and `.cursor/rules/no-code-comments.mdc`.
