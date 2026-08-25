---
name: mobidoo-live-commerce-update
description: >-
  Formats SoT for live-commerce. Package bytes live on Code Storage (not
  skill-lab). Covers pull → lock → two-stage CS push, catalog pin vs
  execute, dest run-create fire, and what belongs on a sume-com mega-issue
  instead. Use before any LC createCommit, Format fire, or “update the
  LC skill” ask.
---

# Formats SoT — live-commerce

This file is the **desk SoT** for Formats work. FLOW.md and Cursor `.mdc`
rules are maps/pointers. If they disagree with this file, **this file
wins** — then fix the map.

`apps/skill-lab` in `sume-com` is a lab mirror. It is **not** what a
Format run executes.

## Which work is this?

| Lane | This skill? | Do |
|---|---|---|
| Running LC **package** (assemble, banners, hold, price cards, `sentence_map`) | **Yes** | Pull CS → conceive → lock hunks → two-stage push |
| Dest **run create** (`POST …/runs`) | **Yes** (fire section) | `api.dev` + `@mobidoo` / `live-commerce` only |
| Formats **UI / PDP / dashboard chrome** | **No** | GitHub mega-issue → Opus → `gt` on `sume-com` |
| Product lock **text** (lock 1–60) | Pull, don’t invent | After fetch: CS `SKILL.md` + `references/locks.md` |

Do not invent package rules from chat. Pull first. Chase one-liners
below override a **filled-card** habit; they do not rewrite the skeleton
anchor.

## Addresses

One org (`sume`). Prefix is the environment.

| Stage | CS repo id | Serves |
|---|---|---|
| **1 — dest** | `dev/mobidoo/live-commerce` | `api.dev` / `@mobidoo` / `live-commerce` |
| **2 — prod** | `prod/mobidoo/live-commerce` | `api.sume.com` / `@mobidoo` |
| **2 — prod** | `prod/sumelabs/live-commerce` | `api.sume.com` / `@sumelabs` |

**Forbidden:** dest and prod in one step. **Forbidden:** prod Mobidoo
without prod Sumelabs in the same stage-2 (both or neither).

If a GET 404s a repo id: `listRepos` / catalog `handle`+`slug`. Do not
invent a third prefix.

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

## Execute = catalog pin (Chase 2026-08-25)

A Format **run** loads the catalog `package_sha` / `version`, **not**
whatever is now at CS `main`.

- CS push can move the tip while `GET /v1/formats/…` still shows the old pin.
- Pushing CS ≠ live execute.
- After every stage, report **CS tip** and **catalog pin**.
- Rebake / bump catalog version **only if Chase asks**.

## Desk locks (keep current; pull package for the rest)

**`hold`:** N/B `timeline_create` of a still/clip at `ceil(needed)+1`
(package lock 59). Not “copy the last avatar frame onto talking H.”
H is compose-only. H-touching seams omit `transition` (hard cut).

**Price cards — no fake money (Chase 2026-08-25):** filled cards never
print `00%` or `00,000원`. Those zeros belong only on the **layout
skeleton / banner-anchor** (package lock 28) as struck examples. If a
SKU has no real percent or won, **omit that slot and collapse**. Keep
the skeleton PNG. Do not fill dummy digits. Do not “fix” the skeleton
with real-looking fake prices.

**Plan:** `sentence_map[]` is the conception (package lock 54). Do not
skip it on produce.

## Publish loop (every repo, every stage)

### 1) Pull

- Fetch **that repo’s `main` now**. `~/.sume/ops/cs-clones/` is a cache —
  fetch first or delete and re-clone (`dev__mobidoo__live-commerce` etc.).
- Do not treat `origin/main` `apps/skill-lab/skills/mobidoo-live-commerce`
  as execute bytes.
- Record: repo id, tip commit sha, tree sha (`package_sha`).
- `GET` the Format on the matching API. If pin ≠ CS tip, say which
  execute will use (the pin).

### 2) Conceive

One rule sentence, file list, dest-only vs later-prod, non-goals.
Example: “H/A never freeze-hold; H seams hard-cut; no TTS regen.”

### 3) Lock the diff

Exact hunks from the **pulled** tree. Chase OK before commit. No extra
files.

### 4) Push

`createCommit` (or clone push) with **`expectedHeadSha` = pulled tip**.

- Identical bytes → vendor `no changes to commit` is **success** (keep tip).
- Stale head → `conflict`. Re-pull; do not force.
- Assert returned `treeSha` matches local tree hash.
- `GET` catalog again. Report repo id + CS `package_sha` + catalog
  version/pin.

## Two-stage push (hard)

```
conceive + lock once
    │
    ▼
stage 1  pull → apply → push   dev/mobidoo/live-commerce
    │
    ▼
Chase dest smoke (fire only if he asked)
    │
    ▼
stage 2  pull each → same diff → push
         prod/mobidoo/live-commerce
         prod/sumelabs/live-commerce
```

- Stage 1 is the only write until Chase says dest is good (or skips smoke).
- Stage 2 = **same hunks** on **both** prod repos. Two pulls, two
  `expectedHeadSha`s. One prod cannot take the hunk → **stop**. Do not
  leave Mobidoo and Sumelabs split.
- Prod `@mobidoo` fire: customer-request only
  (`~/.sume/ops/formats-lc-prod-mobidoo-customer-fire-lock.md`).
- Prod `@sumelabs` desk fire: Sumelabs test lane only.

## Dest fire (run create)

When Chase asks to **create a dest LC run**, this section is SoT.
Policy path (webhook URL may move): `~/.sume/ops/formats-lc-0813-fire-lock.md`.
Cursor rule `formats-api-dev-mobidoo.mdc` is a pointer here.

1. **Host + handle:** `https://api.dev.sume.com` + `mobidoo` /
   `live-commerce`. Workspace **@mobidoo**. Not prod, not Sumelabs.
2. **Webhook we can read.** `communication.mode: "webhook"`. URL = the
   desk inbox in that ops file (webhook.site). Do not fire poll-only.
3. **Forbidden:** Sauceflex
   `https://dev.api-admin.sauceflex.com/sauce-live/v1/ai-showhost/sume-video-callback`
   (partner concept, 403). Not a working receiver.
4. **Structured output:** `primary_output_key: "full_video"`. Schema
   `strict: false`, require only `full_video` (`SumeMediaFile#`).
   `additionalProperties: false`. Do **not** require
   `opening` / `middle` / `closing`.
5. Never paste the webhook signing secret
   (`~/.sume/ops/webhook-secret-mobidoo-dev.env`).

## Non-goals

- `sume-com` PR as the **package** publish path (mirror sync is its own train).
- Scope editor / API-key grants.
- Mixing dest key onto prod, or Sumelabs key onto `@mobidoo`.
- Sauceflex / spend-cap folklore unless Chase added them.
- Treating a CS tip as execute without a catalog pin match.
- Rebaking catalog unless Chase asked.
- Using this skill as the author path for Formats **chrome** PRs.

## Done report

```
lane: package-push | dest-fire | (say if UI → wrong skill)
stage: 1 | 2 | —
repos: …
tip_before: …
tip_after / CS package_sha: …
catalog GET: host + version + package_sha
execute_will_use: catalog pin | (say if pin ≠ CS tip)
blocked: (none | dest smoke | hunk mismatch | pin leftover | fire not asked)
```
