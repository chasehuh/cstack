# Browser: ego-browser (Ego Lite) only

Chase lock 2026-11-04. Applies to every agent on the desk: the main agent,
every worker on the M5 and the laptop, cron jobs, and every harness (Claude
Code, Codex, Cursor).

## The rule

Every agent that needs a browser uses **`ego-browser`** (Ego Lite) and
nothing else: its own TaskSpace, its own tab, its own logged-in profile.
Skill: `~/.agents/skills/ego-browser/SKILL.md`.

Forbidden, for any purpose (QA, screenshots, scraping, sign-in, Slack, HAR,
performance traces, "just a quick check"):

- launching Google Chrome, Chrome for Testing, Chromium, Edge, Brave or
  Safari yourself: `open -a "Google Chrome"`, `osascript` telling a browser
  to do anything, running a browser binary directly;
- `--remote-debugging-port`, a temporary or copied `--user-data-dir`, or
  attaching to someone's Chrome over CDP (`connectOverCDP`,
  `puppeteer.connect`, `chrome-remote-interface`);
- Playwright or Puppeteer **launching** a browser from a script
  (`chromium.launch`, `launchPersistentContext`, `puppeteer.launch`,
  `npx playwright open/codegen/screenshot`);
- `aside repl` / `aside exec`, the Cursor `browser_*` MCP tools, or any
  other harness that drives Chase's Chrome;
- headless Chrome for "signed-out" or "fresh profile" checks. Use a new
  ego TaskSpace instead (see `ego-browser` references for clearing state).

`page.cdp(...)` **inside** an ego TaskSpace is fine: that is ego's own
session, not a Chrome you started.

## The one exception: a repo's own automated test suite

A repository's checked-in automated tests may start the browser their own
runner manages, when you run them the way the repo runs them (for example
`pnpm test:e2e` through `@playwright/test`'s runner, or the CI job that runs
it). Nothing else qualifies:

- run the suite through its runner and script; do not write a new
  script that launches a browser and call it a test;
- no real or copied profile, no remote-debugging port, no driving that
  browser by hand while the suite runs;
- product QA, screenshots for an issue, and dest verification are not a
  test suite: they use ego.

## Leftovers

Browser processes and `/tmp` profile dirs from before this rule can still
be around. Do **not** kill Chrome processes or delete profile dirs you did
not start in this session: they may be Chase's browser or another job's
test run. Clean up only what you started; report anything else.

## Where the rule lives

- `~/.codex/AGENTS.md` section "Sume browser: ego-browser only (always on)"
  (`sume-desk/browser-snippet.md`; Claude Code imports it), written and
  refreshed by `install.sh`, checked by `check-wiring.sh`.
- The worker preamble every `agent-human-stream` prompt starts with.
- `AGENTS.md`, the orchestration skill § Browser verification,
  `references/dest-verify-issue-shots.md`, and the Cursor
  `aside-browser-verify.mdc` rules (kept name, ego-only content).
