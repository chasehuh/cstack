# Releases: only a release agent, only when Chase says so

Chase lock 2026-10-18. Applies to every harness on the desk: the main agent,
every Opus / Fable / Grok / Codex worker, Mini cron jobs. In `sume-com` the
release mechanics (rc tag → staging, `vX.Y.Z` → production, the Production
environment gate) are owned by the repo's release docs; this file owns **who
may start one**.

## The rule

- Staging → prod is forbidden unless Chase explicitly allows **that**
  release. Permission is per release; it does not carry over to the next one.
- "Do it on prod" / "hide it on prod" is not permission to tag.
- The only agent that may tag, approve Production, or dispatch the prod
  release is a dedicated release subagent, and that agent does **only** the
  release. Product workers stop at `origin/main` and a staging candidate.

## What this means for each role

- **Product worker** (any job that writes product code, flags, config or
  ops state): land on `origin/main`, verify on dev, and name the main SHA as
  the staging candidate in the final report. Do not create any release tag
  (`vX.Y.Z-rc.N` or `vX.Y.Z`), do not run or dispatch a release workflow, do
  not approve a Production deployment, do not promote an Open release. If the
  task needs prod and prod needs new code, stop at main and write
  `RELEASE: needs Chase` in the final report.
- **Main agent**: never tell a product worker to tag, release, or ship to
  prod. When Chase asks for a change "on prod", deliver it on dev and ask
  Chase whether he wants a release. Only after Chase says yes for that
  release, launch a separate release job whose prompt quotes his words and
  names the exact SHA.
- **Release agent**: a job that does only the release Chase allowed. It
  quotes Chase's permission, tags the SHA he allowed, watches staging, and
  approves Production. It writes no product code and takes no other task.
  Anything outside that release is out of scope: stop and report.

A prod change that needs no new code and no tag (for example a data or
settings row Chase asked to change on prod) is not a release. It is still
done only on Chase's word for prod.

## Incident (2026-10-18, `v1.0.4`)

Chase said hide Brand OS on dev and prod, and keep the code. He did not say
to cut a release. The main agent told the `brand-os-hide` worker that if prod
could not hide without new code, it should land and ship a production
release. That worker tagged `v1.0.4-rc.1` and then `v1.0.4` on `18eae2f2e`,
which also carried every commit since `v1.0.3`. Chase had not asked for a
release. He let that release finish and asked for this lock so it does not
happen again.
