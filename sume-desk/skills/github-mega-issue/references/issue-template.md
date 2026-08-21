# Mega GitHub Issue Template

Use this as a starting point. Delete sections that truly do not apply, but keep
the issue self-contained.

```markdown
## Summary

<1-3 sentences describing the requested change and the user/product outcome.>

## Why This Matters

<Business/product/agent-workflow reason. Explain why this is worth doing now.>

## Conversation Context

<Condense the relevant user discussion. Include decisions, preferences, and
constraints that would otherwise be lost. Do not include unrelated chat history.>

## Current Behavior

<What exists today. Include exact endpoints, UI flows, worker stages, helper
scripts, schema fields, or limitations.>

## Desired Behavior

<What should exist after the issue is implemented. Be concrete and observable.>

## Source Of Truth

### Internal repo/source

- `path/to/file.ts` - <why it matters>
- `path/to/schema.ts` - <exact schema or behavior to preserve/change>

### External docs/source

- <Official docs URL or local cloned repo path> - <specific relevant detail>
- <OpenAPI/schema/source file> - <specific fields/endpoints>

## Proposed API / Schema

### Request

```json
{
  "field": "example"
}
```

### Response

```json
{
  "id": "example",
  "status": "queued"
}
```

### Validation Rules

- `<field>` is required because...
- `<field>` must not be accepted because...
- Backward compatibility: <existing clients/routes remain valid or not>.

## Implementation Notes

### Likely files to modify

- `path/to/file.ext` - <specific change>
- `path/to/another.ext` - <specific change>

### New files

- `path/to/new-file.ext` - <purpose>

### Flow

1. <Entry point: route/UI/CLI/job/webhook>
2. <Domain/service logic>
3. <Persistence/external provider/worker behavior>
4. <Readback/API/UI response>

### Tests

- `path/to/test.ext` - <test case>
- Add coverage for <edge case>.

## Edge Cases And Risks

- <Security/privacy/billing/tenant isolation risk>
- <Provider failure/rate limit/timeout risk>
- <Backward compatibility risk>
- <Data migration or stale data risk>

## Non-Goals

- <Explicitly out of scope>
- <Adjacent feature to avoid implementing in this issue>

## Acceptance Criteria

- [ ] <Observable behavior or API response>
- [ ] <Validation/error behavior>
- [ ] <Readback/UI/worker behavior>
- [ ] <Tests pass>
- [ ] <Docs/OpenAPI updated if applicable>

## QA Plan

1. <Local/unit test command>
2. <API smoke test command or curl>
3. <Production/staging verification if applicable>

## Suggested PR Scope

<S/M/L. State whether this should be one PR or split. If split, list order.>
```
