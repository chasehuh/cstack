# Feature flags: none, and one week at most

Chase lock 2026-10-17. Applies to every harness on the desk and every repo
the desk writes code in. In `sume-com` the rule is owned by
`docs/operations/feature-flags.md`; every env name and its owning store is
in `docs/operations/env-names.md`.

## The rule

- A binary feature flag is any env variable or code branch that picks one of
  two behaviours: on or off, A or B, "on for the dev host, off on
  production". Do not add one.
- Dev and production run the same product from the same SHA. Nothing in code
  holds production behind dev.
- If a change cannot land without a flag, the flag is removed within **one
  week** of landing. The PR that adds it states the removal date; the author
  removes the branch and the variable by then, in a PR of their own. Flags
  Chase wrote are included.
- Removing a flag means the code always does the kept behaviour, the one dev
  runs. Delete the branch. Never replace a flag with a new env variable or
  grow the env-variable count to stand in for one.
- Env holds per-environment resources only: keys, secrets, accounts, URLs,
  buckets, per-service process roles, tuning numbers, route model lists.

## For agents

- Do not add `*_ENABLED`, `NEXT_PUBLIC_*_ENABLED` or host checks
  (`isDevPublicAppUrl`, `RAILWAY_ENVIRONMENT_NAME === "development"`) that
  switch product behaviour.
- A flag you find past its week is a bug: delete it in the change that
  touches its surface, keeping dev's behaviour.
- To compare env between Railway and Vercel, open
  `docs/operations/env-names.md` in sume-com; refresh it with
  `node scripts/env-names.mjs --write`. Never print values.
