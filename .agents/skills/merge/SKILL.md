---
name: merge
version: 1.0.0
description: |
  Review, fix, and merge multiple PRs in one shot. Deeply reviews each PR using the
  review checklist, resolves cross-PR conflicts, makes code production-ready, and
  squash-merges them in order. Invoke with PR numbers: `$merge 94 96 95`
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Agent
  - ask the user directly
---

# Merge: Multi-PR Review, Fix & Merge

You are running the `/merge` workflow. Given a list of PR numbers, deeply review each one, make them production-ready, resolve cross-PR conflicts, and merge them all.

Input: one or more PR numbers, e.g. `$merge 94 96 95`. If missing, ask for them.

Works with a single PR (`$merge 120`) or many. When only one PR is given, skip Step 3 (cross-PR compatibility).

**This workflow modifies code and merges PRs. It is NOT read-only.**

---

## Step 0: Gather PR metadata

For each PR number, fetch metadata in parallel:

```bash
gh pr view $PR_NUMBER --json number,title,body,additions,deletions,changedFiles,mergeable,state,headRefName,baseRefName
```

Output a summary table:

```
PR #  | Title                          | +/-        | Files | Mergeable | Branch
94    | fix: something                 | +32 / -8   | 3     | MERGEABLE | issue-94
96    | feat: new thing                | +180 / -12 | 7     | CONFLICTING | issue-96
95    | chore: cleanup                 | +15 / -40  | 4     | MERGEABLE | issue-95
```

**If any PR is CLOSED or MERGED:** Remove it from the list and note it. Continue with remaining PRs.

**If no valid PRs remain:** Stop.

---

## Step 1: Deep review (per PR)

For EACH PR, perform a full review:

1. Fetch the diff:
   ```bash
   gh pr diff $PR_NUMBER
   ```

2. Read `.agents/skills/review/checklist.md` (once — reuse across all PRs).

3. Apply the full two-pass review against the diff:
   - **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions, LLM Trust Boundary
   - **Pass 2 (INFORMATIONAL):** Conditional Side Effects, Magic Numbers, Dead Code, Prompt Issues, Test Gaps, Crypto, Time Safety, Type Coercion, Frontend

4. Additionally check for:
   - **Cross-PR conflicts:** Does this PR's change conflict with or duplicate logic from another PR in the batch?
   - **Missing tests:** Does the change warrant tests that aren't present?
   - **Type safety:** Does `npm run typecheck` pass with this change?
   - **Consistency:** Does the code follow existing patterns in the codebase?

5. Output findings per PR:
   ```
   ## PR #94: fix: something
   Pre-Landing Review: 2 issues (1 critical, 1 informational)

   **CRITICAL:**
   - [src/lib/foo.ts:42] SQL interpolation in query
     Fix: use parameterized binding

   **Issues:**
   - [src/lib/foo.ts:87] Magic number 3600
     Fix: extract to named constant
   ```

6. After reviewing ALL PRs, present the full findings table to the user. Use ask the user directly:
   - Show the review summary for all PRs
   - For each CRITICAL issue: problem, recommended fix, options (A: Fix it, B: Acknowledge, C: False positive)
   - **Wait for user confirmation before proceeding to Step 2.** The user may want to adjust scope, drop a PR, or change merge order.

---

## Step 2: Fix critical issues

For each PR with CRITICAL or HIGH issues:

1. Check out the PR branch:
   ```bash
   gh pr checkout $PR_NUMBER
   ```

2. Apply fixes for ALL critical issues found in Step 1.

3. Run typecheck:
   ```bash
   npx tsc --noEmit
   ```

4. Run tests:
   ```bash
   npm test
   ```

5. If tests or typecheck fail, fix until they pass.

6. Commit fixes:
   ```bash
   git add <fixed-files>
   git commit -m "$(cat <<'EOF'
fix: address review findings for PR #$PR_NUMBER

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
   git push
   ```

7. Switch back to main:
   ```bash
   git checkout main
   ```

**If only INFORMATIONAL issues:** Note them but do not block. They will be included in the merge summary.

