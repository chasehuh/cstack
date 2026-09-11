# Dest verify → GitHub issue screenshots — HARD LOCK (Chase 2026-09-11, #7110)

Proved on [#6860](https://github.com/sumelabs/sume/issues/6860#issuecomment-5602167174)
(Members / Usage, four shots, one comment).

This is **desk policy**, not a product feature. SoT also lives in
`sume-main-agent-orchestration` SKILL.md § Browser verification.

## When (hard stop)

After **any** browser verify on dest (`www.dev.sume.com`, sumelabs) or
Chase-authorized prod (`www.sume.com`, sumelabs + chase@sume.com), the
verify is **incomplete** until **one** GitHub issue comment on the Job’s
issue carries **all** evidence: **2–4 screenshots** + text (host,
workspace, Auto, SHA, pass/fail, thread/URL). Chase checks work on the
issue; chat and board are not enough.

- Final report **must** include `SHOTS: <gh comment URL>`. No URL ⇒ no
  `DEST: pass`, and do not tell Chase dest is done.
- Do **not** exit after `origin/main` `(#N)` while the dest deploy is
  still building; stay or resume until the comment is posted (`#7104`
  fail pattern). `#7103` landed with no shots — also a fail.
- RCA / no-UI Jobs: no forced tour, but if you opened dest/prod, the rule
  applies.

Does **not** replace the chat work report or the status board.

## How

1. **`ego-browser` TaskSpace (preferred) or `aside repl`.** Ego: own
   space + own tab (`p1`), `page.screenshot({ path })` for the PNGs.
   Aside: Chase window **and same tab** are OK. Tab title is optional; if
   set, **`[Agent]`** only — not `[Astra]`.
2. **Compose model = Auto.** Never pin GPT-6 Astra (or another model)
   unless Chase locked a pin test. Auto router is the dest AC.
3. Capture 2–4 PNGs of the locked surfaces (not a full product tour).
4. **One** `gh issue comment` on that issue. Embed the images in the
   body (same `user-attachments` / upload path as #6860). No second
   comment per extra shot.
5. Body must name: dest host, workspace `sumelabs`, **Auto** (not
   Astra), `/api/build` or agent SHA if known, pass/fail, thread URL.
6. No secrets, PEM, API keys, Clerk cookies.

## Non-goals

- Prod shots unless Chase authorized prod test (Sumelabs + chase@sume.com).
- Customer workspaces (mobidoo, etc.).
- Harness spam on every RCA-only / no-UI Job.
- Replacing Slack or the chat board.
- Treating the worker’s coding model as the dest picker.

## Worker prompt line (copy)

```text
DEST EVIDENCE (hard lock 2026-09-11, #7110): after dest/prod browser verify
(ego-browser TaskSpace preferred, aside repl ok; Auto router, not GPT-6
Astra; sumelabs; www.dev.sume.com), post ONE gh issue comment on the Job
issue with 2–4 screenshots + host, sumelabs, Auto, SHA, pass/fail. Final
report must carry `SHOTS: <comment URL>`. Forbidden: `DEST: pass` without
SHOTS. Forbidden: exiting after main land while dest deploy still builds.
```
