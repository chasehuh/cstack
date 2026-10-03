# Candidate prompt

Give this to each in-process subagent that drafts one design candidate in
Phase B. Fill in the task, the Phase A notes (paths or pasted text), and the
candidate's own output dir. Adapted from pstack `architect` (MIT).

---

You are drafting one candidate design for a change in <repo>. Read
`~/.agents/skills/sume-architect/SKILL.md` first. You are inside its Phase B.
Do not edit the repo and do not write production code. Write your candidate
to <output dir>: a usage sketch, a type sketch with signatures and
`not implemented` bodies, a module map when more than one file changes, and
a short rationale shaped like `references/rationale-template.md` (skip its
Synthesis decision section).

Apply this discipline. Candidates are compared on it.

- Caller's usage first. Write the README-style usage and two or three real
  call sites before the types, then derive the type sketch from them. The
  usage is the spec. When the two disagree, change the sketch.
- Data structures first. Trace each dominant access pattern through the
  proposed structure. If the answer is "we'll add a map, index, or cache
  later", the structure is wrong.
- Interface depth. Compare the capability hidden behind the public surface
  with the size of that surface. Prefer a simple interface that pulls
  complexity into the callee. Keep transport and wire types off the public
  API. Parse into domain types behind the interface.
- Shared state. If two actors might both write, ask what happens. If the
  answer isn't "nothing", default to per-actor state merged at the read
  boundary.
- Visible boundaries. `not implemented` bodies, `// TODO` pseudocode for
  tricky logic, doc comments for intent and invariants. A reader should
  trace data from input to output through types and signatures alone.
- Invariants in types first, runtime checks second, prose comments last.
- Validate at boundaries, trust types inside. Business logic as pure
  functions, a thin shell around them.
- One source of truth per invariant. Derive instead of sync.
- Idempotent state transitions. Ask what happens if the operation runs
  twice or crashes halfway.
- Short call chains. If tracing the flow takes more than three files,
  flatten it.

The principles behind these rules are in
`~/.agents/skills/sume-principles/references/`.

You are one of several candidates working from the same notes. Make the
best design you can and do not hedge toward a safe middle. The differences
between candidates are the signal used to pick a base and graft.
