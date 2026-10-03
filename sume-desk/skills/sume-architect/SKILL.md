---
name: sume-architect
description: >-
  Shape the caller's usage, types, signatures, and module boundaries before
  writing code, design it twice, record the rationale where Chase reads work,
  then implement against the chosen sketch and scrap it when implementation
  proves it wrong. Use for /sume-architect, "architect this", "design this
  first", Pipeline 1 design, a new API or data model, or a change that
  crosses a module or package boundary where jumping to code would lock in
  the wrong shape. Skip one-file mechanical edits.
---

# Sume architect

Adapted from pstack `architect` (MIT, Lauren Tan; `docs/PSTACK.md` in
chasehuh/cstack). Write the caller's usage first, derive types and signatures
from it with `not implemented` bodies, compare at least two structurally
different shapes, then fill in code against the one you chose.

This skill decides the shape of the code. Roles, routing, transport, effort
lanes, Graphite, land, and dest evidence stay in
`sume-main-agent-orchestration` and `sume-gt-mq`. Principles cited below
live in `~/.agents/skills/sume-principles/references/<name>.md`. Read a leaf
before you cite it.

Track five phases: Ground, Sketch, Record, Implement, Scrap.

## Phase A: Ground

Build a real model of every system the new code touches. Read `origin/main`
in your own clone (`cstack-clone <slug>` for sume-com), never a dirty shared
checkout.

For each touched subsystem, write down:

1. The entry point (route, job, tool call, UI action) and the flow from it.
2. The core types and where they are defined.
3. The boundaries. What comes in, what goes out, and who else reads it:
   other packages, the web client, workers, the DB, external APIs.
4. Anything surprising or historical.

When the design changes ownership or layering, learn why the current shape
exists, so the reason becomes a constraint instead of a guess:
`git log --follow -- <file>`, `git blame -L <a>,<b> <file>`, and
`gh pr view <N> --json title,body,comments,reviews` for the PRs that shaped
it. Read the Job issue and the issues it links.

For a large area, give each angle to a read-only in-process subagent
(Claude Code Explore or Agent) and keep only its findings. A worker never
launches nested workers: no `sume-bg-launch`, `agent-human-stream`,
`claude-human-stream`, or bare `claude -p` / `codex exec` / `grok -p`
(sume#7839). A Cursor main agent explores with Composer `Task` only, never
`Task` with `claude-opus-*` or `cursor-grok-*`, and hands the design itself
to the author worker.

Skip this phase only for greenfield code with nothing to integrate.

## Phase B: Sketch

1. **Usage first.** Write what the caller reads (README, quickstart, or API
   example) and two or three real call sites. Derive the type sketch from
   it. When the two disagree, change the sketch, not the usage.
2. **Data structures first.** Trace each dominant access pattern through the
   proposed types. "We'll add an index or cache later" means the structure
   is wrong (`foundational-thinking`).
3. **Design it twice.** Produce at least two structurally different
   candidates, whole shapes rather than tweaks of one shape, even when the
   first looks fine (`exhaust-the-design-space`). Draft them yourself, or
   give each to an in-process subagent with `references/candidate-prompt.md`,
   the Phase A notes, and its own scratch dir
   (`/tmp/architect-<slug>/candidate-<n>/`).
4. **Screen** every candidate against `references/design-red-flags.md`:
   shallow module, information leakage, temporal decomposition, pass-through
   method. Revise or reject.
5. **Pick a base on interface depth.** Prefer the shape that hides more
   behind a smaller public surface and that a maintainer can extend without
   breaking invariants. When two feel tied, take the smaller API
   (`laziness-protocol`). Graft the one or two best ideas from the others by
   hand so the result keeps one mental model. If every candidate converged,
   say so and ship that shape. If they diverged wildly, the problem is
   under-specified, so go back to Phase A.

Shared state between actors defaults to per-actor state merged at the read
boundary (`separate-before-serializing-shared-state`). Guards sit at
boundaries and business logic stays pure (`boundary-discipline`). State
transitions survive a rerun or a crash halfway (`make-operations-idempotent`).

One-way doors (DB schema, public API shape, billing) earn an independent
second design pass before implementation starts. A worker gets it from an
in-process subagent that reviews the chosen sketch cold, before Phase D. A
cross-family pass is the main agent's call: it runs before the author starts
coding, through the normal transport, with efforts from orchestration
§ Worker reasoning effort.

## Phase C: Record

Write the rationale with `references/rationale-template.md`. Put it where
Chase reads work: the mega-issue's `Proposed API / Schema` and
`Implementation Notes` sections when you are drafting it, otherwise one
comment on the Job issue. The PR body links it. A small change can keep the
rationale in the PR body alone.

The type sketch can be its own first commit, or the bottom PR of a Graphite
stack when it is green under MQ CI on its own: scaffold before fill-in
(`foundational-thinking`). Planned, scoped breakage while filling it in is
fine inside the branch (`outcome-oriented-execution`).

Default is no checkpoint: record, then implement. Stop for sign-off only
when Chase asked ("show me the design first", "설계 먼저 보여줘"). If Chase
pushes back on the shape at any point, treat it as Phase A evidence and redo
Phase B before writing more code.

## Phase D: Implement against the sketch

Replace `not implemented` bodies with code and pseudocode with logic. The
sketch is the contract. A deviation, such as a parameter nobody planned for
or a type that only compiles with a cast, is a finding. Decide whether the
sketch was wrong, a requirement was missed, or the code is overreaching, and
note each deviation in the PR body.

## Phase E: Scrap when the shape is wrong

The signal is a pattern, not one awkward spot:

- The same workaround shape in unrelated places.
- Several unrelated edge cases that each need a special branch.
- Types that only compile with `any`, casts, or optional fields that are
  always set in practice.
- A "we need a lock" reflex where the sketch said state was not shared.
- Callers that must know the abstraction's internal rules.
- Two or more Phase D deviations of the same shape.

Complexity in the data is not complexity in the design, and a few edge cases
do not condemn a shape. When you scrap, re-ground on what you built, redesign
as if the new constraints were day-one assumptions
(`redesign-from-first-principles`), make the new sketch smaller than the old
one before it grows (`subtract-before-you-add`), and return to Phase B.

## Outputs

- The usage sketch, written first.
- The type sketch. One file of types and signatures for a small change, a
  module map plus types for larger work.
- The rationale from Phase C, naming the base, the grafts, and the shapes
  that lost.
