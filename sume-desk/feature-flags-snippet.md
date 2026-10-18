## Sume feature flags (always on)

No binary feature flags (`~/.cstack/src/docs/FEATURE-FLAGS.md`; in sume-com,
`docs/operations/feature-flags.md`).

- Do not add an env variable or a host check that turns product behaviour on
  or off, or picks A or B. Dev and production run the same product.
- A flag needed to land a change is removed within one week of landing; the
  PR that adds it states the removal date.
- Removing a flag keeps dev's behaviour and adds no env variable. Env holds
  per-environment resources only (keys, accounts, URLs, buckets, process
  roles, tuning numbers).
- Env names side by side, Railway and Vercel: sume-com
  `docs/operations/env-names.md` (names only, never values).
