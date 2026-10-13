#!/usr/bin/env node
// cstack-ego-reap — close ego lite task spaces that agents left open (sume#12962).
//
//   cstack-ego-reap                      # dry run: list what a sweep would close
//   cstack-ego-reap --apply              # close them
//   cstack-ego-reap --job-dir <dir> [--sweep] [--apply]
//                                        # a finished job: close the agent spaces
//                                        # its worker.log names by id AND name
//                                        # (any age); --sweep
//                                        # also runs the dead-space sweep
//
// A sweep closes a space only when ALL of these hold:
//   - createdBy "agent". A space the person created (createdBy "user") is never
//     touched. When a worker dies, ego flips its space to ownership "user"
//     (inactive), so ownership alone cannot find the leaks; such a space is
//     claimed, then finished. finish() keeps any tab the person opened in it;
//   - older than --min-age-min (default 60). Ego reuses ids, so age is keyed
//     by id + name: an epoch-ms stamp in the name when there is one, else when
//     this tool first saw that id + name;
//   - no live job's worker.log names it (live = no exit_code and pid alive);
//   - no Claude/Codex transcript modified in the last --recent-min (default 60)
//     names it (covers interactive and non-launcher sessions);
//   - its name does not contain a live job's slug.
// Names = `taskSpace(N)`, `takeOverTaskSpace(N)`, `claimTaskSpace(N)`,
// `spaceId: N`, `taskSpaceId: N`.
// Closing = `taskSpace(N)` (or `claimTaskSpace(N)` when inactive), open one
// agent page, close blank (new tab / about:blank) tabs, adopt the agent's own
// tabs, then `finish({ keep: [] })`.
// A real page of unknown origin is the person's: it stays, and so does its
// space. The ego app is never killed.
// State and log: ~/.cstack/state/ego-reap/{first-seen.json,reap.log}.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = os.homedir();
const STATE = process.env.CSTACK_EGO_REAP_DIR || path.join(HOME, ".cstack/state/ego-reap");
const JOBS = process.env.SUME_BG_REMOTE_JOBS_DIR || path.join(HOME, ".cstack/state/remote-jobs");
const TRANSCRIPT_ROOTS = [path.join(HOME, ".claude/projects"), path.join(HOME, ".codex/sessions")];
const EGO = process.env.EGO_BROWSER_BIN || "ego-browser";

