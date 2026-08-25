---
name: mobidoo-live-commerce-update
description: >-
  Pull, lock a diff, and publish the live-commerce Format package via Code
  Storage (not sume-com skill-lab). Two-stage push: dest
  `mobidoo/live-commerce` first, then prod `mobidoo/live-commerce` plus
  `sumelabs/live-commerce`. Use when Chase says to update the LC skill,
  assemble/hold/half-banner rules, or to commit to code.storage.
---

# mobidoo-live-commerce-update

Edit the **running Format package** on Code Storage. `apps/skill-lab` in
`sume-com` is a lab mirror, not the execute SoT.

Read this skill before any `createCommit` / CS push for live-commerce.

## Addresses

One org (`sume`). Prefix is the environment.

| Stage | CS repo id | Serves |
|---|---|---|
| **1 — dest** | `dev/mobidoo/live-commerce` | `api.dev` / `@mobidoo` / `live-commerce` |
| **2 — prod** | `prod/mobidoo/live-commerce` | `api.sume.com` / `@mobidoo` |
| **2 — prod** | `prod/sumelabs/live-commerce` | `api.sume.com` / `@sumelabs` |

**Forbidden:** push dest and prod in one step. **Forbidden:** prod Mobidoo
without prod Sumelabs in the same stage-2, or the reverse (both or neither).

**Needs verification** if a GET 404s the repo id: confirm with `listRepos` /
catalog `handle`+`slug`. Do not invent a third prefix.

## Auth (desk)

| Use | Path |
|---|---|
| Desk author commits | `~/.sume/ops/code-storage-local.pem` + `code-storage-local.env` |
| Railway publisher | `~/.sume/ops/code-storage-sume.pem` — **do not** use for desk push |

```bash
set -a
source ~/.sume/ops/code-storage-local.env
set +a
export SUME_CS_PRIVATE_KEY="$(cat "$SUME_CS_PRIVATE_KEY_FILE")"
export SUME_CS_ORG=sume
# dest: SUME_CS_REPO_PREFIX=dev   prod: SUME_CS_REPO_PREFIX=prod
```

Never echo the PEM. Never paste it into issues, PRs, or chat.

## Loop (every repo, every stage)

### 1) Pull

- Fetch **that repo’s `main` now**. Do not trust
  `~/.sume/ops/cs-clones/` without fetch (those trees go stale).
- Do not treat `origin/main` `apps/skill-lab/skills/mobidoo-live-commerce`
  as the bytes the agent will run.
- Record: repo id, tip commit sha, **tree sha** (`package_sha`).
- `GET` the Format on the matching API (`api.dev` vs `api.sume.com`) and
  compare `package_sha` / `version`. If they disagree, stop and say which
  one execute will use (CS `main` tip vs catalog pin — env-dependent).

### 2) Conceive

Write one rule sentence, file list, dest-only vs later-prod, and non-goals.
Example: “H/A never freeze-hold; H seams hard-cut; no TTS regen.”

**Word lock — `hold`:** in this package, a **hold** is the N/B
`timeline_create` of a still/clip at `ceil(needed)+1` (lock 59). It is
**not** “copy the last avatar frame onto a talking H compose.” H is
compose-only and **not** padded that way. H-touching seams omit
`transition` (hard cut).

### 3) Lock the diff

Show the exact hunks from the **pulled** tree. Chase OK before commit.
No extra files.

### 4) Push

`createCommit` (or clone push) with **`expectedHeadSha` = pulled tip**.

- Identical bytes → vendor `no changes to commit` is **success** (keep tip).
- Stale head → `conflict`. Re-pull; do not force.
- Assert returned `treeSha` matches local tree hash.

Then `GET` catalog again. Report repo id + new `package_sha` + `version`.

## Two-stage push (hard)

```
conceive + lock once
    │
    ▼
stage 1  pull → apply → push   dev/mobidoo/live-commerce
    │
    ▼
Chase dest smoke (Formats fire only if he asked)
    │
    ▼
stage 2  pull each → same diff → push
         prod/mobidoo/live-commerce
         prod/sumelabs/live-commerce
```

- Stage 1 is the only write until Chase says dest is good (or explicitly
  skips smoke).
- Stage 2 applies the **same locked hunks** to **both** prod repos. Two
  pulls, two `expectedHeadSha`s. If one prod tip cannot take the hunk,
  **stop** — do not leave Mobidoo and Sumelabs split.
- Prod `@mobidoo` fire is customer-request only
  (`formats-lc-prod-mobidoo-customer-fire-lock.md`). Prod `@sumelabs`
  desk fire is the Sumelabs test lane only.

## Non-goals

- `sume-com` PR as the publish path (optional later mirror sync, own train).
- Scope editor / API-key grants.
- Mixing dest key onto prod, or Sumelabs key onto `@mobidoo`.
- Sauceflex webhook, spend-cap folklore, unless Chase added them.

## Local clone layout (optional)

After a real fetch, trees may live under `~/.sume/ops/cs-clones/` as
`dev__mobidoo__live-commerce` etc. Treat that path as a cache: **fetch
first** or delete and re-clone.

## Done report

```
stage: 1 | 2
repos: …
tip_before: …
tip_after / package_sha: …
catalog GET: host + version + package_sha
blocked: (none | dest smoke | hunk mismatch on …)
```
