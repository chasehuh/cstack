---
name: generate-pr
description: |
  Generate a merge-ready PR from a GitHub issue. Reads the issue, explores relevant code,
  creates a worktree, implements the fix/feature, self-reviews, tests, and opens a PR.
  Invoke with issue number: `$generate-pr 39`
---

# Generate PR from Issue

Read a GitHub issue, implement the solution in an isolated worktree, and open a merge-ready PR.

Input: issue number, for example `$generate-pr 39`. If missing, ask for it.

## Step 0: Issue 파악

```bash
gh issue view $ISSUE_NUMBER
```

Extract from the issue:
- Goal: what needs to be done
- Acceptance criteria: what "done" looks like
- Constraints: what not to touch, caveats

Show a brief summary and ask the user to confirm direction once. If the user adjusts scope, incorporate it.

## Step 1: Codebase exploration

Search only files relevant to the issue scope. Do not read the entire codebase.

1. Grep or glob for keywords from the issue.
2. Read 2-5 key files.
3. List which files need changes and the approach.

## Step 2: Worktree creation

```bash
git fetch origin main
BRANCH="issue-${ISSUE_NUMBER}"
git worktree add /tmp/worktree-${ISSUE_NUMBER} -b "$BRANCH" origin/main
```

All file modifications happen inside `/tmp/worktree-${ISSUE_NUMBER}` only. Never modify the original worktree.

## Step 3: Implementation

Write code in the worktree.

Principles:
- Minimum changes to meet acceptance criteria
- Follow existing code style and patterns
- No unnecessary refactoring, comments, or type annotations
- Add or update tests if the project has test infrastructure

## Step 4: Complexity Guard + Review -> Fix Loop

First, check change size:

```bash
cd /tmp/worktree-${ISSUE_NUMBER}
git diff origin/main --stat
```

- 8+ files or 300+ lines changed: warn and verify issue scope is not exceeded. Revert unrelated changes before proceeding.
- Within scope: continue.

Read `.agents/skills/review/checklist.md` and run this loop until CRITICAL/HIGH count reaches 0.

1. `git diff origin/main` to see full changes
2. Run 4-pass review
   - Pass 1 (CRITICAL): Security & Data Safety
   - Pass 2 (HIGH): Code Quality & Performance
   - Pass 3 (MEDIUM): AI Slop & Maintainability
   - Pass 4 (LOW): Style & Test Gaps
3. Also verify acceptance criteria from the issue
4. If CRITICAL/HIGH found:
   - Fix the code immediately
   - Go back to the start of the loop
5. If only MEDIUM/LOW or no issues:
   - Exit loop

Maximum 5 iterations. If CRITICAL/HIGH remain after 5 rounds, report to the user and stop.

Record MEDIUM/LOW issues for the PR body.
Save full review history, including findings and fixes per iteration, for Step 7.

## Step 5: Tests

Run tests only if the project has test infrastructure.

```bash
# If package.json has test script
npm test 2>&1 | tail -30

# If vitest
npx vitest run 2>&1 | tail -30
```

Fix failures. Skip this step if no test infrastructure exists.

## Step 6: Commit & Push

```bash
cd /tmp/worktree-${ISSUE_NUMBER}

# Stage specific files only
git add <changed-files>

git commit -m "$(cat <<'EOF'
<type>: <summary> (#ISSUE_NUMBER)

<what changed and why, 1-2 lines>

Co-Authored-By: Codex <noreply@openai.com>
EOF
)"

git push -u origin "$BRANCH"
```

For large changesets, split into bisectable commits:
- Infrastructure or migrations first
- Models or services plus tests
- Controllers or views plus tests
- Each commit independently valid

## Step 7: Create PR

```bash
gh pr create --base main --head "$BRANCH" --title "<type>: <summary>" --body "$(cat <<'EOF'
Closes #ISSUE_NUMBER

## Summary
<bullet points: what changed and why>

## Changes
<per-file or per-module description>

## Self-Review
<Step 4 findings summary, or "No issues found.">

## Test Plan
<test results or manual verification steps>

🤖 Generated with Codex
EOF
)"
```

Use a heredoc or another shell-safe form for the PR body. Do not rely on raw backticks inside a quoted shell string.

## Step 8: Cleanup & report

```bash
git worktree remove /tmp/worktree-${ISSUE_NUMBER}
```

Final output:
- PR URL
- 1-3 line change summary
- Review result summary

## Rules

- User confirmation only at Step 0, once
- Never modify the original worktree
- Never force push
- Never work outside issue scope
- Never deploy
- Never run `wrangler deploy`