---

## Step 3: Cross-PR compatibility check

After all individual PRs are fixed, check if they are compatible when combined:

1. Create a temporary integration branch:
   ```bash
   git fetch origin main
   git checkout -b merge-integration origin/main
   ```

2. Merge each PR branch sequentially into the integration branch to test compatibility:
   ```bash
   for each PR in order:
     git merge origin/$BRANCH_NAME --no-edit
     # If conflict: note it, abort, and handle in step 3
   ```

3. If conflicts exist between PRs:
   - Identify the conflicting files and lines
   - Determine the correct resolution (both changes should coexist, one supersedes the other, etc.)
   - Check out the conflicting PR, resolve the conflict, commit, and push
   - Report what was resolved

4. Clean up the integration branch:
   ```bash
   git checkout main
   git branch -D merge-integration
   ```

---

## Step 4: Final validation

Before merging, run one final validation pass on `main` with all PRs applied:

1. For each PR, verify it's still MERGEABLE:
   ```bash
   gh pr view $PR_NUMBER --json mergeable --jq '.mergeable'
   ```

2. If any PR became CONFLICTING after Step 2/3 fixes, rebase it:
   ```bash
   gh pr checkout $PR_NUMBER
   git fetch origin main
   git rebase origin/main
   # Resolve any conflicts
   git push --force-with-lease
   git checkout main
   ```

3. Run full test suite one final time on the latest state:
   ```bash
   npm test
   ```

---

## Step 5: Merge (sequential, in order)

Merge each PR in the order specified by the user:

```bash
for PR_NUMBER in $PR_NUMBERS:
  gh pr merge $PR_NUMBER --squash --delete-branch
  git pull origin main  # stay up to date for next merge
```

After each merge:
- Verify it succeeded (`gh pr view $PR_NUMBER --json state --jq '.state'` should be `MERGED`)
- If merge fails due to conflict from a previously merged PR:
  1. `gh pr checkout $PR_NUMBER`
  2. `git fetch origin main && git rebase origin/main`
  3. Resolve conflicts, `git push --force-with-lease`
  4. `git checkout main`
  5. Retry `gh pr merge $PR_NUMBER --squash --delete-branch`
- If merge fails for other reasons (CI checks, branch protection): report to user and stop

---

## Step 6: Post-merge validation

After all PRs are merged:

1. Pull the final state:
   ```bash
   git checkout main
   git pull origin main
   ```

2. Run typecheck and tests:
   ```bash
   npx tsc --noEmit
   npm test
   ```

3. If anything fails, report immediately — do NOT deploy.

---

## Step 7: Summary report

Output a final summary:

```
## Merge Complete

| PR | Title | Status | Review |
|----|-------|--------|--------|
| #94 | fix: something | MERGED | 1 critical (fixed), 1 info |
| #96 | feat: new thing | MERGED | Clean |
| #95 | chore: cleanup | MERGED | 2 info (noted) |

### Cross-PR Resolutions
- Resolved conflict between #94 and #96 in src/lib/payment.ts (both modified the provider check)

### Post-Merge Validation
- Typecheck: PASS
- Tests: 38/38 PASS

### Informational Findings (non-blocking)
- [#94] src/lib/foo.ts:87 — Magic number 3600 (extract to constant)
- [#95] src/lib/bar.ts:12 — Unused import (remove)
```

---

## Important Rules

- **Review depth matters.** This is not a rubber stamp — read every line of every diff. Catch real problems.
- **Fix before merge.** Never merge a PR with CRITICAL issues. Fix them first, push, then merge.
- **Order matters.** Merge in the user-specified order. Earlier PRs may affect later ones.
- **Never force push to main.** Only force-push feature branches during rebase.
- **Never deploy.** This workflow merges only. Deployment is a separate step.
- **Never skip tests.** If tests fail after merge, report and stop.
- **Be terse in output.** Show the table, findings, and PR URLs. No filler.
- **Preserve authorship.** Use `--squash` to keep clean history but credit the original author in the squash message.
