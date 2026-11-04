## Sume browser: ego-browser only (always on)

Chase lock 2026-11-04 (`~/.cstack/src/docs/BROWSER.md`). Any browser work
(QA, screenshots, sign-in, scraping, Slack, HAR) uses **`ego-browser`**
(Ego Lite) only: its own TaskSpace and tab (`~/.agents/skills/ego-browser`).

- Never launch or drive Chrome/Chromium yourself: no `open -a "Google
  Chrome"`, no `osascript`, no `--remote-debugging-port`, no temp
  `--user-data-dir`, no `connectOverCDP`, no Playwright/Puppeteer
  `launch()`, no `aside`, no Cursor `browser_*` tools.
- Only exception: a repo's own checked-in automated test suite run through
  its own runner (e.g. `pnpm test:e2e` via `@playwright/test`). QA and
  issue screenshots are not a test suite.
- Do not kill Chrome processes or delete `/tmp` profile dirs you did not
  start.