function parseArgs(argv) {
  const opts = { apply: false, sweep: true, jobDir: null, minAgeMin: 60, recentMin: 60 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--apply") opts.apply = true;
    else if (a === "--dry-run") opts.apply = false;
    else if (a === "--job-dir") {
      opts.jobDir = argv[++i];
      opts.sweep = false;
    } else if (a === "--sweep") opts.sweep = true;
    else if (a === "--min-age-min") opts.minAgeMin = Number(argv[++i]);
    else if (a === "--recent-min") opts.recentMin = Number(argv[++i]);
    else if (a === "-h" || a === "--help") opts.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  if (opts.jobDir && argv.includes("--sweep")) opts.sweep = true;
  return opts;
}

const REF_PATTERNS = [
  /\b(?:taskSpace|takeOverTaskSpace|claimTaskSpace)\(\s*(\d+)\s*\)/g,
  /\b(?:taskSpaceId|spaceId)["']?\s*[:=]\s*(\d+)/g,
];

function spaceRefs(text) {
  const ids = new Set();
  for (const re of REF_PATTERNS) for (const m of text.matchAll(re)) ids.add(Number(m[1]));
  return ids;
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

/** `20261012T215348Z-theme-light-default-resume-277737b7` → start ms + slug. */
function jobMeta(name) {
  const m = /^(\d{8})T(\d{6})Z-(.+)$/.exec(name);
  if (!m) return { startMs: NaN, slug: name };
  const [d, t] = [m[1], m[2]];
  const startMs = Date.parse(`${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6)}T${t.slice(0, 2)}:${t.slice(2, 4)}:${t.slice(4)}Z`);
  const slug = m[3].replace(/-(resume|fork)-[0-9a-f]{6,}$/, "");
  return { startMs, slug };
}

function scanJobs() {
  const jobs = [];
  let names = [];
  try {
    names = fs.readdirSync(JOBS);
  } catch {}
  for (const name of names) {
    const dir = path.join(JOBS, name);
    const log = path.join(dir, "worker.log");
    if (!fs.existsSync(log)) continue;
    const live = !fs.existsSync(path.join(dir, "exit_code")) && pidAlive(Number(readText(path.join(dir, "pid")).trim()));
    const text = readText(log);
    jobs.push({ name, dir, live, ...jobMeta(name), refs: spaceRefs(text), text: null, log });
  }
  return jobs;
}

function recentTranscriptRefs(recentMin) {
  const cutoff = Date.now() - recentMin * 60_000;
  const ids = new Set();
  const walk = (dir, depth) => {
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && depth < 5) walk(p, depth + 1);
      else if (e.isFile() && e.name.endsWith(".jsonl")) {
        const st = fs.statSync(p, { throwIfNoEntry: false });
        if (st && st.mtimeMs >= cutoff) for (const id of spaceRefs(readText(p))) ids.add(id);
      }
    }
  };
  for (const root of TRANSCRIPT_ROOTS) walk(root, 0);
  return ids;
}

/** Runs a script in ego's embedded Node and returns the last JSON line it printed. */
function egoEval(script, timeoutMs) {
  const r = spawnSync(EGO, ["nodejs", "-e", script], { encoding: "utf8", timeout: timeoutMs });
  const out = `${r.stdout ?? ""}\n${r.stderr ?? ""}`;
  const line = out.split("\n").reverse().find((l) => l.startsWith("@@REAP@@"));
  if (!line) throw new Error(`ego-browser gave no result (status ${r.status}${r.error ? `, ${r.error.code}` : ""}): ${out.slice(0, 400)}`);
  return JSON.parse(line.slice(8));
}

function listSpaces() {
  return egoEval('const s = await listTaskSpaces(); console.log("@@REAP@@" + JSON.stringify(s));', 240_000);
}

function closeSpaces(rows) {
  const script = `const out = [];
for (const { id, inactive } of ${JSON.stringify(rows.map((r) => ({ id: r.id, inactive: r.inactive })))}) {
  try {
    const t = inactive ? await claimTaskSpace(id) : await taskSpace(id);
    // finish() keeps unmanaged tabs, and ego replaces a space's last tab
    // with a blank one. So: open one agent page first, close the blank
    // unmanaged tabs, adopt the agent's own, then finish. A real page of
    // unknown origin is the person's: it stays, and so does the space.
    await t.newPage();
    let kept = 0;
    for (const tab of await t.tabs()) {
      if (tab.label) continue;
      const blank = ["chrome://newtab/", "chrome://newtab", "about:blank"].includes(tab.url || "");
      if (blank) await (await t.adopt(tab.page)).close();
      else if (tab.openedBy === "agent") await t.adopt(tab.page);
      else kept += 1;
    }
    const receipt = await t.finish({ keep: [] });
    out.push({ id, ok: true, closed: Boolean(receipt && receipt.closedSpace), kept });
  }
  catch (e) { out.push({ id, ok: false, error: String(e && e.message || e).slice(0, 200) }); }
}
console.log("@@REAP@@" + JSON.stringify(out));`;
  return egoEval(script, 60_000 + rows.length * 20_000);
}

function loadFirstSeen() {
  try {
    return JSON.parse(fs.readFileSync(path.join(STATE, "first-seen.json"), "utf8"));
  } catch {
    return {};
  }
}

function age(ms) {
  if (!Number.isFinite(ms)) return "?";
  const m = Math.round((Date.now() - ms) / 60_000);
  return m < 120 ? `${m}m` : `${(m / 60).toFixed(1)}h`;
}

/** One reaper at a time (a mass exit ends many jobs at once). */
function takeLock() {
  const lock = path.join(STATE, "lock");
  const deadline = Date.now() + 180_000;
  for (;;) {
    try {
      fs.mkdirSync(lock);
      fs.writeFileSync(path.join(lock, "pid"), String(process.pid));
      process.on("exit", () => fs.rmSync(lock, { recursive: true, force: true }));
      return true;
    } catch {}
    const holder = Number(readText(path.join(lock, "pid")).trim());
    const st = fs.statSync(lock, { throwIfNoEntry: false });
    if (!pidAlive(holder) && st && Date.now() - st.mtimeMs > 10_000) {
      fs.rmSync(lock, { recursive: true, force: true });
      continue;
    }
    if (Date.now() > deadline) return false;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2000);
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(readText(new URL(import.meta.url).pathname).split("\n").slice(1, 25).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    return;
  }
  fs.mkdirSync(STATE, { recursive: true });
  if (!takeLock()) {
    console.error("cstack-ego-reap: another reaper held the lock for 3 min; skipping");
    return;
  }
  const spaces = listSpaces();
  const now = Date.now();
  const firstSeen = loadFirstSeen();
  const key = (s) => `${s.id}\t${s.name ?? ""}`;
  for (const s of spaces) firstSeen[key(s)] ??= new Date(now).toISOString();
  for (const k of Object.keys(firstSeen)) if (!spaces.some((s) => key(s) === k)) delete firstSeen[k];
  fs.writeFileSync(path.join(STATE, "first-seen.json"), JSON.stringify(firstSeen));

  const jobs = scanJobs();
  const ownJob = opts.jobDir ? jobs.find((j) => path.resolve(j.dir) === path.resolve(opts.jobDir)) : null;
  const liveJobs = jobs.filter((j) => j.live && j !== ownJob);
  const liveRefs = new Set(liveJobs.flatMap((j) => [...j.refs]));
  const liveSlugs = liveJobs.map((j) => j.slug.toLowerCase()).filter((s) => s.length >= 4);
  const recentRefs = recentTranscriptRefs(opts.recentMin);

  if (opts.jobDir && !ownJob) console.error(`cstack-ego-reap: no worker.log under ${opts.jobDir}`);
  const ownRefs = new Set(ownJob ? [...ownJob.refs] : []);
  const ownText = ownJob ? readText(ownJob.log) : "";

  const rows = [];
  for (const s of spaces) {
    const stamp = /(?:^|\D)(1[7-9]\d{11})(?:\D|$)/.exec(String(s.name ?? ""));
    const born = Math.min(Date.parse(firstSeen[key(s)]) || now, stamp ? Number(stamp[1]) : Infinity);
    const agentSpace = s.createdBy === "agent";
    const nameLive = liveSlugs.find((slug) => String(s.name ?? "").toLowerCase().includes(slug));
    let action = "keep";
    let why;
    if (!agentSpace) why = "created by the person";
    else if (liveRefs.has(s.id)) why = "named by a live job";
    else if (ownRefs.has(s.id) && s.name && ownText.includes(s.name)) {
      action = "close";
      why = `used by finished job ${ownJob.name}`;
    } else if (!opts.sweep) why = "not this job's";
    else if (recentRefs.has(s.id)) why = `named by a transcript active in the last ${opts.recentMin}m`;
    else if (nameLive) why = `name matches live job ${nameLive}`;
    else if (now - born < opts.minAgeMin * 60_000) why = `younger than ${opts.minAgeMin}m`;
    else {
      action = "close";
      why = "agent space, no live job";
    }
    rows.push({ id: s.id, inactive: s.ownership !== "agent", action, why, age: age(born), owner: `${s.ownership}/${s.createdBy}`, name: String(s.name ?? "").slice(0, 60), tabs: (s.recentTabTitles ?? []).length });
  }

  const toClose = rows.filter((r) => r.action === "close");
  console.log(`cstack-ego-reap: ${spaces.length} spaces, ${toClose.length} to close, ${liveJobs.length} live jobs${opts.apply ? "" : " (dry run)"}`);
  for (const r of rows) console.log(`${r.action === "close" ? "CLOSE" : "keep "} ${String(r.id).padStart(4)}  ${r.owner.padEnd(11)} age ${r.age.padStart(5)}  tabs ${r.tabs}  ${r.name}  — ${r.why}`);
  if (!opts.apply || toClose.length === 0) return;
  const results = closeSpaces(toClose);
  const log = path.join(STATE, "reap.log");
  for (const res of results) {
    const row = toClose.find((r) => r.id === res.id);
    fs.appendFileSync(log, `${new Date().toISOString()} ${res.ok ? (res.closed ? "closed" : `kept(${res.kept} person tabs)`) : "failed"} ${res.id} age=${row.age} "${row.name}" ${res.error ?? ""}\n`);
  }
  const ok = results.filter((r) => r.ok && r.closed).length;
  console.log(`cstack-ego-reap: closed ${ok}/${results.length}${results.some((r) => r.ok && !r.closed) ? " (the rest hold a person's tab)" : ""}`);
  for (const r of results.filter((x) => !x.ok)) console.log(`  failed ${r.id}: ${r.error}`);
}

try {
  main();
} catch (error) {
  console.error(`cstack-ego-reap: ${error?.message ?? error}`);
  process.exit(1);
}
