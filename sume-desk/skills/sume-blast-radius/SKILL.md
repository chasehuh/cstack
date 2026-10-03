---
name: sume-blast-radius
description: >-
  Find what a change could break outside its own diff, and prove the one fact
  it is safe because of by running real code instead of writing a convincing
  paragraph. Use for /sume-blast-radius, "what could this break", "blast
  radius of X", a small diff you do not trust, or before submitting a fix
  that touches shared types, API or stream payloads, DB columns, flags, env
  config that differs between dest and prod, or billing.
---

# Sume blast radius

Adapted from pstack `blast-radius` (MIT, Lauren Tan; `docs/PSTACK.md` in
chasehuh/cstack). Listing the callers is not the job. Grep does that in a
second. The job is the breakage grep will not show you, plus proof that the
change is safe.

## Do not trust your own writeup

A blast-radius writeup that sounds right reads the same whether or not it is
true. Find the one or two facts the change's safety depends on and prove
them by running code.

### How sure are you

For each fact the change's safety depends on, get it as far down this list
as is cheap, and say where it stopped.

1. You said so. Worthless on its own.
2. You pointed at the line. A real `file:line` on `origin/main`, or the
   library's own source at the pinned version.
3. You showed the bad case can't happen. You walked the failure step by step
   and it doesn't reach.
4. You ran it. A script or test that calls the real code and fails loudly if
   you are wrong.
5. You reproduced it in the running app, locally first, then on dest under
   the orchestration skill's browser-verify rules.

Level 4 is usually one small script in your clone that imports the module
the app ships and calls the exact function you are worried about
(`pnpm tsx <script>`, `node <script>`, or `vitest run <file>` in the owning
package).

## Steps

1. **Read the change.** The diff, the symbols it adds, changes, and deletes,
   and what it now does differently, including the part the diff doesn't
   spell out. Pull its history with `git log --oneline -20 -- <file>`,
   `git blame -L <a>,<b> <file>`, and
   `gh pr view <N> --json title,body,comments,reviews`.
2. **Find the one fact it is safe because of.** Most changes that look risky
   are safe because of a single fact, such as "this call only drops cache
   entries that are already dead". If that fact holds, most of the risky
   cases clear at once. Spend your time here, not on a long list of maybes.
3. **Look where grep stops.** Read the source of the library you call at its
   pinned version, plus any local patch. Work out when things run:
   microtasks, retries, teardown, a job resumed after a crash. Follow what a
   symbol search misses:
   - JSON an API returns and every client that parses it (web app, Formats
     API callers, SSE or stream consumers).
   - A DB column or migration that another package reads.
   - A queue payload, job record, or wire format another service reads.
   - A feature flag or env var whose value differs between dest and prod.
   - Billing and metering paths (holds, settlement, ledgers).
   - Code three hops downstream.
4. **Be honest about each risk.** Give it a real chance of happening and a
   real cost if it does. Keep the risks you confirmed. List the ones you
   checked and cleared separately. Cite a real `file:line`. A search that
   finds nothing is still an answer. Never make up a caller or an API.
5. **Prove the one fact.** Write the script or test that runs the real code,
   run it, and paste what happened.
6. **Big or wide change: get an independent second pass before you submit
   the PR** (`gt submit` on sume-com). Give one angle to a read-only
   in-process subagent (Claude Code Agent or Explore) and fold its findings
   in. A worker never launches
   nested workers (sume#7839). If a cross-family pass still looks warranted,
   say so in the report as a follow-up.

## What to hand back

Put this in the PR body under `## Blast radius`, or in the final report when
there is no PR.

- **What it does.** What changed, including the part that isn't obvious.
- **The one fact it's safe because of.** State it, give the level (1 to 5)
  you got it to, and show the proof. If you couldn't prove it, write
  `unproven`.
- **Risks.** For each: how it breaks, the `file:line`, how likely and how
  bad, and how to check. Paste the proof for the ones that matter.
- **Cleared.** What you checked and why it's fine.
- **Before you merge.** The cheapest test or repro that catches the real
  bug, including the script you wrote.

Cite real code and write plain sentences. Strip secrets, tokens, and
customer data before anything goes to GitHub or Slack.
