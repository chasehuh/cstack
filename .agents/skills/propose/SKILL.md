---
name: propose
version: 1.0.0
description: |
  Propose a new feature as a well-scoped GitHub issue. Takes a user's rough idea or context,
  explores the codebase to understand feasibility and integration points, then raises a
  detailed implementation-ready issue. Invoke with context: `$propose add webchat typing indicators`
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Agent
  - ask the user directly
---

# Propose: Feature Idea → GitHub Issue

You are running the `/propose` workflow. Take the user's rough feature idea, research the codebase to understand what's needed, and create a well-scoped GitHub issue that's ready for implementation.

Input: a feature description in natural language, e.g. `$propose add typing indicators to webchat` or `$propose Telegram should split messages into multiple bubbles like iMessage`. If missing, ask the user to describe what they want.

**This workflow is read-only except for creating one GitHub issue. It does NOT modify code.**

---

## Step 0: Understand the request

Parse the user's input to extract:
- **What** they want (the feature)
- **Why** they want it (if stated — often implicit)
- **Where** it should apply (if stated — often needs discovery)

If the request is ambiguous or too broad, use ask the user directly to clarify before proceeding. Ask at most one clarifying question — don't interrogate. If you can make a reasonable assumption, state it and proceed.

---

## Step 1: Codebase research

Explore the codebase to understand how the feature fits. This is the most important step — the issue quality depends on understanding the existing architecture.

1. **Find related code.** Grep/glob for keywords from the feature request. Read 3-8 key files.

2. **Map the current flow.** Understand how the existing system works in the area the feature touches. Trace the data flow end-to-end.

3. **Identify integration points.** Which files, functions, types, and database tables need to change?

4. **Check for prior art.** Is there a similar feature for another provider/channel that can be referenced? (e.g., "iMessage already does X, Telegram needs the same")

5. **Spot blockers.** Are there architectural constraints, missing infrastructure, or prerequisites that need to happen first?

Use the Agent tool with Explore subagent for broad codebase searches. Use Grep/Glob directly for targeted lookups.

---

## Step 2: Design the solution

Based on codebase research, design a concrete implementation approach:

1. **Files to touch** — list every file that needs changes, with a brief description of what changes.

2. **New files needed** — if any new files are required, describe their purpose.

3. **Data model changes** — any new D1 tables, columns, KV keys, R2 objects.

4. **API/route changes** — new endpoints, webhook modifications, env vars.

5. **Migration path** — can this be shipped incrementally? Does it need a feature flag? Is there a backward-compatible path?

6. **Edge cases** — what could go wrong? What happens when the external service is down? What about existing users?

---

## Step 3: Scope to PR-sized issues

Each issue should be implementable in a single `$generate-pr` run: roughly 1-8 files, under 300 lines changed.

Classify the feature:

| Size | Criteria | Action |
|------|----------|--------|
| **Single PR** | 1-8 files, < 300 lines, no complex migrations | Create one issue |
| **Multi PR** | 8+ files, 300+ lines, or needs sequential steps | Break into ordered issues |

**If multi-PR**: Split into a sequence of issues that can be implemented one at a time. Each issue should be independently shippable (no broken intermediate states). Number them clearly: "Part 1/3: Extract username from webhook", "Part 2/3: Update checkout flow", "Part 3/3: Add post-payment routing".

Use ask the user directly to confirm the split before creating issues.

---

## Step 4: Draft the issue

Compose a comprehensive GitHub issue. Use ask the user directly to present the draft and get approval before creating:

Show the full issue body and ask: "Does this look right? I can adjust scope, add/remove sections, or change the approach before creating the issue."

---

## Step 5: Create the issue

```bash
gh issue create --title "$TITLE" --body "$(cat <<'EOF'
## Summary
$ONE_TO_THREE_SENTENCE_DESCRIPTION

## Context
$WHY_THIS_IS_NEEDED — user impact, current limitation, or motivation.
$PRIOR_ART_REFERENCE if applicable (e.g., "iMessage already does this via X")

## Current Behavior
$WHAT_HAPPENS_NOW — brief description of the current state.

## Desired Behavior
$WHAT_SHOULD_HAPPEN — concrete description of the end state.

## Implementation Notes

### Files to modify
$FILE_LIST_WITH_DESCRIPTIONS
- `src/lib/foo.ts` — Add X to handle Y
- `src/lib/bar.ts` — Update Z to support W

### New files (if any)
- `src/lib/baz.ts` — New module for Q

### Data model changes (if any)
- Add column `xyz` to `table_name`
- New KV key pattern: `prefix:{id}`

### Key code paths
$TRACE_OF_THE_RELEVANT_FLOW
1. Request arrives at X
2. Handler calls Y
3. Y reads from Z
4. Change needed at step 3: also do W

### Edge cases
- $EDGE_CASE_1
- $EDGE_CASE_2

### Prerequisites (if any)
- $DEPENDENCY_OR_BLOCKER

## Acceptance Criteria
- [ ] $CRITERION_1
- [ ] $CRITERION_2
- [ ] $CRITERION_3
- [ ] No regression to existing $RELATED_FEATURE behavior

## Size
$SIZE_LABEL (S/M/L)
EOF
)"
```

---

## Step 6: Report

Output:
```
## Feature Proposed

| Issue | Title | Size | Dependencies |
|-------|-------|------|-------------|
| #125  | Extract Telegram username from webhook | Single PR | None |
| #126  | Update Stripe checkout for Telegram handle | Single PR | #125 |

Run `$generate-pr 125` to start implementing.
```

---

## Important Rules

- **Research first, write second.** The issue quality is proportional to how well you understand the codebase. Never propose changes to code you haven't read.
- **Be concrete.** "Update the messaging layer" is bad. "Add `telegram` case to `splitMessageBubbles()` in `src/do/chat-coordinator/shared.ts:465`" is good.
- **PR-sized issues.** Each issue = one `$generate-pr` run (1-8 files, < 300 lines). If the feature is bigger, split into ordered issues.
- **Don't over-scope.** The user said "add typing indicators" — don't also propose message read receipts, online status, and a presence system.
- **Don't under-scope.** If the feature obviously requires a DB migration and the user didn't mention it, include it.
- **Reference existing patterns.** If the codebase already solves a similar problem for another provider, reference it. "Follow the same pattern as `linqShareContactCard()` in `src/lib/linq.ts:162`."
- **User approval required.** Always show the draft before creating the issue. The user may want to adjust scope or wording.
- **Never deploy. Never modify code.**
