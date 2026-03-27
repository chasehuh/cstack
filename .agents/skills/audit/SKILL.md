---
name: audit
version: 1.0.0
description: |
  Production readiness audit. Scans the codebase for security vulnerabilities,
  error handling gaps, race conditions, missing validation, and operational risks,
  then raises GitHub issues for each finding. Run with optional scope: `$audit`
  (full) or `$audit src/lib/payment.ts` (targeted).
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Agent
  - ask the user directly
---

# Audit: Production Readiness Review → Issues

You are running the `/audit` workflow. Systematically scan the codebase for production-readiness problems and raise a GitHub issue for each actionable finding.

Input: optional file or directory scope, e.g. `$audit src/lib/telegram.ts` or `$audit src/`. If omitted, audit the full `src/` directory.

**This workflow is read-only except for creating GitHub issues. It does NOT modify code.**

---

## Step 0: Scope & context

1. Determine the audit scope:
   - If a path was given: audit only that file/directory
   - If omitted: audit `src/` (the main application code)

2. Get a quick sense of the project:
   ```bash
   git log --oneline -10
   wc -l src/**/*.ts | tail -1
   ```

3. Read `CLAUDE.md` and any project-level configuration for deployment context (Cloudflare Workers, D1, R2, etc.).

---

## Step 1: Automated scans

Run these checks in parallel where possible:

### 1a. TypeScript strict-mode gaps
```bash
npx tsc --noEmit 2>&1 | head -50
```
Note any type errors — these are potential runtime failures.

### 1b. Dependency audit
```bash
npm audit --json 2>&1 | head -100
```
Note HIGH and CRITICAL vulnerabilities.

### 1c. Secrets in code
```bash
# Search for hardcoded secrets, tokens, keys
```
Use Grep for patterns: `(api_key|secret|token|password|credential)\s*[:=]\s*["'][^"']{8,}` across `src/`, `config/`, `wrangler.toml`. Exclude `.env*` and `node_modules`.

### 1d. SQL injection surface
Use Grep for string interpolation in SQL: `\$\{.*\}.*(?:SELECT|INSERT|UPDATE|DELETE|WHERE)` or `.prepare\(.*\+` or template literals near `.prepare(`.

---

## Step 2: Manual deep review

Read the code systematically. For each file in scope, check these categories:

### Security
- [ ] Input validation at system boundaries (webhooks, API routes, user input)
- [ ] SQL parameterization (no string interpolation in queries)
- [ ] Auth/authz checks on all protected routes
- [ ] Webhook signature verification (timing-safe comparison)
- [ ] Secrets not logged, not in error messages, not in client responses
- [ ] CORS / CSP headers where applicable
- [ ] Rate limiting on public endpoints

### Error handling & resilience
- [ ] External API calls have timeouts
- [ ] External API failures are caught and handled (not silently swallowed, not crashing)
- [ ] Retry logic has backoff and max attempts (no infinite retry loops)
- [ ] Database operations handle constraint violations
- [ ] Partial failure paths don't leave inconsistent state
- [ ] Error responses don't leak internal details (stack traces, SQL, env vars)

### Race conditions & data integrity
- [ ] Check-then-act patterns use atomic operations or transactions
- [ ] Concurrent writes to the same record are handled (upsert, optimistic locking)
- [ ] Idempotency on webhook handlers (dedup by event ID)
- [ ] Queue consumers handle duplicate delivery

### Operational risks
- [ ] No unbounded loops or recursion
- [ ] No unbounded memory growth (streaming large payloads, accumulating arrays)
- [ ] Cron jobs have execution time guards
- [ ] Logging is sufficient for debugging (but not excessive)
- [ ] Feature flags or kill switches for new/risky features

### Provider-specific (Cloudflare Workers)
- [ ] D1 queries within Worker CPU time limits
- [ ] R2 operations handle network failures
- [ ] Durable Object alarm handlers are idempotent
- [ ] KV reads handle eventual consistency

---

## Step 3: Classify findings

For each finding, classify severity:

| Severity | Criteria | Action |
|----------|----------|--------|
| **CRITICAL** | Exploitable security vulnerability, data loss risk, can crash production | Must fix before next deploy |
| **HIGH** | Race condition, missing auth check, silent data corruption | Should fix soon |
| **MEDIUM** | Missing error handling, no timeout on external call, logging gap | Fix in next sprint |
| **LOW** | Code smell, missing validation on internal boundary, minor inconsistency | Nice to have |

---

## Step 4: Group findings into PR-sized issues

Before presenting to the user, **group related findings into coherent, PR-sized issues**. Each issue should represent a single `$generate-pr` run — roughly 1-8 files, under 300 lines changed.

