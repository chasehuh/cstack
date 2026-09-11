# Dest verify → GitHub issue screenshots (Chase lock 2026-09-09)

Proved on [#6860](https://github.com/sumelabs/sume/issues/6860#issuecomment-5602167174)
(Members / Usage, four shots, one comment).

This is **desk policy**, not a product feature. SoT also lives in
`sume-main-agent-orchestration` SKILL.md § Browser verification.

## When

After a worker finishes **user-visible dest** verify on
`www.dev.sume.com` (sumelabs), it posts **one** GitHub issue comment on
the Job’s issue with **2–4 screenshots**. Not exhaustive. Enough to show
dest applied.

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
After dest browser verify (ego-browser TaskSpace preferred, aside repl ok):
Auto router only (not GPT-6 Astra). Ego = own tab; Aside = same window/tab
as Chase OK, optional title [Agent]. One issue comment, 2–4 screenshots
(proved #6860). sumelabs, www.dev.sume.com.
```
