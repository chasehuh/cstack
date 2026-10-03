---
name: sume-principles
description: >-
  Engineering principles for Sume desk work, vendored from pstack: laziness
  protocol, foundational thinking, prove it works, fix root causes, explain
  the number, boundary and type-system discipline, and 17 more. Use when
  Chase or a prompt names a principle ("apply prove it works", "subtract
  before you add"), when sume-architect or sume-blast-radius cites one, or
  before you report a number you measured.
---

# Sume principles

Twenty-four short engineering rules, one file each under `references/`,
vendored from pstack (MIT, Lauren Tan). Provenance, upstream pin, and resync:
`docs/PSTACK.md` in chasehuh/cstack.

They steer **how** you build. They do not change who builds, where, or at
what effort: roles, routing, transport, effort lanes, Graphite, land, and
dest evidence stay in `sume-main-agent-orchestration` and `sume-gt-mq`.

## Use

- Read the leaf `references/<name>.md` in full before you apply a principle.
  The index line below is a trigger, not the rule.
- When a principle changes a decision, name both in the PR body or final
  report ("subtract-before-you-add: deleted the old adapter before adding
  the new one"). Cite only leaves you read this session. A citation with no
  decision behind it is name-dropping.
- A principle name from Chase or the main agent is a steer. "Apply prove it
  works" means read `references/prove-it-works.md`, then redo the check
  against the real artifact.

## Index

**Core**

- `laziness-protocol`. Refactoring, sizing a diff, tempted to add layers or thread a new signal. Bias to deletion and the smallest change that solves it.
- `foundational-thinking`. Before writing logic. Core types and data structures first, scaffold before features, ask what concurrent actors share.
- `redesign-from-first-principles`. Integrating a new requirement. Redesign as if it had been there from day one instead of bolting it on.
- `attack-the-premise`. Two or more fixes sharing one premise failed the same gate. Write the premise down, census who holds the imbalance, then question the premise.
- `subtract-before-you-add`. Sequencing an addition, refactor, or rewrite. Remove dead weight first, build on the simpler base.
- `minimize-reader-load`. Code that is hard to trace. Count layers and hidden state, collapse one-caller wrappers, shrink mutable scope.
- `outcome-oriented-execution`. Planned rewrites and migrations. Converge on the target design, no throwaway compatibility states.
- `experience-first`. Product, UX, or scope tradeoffs. The user's result over implementation convenience.
- `exhaust-the-design-space`. A novel interaction or architecture with no precedent. Build 2-3 competing shapes and compare before committing.
- `build-the-lever`. Any non-trivial work. Build the script, codemod, or check that does or proves it, so a reviewer can rerun it.

**Architecture**

- `model-the-domain`. Stateful logic, heavy branching, a shape assumption repeated across files. Encode it in one structure (state machine, typed model, table, reducer).
- `boundary-discipline`. Validation, error handling, adapters. Guards at system boundaries, trusted types inside, pure business logic.
- `type-system-discipline`. Designing types or signatures. Illegal states unrepresentable, branded primitives, parse external data at the boundary.
- `make-operations-idempotent`. Commands, lifecycle steps, loops that crash and retry. Converge to the same end state.
- `migrate-callers-then-delete-legacy-apis`. A new internal API with old callers. Migrate and delete in one wave.
- `separate-before-serializing-shared-state`. Concurrent actors might write the same file, branch, key, or row. Remove the sharing first.

**Verification**

- `prove-it-works`. Before declaring done. Check the real artifact, not a proxy, a self-report, or "it compiles".
- `fix-root-causes`. Debugging. Reproduce first, ask why until the root, no guards that silence the symptom.
- `sequence-verifiable-units`. Multi-step work and how commits and PRs stack. Small units that each end in a check, ordered so the sequence proves itself.
- `test-behavior-not-implementation`. Writing or keeping a test. Call the code like its users and assert a literal result. A test that passes when every import returns `undefined` gets rewritten or deleted.
- `explain-the-number`. Before you trust, report, or act on a measured number. Name the limiter and rule out that it measured something else. Full procedure: `references/benchmark-checklist.md`.

**Delegation**

- `guard-the-context-window`. Large outputs, long files, fan-out planning. Bulk goes to subagents, summaries stay in the main thread.
- `never-block-on-the-human`. Tempted to ask "should I do X?" on reversible work. Proceed, show the result, let the human correct it.

**Meta**

- `encode-lessons-in-structure`. The same correction a second time. Make it a lint, check, script, or skill edit instead of more text.

## On this desk

Where a principle meets a desk lock, the lock wins and the principle reads
like this:

- `prove-it-works`. Done means `origin/main` has `(#N)`, plus `SHOTS:` when
  dest browser verify is in scope. A green PR check, an enqueue, or a
  worker's own summary is a proxy.
- `never-block-on-the-human`. A worker session never stops to ask. It takes
  the smaller reversible option and says so in its report. Irreversible here
  also covers prod data and deploys, paid provider calls, customer
  workspaces, and destructive verification (send, delete, pay). Those need
  the explicit authorization that orchestration § Workers / Subagents and
  § Browser verification describe, never a guess.
- `guard-the-context-window`. From a worker, a subagent means an
  in-process one (Claude Code Agent or Explore). Never `sume-bg-launch`,
  `agent-human-stream`, `claude-human-stream`, or a bare `claude -p` /
  `codex exec` / `grok -p` from a worker (sume#7839). From a Cursor main
  agent, in-process means Composer `Task` explore only, never `Task` with
  `claude-opus-*` or `cursor-grok-*`.
- `separate-before-serializing-shared-state`. One `cstack-clone` per job.
  Never `git worktree` under a shared checkout for `gt` (#2383).
- `outcome-oriented-execution`. Planned breakage stays inside a branch or a
  Graphite train. Every PR that lands passes MQ CI.
- `explain-the-number`. TTFT, latency, cost, and CI-minute numbers in a
  report carry the run count, the spread, and the limiter.
  `benchmark-checklist.md` names Linux tools. On the Macs use
  `sysctl -n hw.ncpu` for `nproc`, and `top` or `sample <pid>` for
  `pidstat` and `strace`.
- `encode-lessons-in-structure`. A Chase correction that recurs becomes a
  script, check, or skill edit in cstack, not only a chat promise or a
  memory note.

The leaves keep pstack's wording. Names they mention that this desk does not
ship (`show-me-your-work`, `typescript-best-practices`, the "brain note",
and the poteto-mode playbooks such as Perf issue, Hillclimb, and Opening a
PR) live in upstream pstack. Here the Job issue, the PR body, the final
report, and cstack skill edits carry that evidence.
