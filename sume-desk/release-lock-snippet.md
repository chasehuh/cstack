## Sume release lock (always on)

Chase lock 2026-10-18 (`~/.cstack/src/docs/RELEASE-LOCK.md`).

- Staging → prod is forbidden unless Chase explicitly allows **that**
  release.
- "Do it on prod" / "hide it on prod" is not permission to tag.
- The only agent that may tag, approve Production, or dispatch the prod
  release is a dedicated release subagent, and that agent does **only** the
  release. Product workers stop at `origin/main` and a staging candidate.
- Product workers: no `vX.Y.Z-rc.N` / `vX.Y.Z` tag, no release workflow
  dispatch, no Production approval. If prod needs new code, stop at main and
  write `RELEASE: needs Chase` in the final report.
- Main agent: never tell a product worker to release. Ask Chase; launch a
  release-only job only after he allows that release.
- Incident: on 2026-10-18 a worker told "hide Brand OS on prod" tagged
  `v1.0.4-rc.1` and `v1.0.4` on `18eae2f2e`, shipping every commit since
  `v1.0.3`. Chase had not asked for a release.