Grouping rules:
- **Same root cause** → one issue (e.g., 5 endpoints all missing input validation → "Add input validation to public webhook handlers")
- **Same file/module** → prefer grouping (e.g., 3 findings in `telegram.ts` → one issue for that module)
- **Same category across files** → group if the fix is mechanical (e.g., "Add timeouts to all external API calls in src/lib/")
- **Unrelated CRITICAL findings** → keep separate (each needs its own focused PR)

Aim for **3-8 issues** from a full audit, not 20+ micro-issues.

---

## Step 5: Present findings to user

Output a summary table:

```
## Audit Results: N findings → M issues proposed

| Issue | Severity | Scope | Findings | Description |
|-------|----------|-------|----------|-------------|
| 1     | CRITICAL | src/lib/payment.ts, src/routes/public.ts | 3 | Stripe webhook lacks idempotency and error isolation |
| 2     | HIGH     | src/lib/telegram.ts, src/lib/messaging.ts | 2 | Missing timeouts on Telegram Bot API calls |
| 3     | MEDIUM   | src/do/chat-coordinator/ | 4 | Race conditions in concurrent ingest handling |
```

Then use ask the user directly:
- Show all proposed issues with their grouped findings
- Ask: "Which issues should I create? Options: A) All, B) CRITICAL+HIGH only, C) Let me pick, D) None"
- Wait for user response before creating any issues

---

## Step 6: Raise GitHub issues

For each approved issue, create a comprehensive, implementation-ready GitHub issue:

```bash
gh issue create --title "$SEVERITY: $DESCRIPTIVE_TITLE" --body "$(cat <<'EOF'
## Summary
$ONE_TO_THREE_SENTENCE_OVERVIEW of what needs to be fixed and why.

## Findings

### Finding 1: $PROBLEM_TITLE
**Location:** `$FILE:$LINE`
**Risk:** $WHAT_CAN_GO_WRONG_IN_PRODUCTION

```$LANGUAGE
$PROBLEMATIC_CODE (5-10 lines)
```

### Finding 2: $PROBLEM_TITLE
(repeat for each finding in this group)

## Current Behavior
$WHAT_HAPPENS_NOW — the vulnerable/broken behavior.

## Desired Behavior
$WHAT_SHOULD_HAPPEN — the correct, hardened behavior.

## Implementation Notes

### Files to modify
- `$FILE_1` — $WHAT_TO_CHANGE
- `$FILE_2` — $WHAT_TO_CHANGE

### Suggested fixes

```$LANGUAGE
$FIX_CODE_SNIPPET_1
```

```$LANGUAGE
$FIX_CODE_SNIPPET_2
```

### Edge cases
- $EDGE_CASE_1
- $EDGE_CASE_2

## Acceptance Criteria
- [ ] $CRITERION_1
- [ ] $CRITERION_2
- [ ] No regression to existing behavior
- [ ] Tests added/updated for the fix

## Severity
$HIGHEST_SEVERITY_IN_GROUP — $JUSTIFICATION
EOF
)"
```

Each issue should be:
- **PR-sized** — can be implemented in a single `$generate-pr` run (1-8 files, < 300 lines)
- **Self-contained** — includes all context needed to implement the fix
- **Implementation-ready** — file paths, code snippets, suggested fixes, acceptance criteria

---

## Step 8: Summary report

Output:
```
## Audit Complete

Scope: $SCOPE
Files scanned: N
Findings: X total (A critical, B high, C medium, D low)
Issues created: Y (grouped from X findings)

| Issue | Severity | Title | Findings |
|-------|----------|-------|----------|
| #121  | CRITICAL | Stripe webhook hardening | 3 |
| #122  | HIGH     | External API timeout coverage | 2 |
| #123  | MEDIUM   | Ingest race condition fixes | 4 |

Run `$generate-pr 121` to start implementing.
```

---

## Important Rules

- **Read-only.** Do not modify any code. Only create GitHub issues.
- **Be precise.** Every finding must cite `file:line` and show the actual problematic code.
- **No false positives.** Only flag real, exploitable, or likely-to-cause-production-issues problems. If you're unsure, classify as LOW and note the uncertainty.
- **No duplicates.** Before creating an issue, check if an open issue already covers the same finding: `gh issue list --state open --search "$KEYWORDS" --limit 5`.
- **Respect suppressions.** Read `.agents/skills/review/checklist.md` suppressions section — do not flag suppressed patterns.
- **Context matters.** A missing timeout on an internal D1 query is LOW. A missing timeout on an external LLM API call is HIGH. Judge by blast radius.
- **Never deploy. Never modify code.**
