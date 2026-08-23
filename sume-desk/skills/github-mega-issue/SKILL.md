---
name: github-mega-issue
description: Draft and optionally create high-context, implementation-ready GitHub issues. Use when the user wants the kind of long, detailed issue that includes conversation context, source-of-truth docs, OpenAPI/schema excerpts, current repo behavior, proposed API shape, risks, acceptance criteria, QA plan, and enough detail for a context-free coding agent to implement end to end.
---

# GitHub Mega Issue

Use this skill when a normal GitHub issue would be too thin. The goal is to
produce a self-contained implementation brief that another agent can pick up
without reading the original conversation.

For smaller issues, prefer `$propose`. Use this skill when the user explicitly
wants "엄청 해상도 높게", "가능한 최대한 많은 컨텍스트", "source of truth",
"OpenAPI/schema까지", "대화 맥락까지", or a similar high-context issue.

## Workflow

1. Resolve the target repository.
   - Run `gh repo view --json nameWithOwner,url,defaultBranchRef`.
   - If outside a repo or the repo is ambiguous, ask which GitHub repo to use.

2. Gather implementation context before writing.
   - Read repo guidance: `AGENTS.md`, `README.md`, docs, and existing API docs.
   - Search for current routes, schemas, model ids, provider wrappers, workers,
     jobs, tests, UI surfaces, and prior issues.
   - For external systems, use source-of-truth docs whenever available:
     official docs, OpenAPI files, SDK types, copied schema examples, or local
     source code from cloned repos.
   - If the request references a previous conversation, include the actionable
     context in the issue rather than assuming future agents can see it.

3. Decide whether one issue is enough.
   - Keep one issue when the work is one coherent implementation path.
   - Split when the work crosses independent surfaces, requires risky migration
     plus product behavior, or would create a PR too large to review.
   - Ask before creating multiple issues unless the user already requested a
     multi-issue plan.

4. Draft the issue using `references/issue-template.md`.
   - Include exact file paths and likely functions/routes where possible.
   - Include concrete request/response schemas, not just prose.
   - Quote or paraphrase enough source-of-truth detail to remove ambiguity.
   - Mark uncertain details clearly as "Needs verification" rather than hiding
     uncertainty.
   - Include non-goals so implementers do not expand scope.

5. Review the draft before creating the issue.
   - Check that a context-free agent can answer:
     - What problem is being solved?
     - Why does it matter?
     - What exists today?
     - What exact behavior/API/schema should exist?
     - Which files and tests are likely involved?
     - How will success be verified?
   - Remove filler. Length is acceptable only when it carries useful context.

6. Check for duplicate issues.
   ```bash
   gh issue list --state all --search "<keywords>" --limit 20
   ```

7. Create only after approval or when the user explicitly told you to create it.
   ```bash
   gh issue create --title "$TITLE" --body-file /tmp/issue.md
   ```

8. Report the created issue URL and suggested next action.
   - If the issue is implementation-ready, say which agent/skill should handle
     it next, usually `$worktree-task` or `$generate-pr`.

## Model Routing (Sume main-agent flow)

When this skill runs inside the Sume main-agent orchestration flow, follow
`sume-main-agent-orchestration` § "Coding Worker Model Routing":

- Heavy / ambiguous work: **Opus** drafts this mega-issue (design + RCA)
  via `claude-human-stream` (not Cursor `Task` Opus) and implements through
  MQ enqueue. After enqueue, **Grok Build** lands via
  `agent-human-stream --backend grok` (not Cursor `Task`).
- Clear / well-scoped work Chase assigned to Grok: **Grok Build**
  (`agent-human-stream --backend grok`) may write the mega-issue and implement.
- Composer must not write issues (exploration only).
- Full routing/transport SoT:
  `~/.agents/skills/sume-main-agent-orchestration/SKILL.md`

## Quality Bar

The issue should be closer to a compact technical design doc than a TODO.

Required:
- Clear title with the product/API surface named.
- Summary and why now.
- Current behavior and desired behavior.
- Source-of-truth evidence with links or file paths.
- Existing repo code paths with exact paths.
- Proposed API/schema/data model shape.
- Implementation notes detailed enough to start coding.
- Acceptance criteria and verification plan.
- Risks, edge cases, backward compatibility, and non-goals.

Avoid:
- Vague "integrate X" language without exact entry points.
- Unlinked references to "as discussed".
- Copying huge docs verbatim when a schema excerpt and link would do.
- Mixing unrelated feature requests into one issue.
- Creating the issue before the user has seen the draft unless explicitly asked.

## References

Read `references/issue-template.md` when drafting a new issue body.
