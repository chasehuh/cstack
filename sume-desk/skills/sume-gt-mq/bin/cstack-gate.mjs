#!/usr/bin/env node
// cstack-gate — machine-wide admission for heavy local gates (sume#12962).
//
//   cstack-gate [--label <name>] [--timeout <minutes>] -- <command…>
//   cstack-gate status
//
// Heavy gates (ci-test-changed, ci-typecheck-changed, ci-build-changed, a full
// `pnpm -r test`) wait in one FIFO queue shared by every worker on this Mac.
// The head of the queue is admitted when:
//   - no gate runs (a gate never waits on load it did not cause), or
//   - fewer than CSTACK_GATE_MAX gates run (default 4), load1 is under
//     CSTACK_GATE_ADMIT_LOAD (default 14, ~80% of 18 cores), and the last
//     admission was at least CSTACK_GATE_SETTLE_S ago (default 20; load1 lags).
//   - A head that has waited CSTACK_GATE_PATIENCE_S (default 120) is also
//     admitted while load1 is at or under CSTACK_GATE_HOLD_LOAD (default 17,
//     ~95%). Above 17 the next gate always waits.
// A running gate is never paused. The child runs under `nice -n 10` with
// VITEST_MAX_WORKERS=4 and npm_config_workspace_concurrency=4 unless the
// caller already set them, and is killed (whole process tree) at the timeout
// (default 30 min, exit 124).
//
// State: ~/.cstack/state/gate/{queue/<ticket>.json, slots/<k>/owner.json,
// last-admit}. A ticket or slot whose pid is gone is removed by the next
// waiter, so a SIGKILLed worker never wedges the queue.
// CSTACK_GATE_OFF=1 runs the command at once (emergency bypass).
// CSTACK_GATE_HELD=1 is set in the child, so a nested gate runs directly.

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const env = process.env;
const num = (name, fallback) => {
  const value = Number(env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};
const STATE = env.CSTACK_GATE_DIR || path.join(os.homedir(), ".cstack/state/gate");
const QUEUE = path.join(STATE, "queue");
const SLOTS = path.join(STATE, "slots");
const LAST_ADMIT = path.join(STATE, "last-admit");
const MAX = Math.floor(num("CSTACK_GATE_MAX", 4));
const ADMIT_LOAD = num("CSTACK_GATE_ADMIT_LOAD", 14);
const HOLD_LOAD = num("CSTACK_GATE_HOLD_LOAD", 17);
const SETTLE_MS = num("CSTACK_GATE_SETTLE_S", 20) * 1000;
const PATIENCE_MS = num("CSTACK_GATE_PATIENCE_S", 120) * 1000;
const POLL_MS = num("CSTACK_GATE_POLL_MS", 2000);
const NICE = env.CSTACK_GATE_NICE ?? "10";

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function age(ms) {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  return s < 120 ? `${s}s` : `${Math.round(s / 60)}m`;
}

function load1() {
  return os.loadavg()[0];
}

/** Live tickets in FIFO order; dead ones are removed. */
function tickets() {
  let names = [];
  try {
    names = fs.readdirSync(QUEUE).filter((n) => n.endsWith(".json")).sort();
  } catch {}
  const live = [];
  for (const name of names) {
    const file = path.join(QUEUE, name);
    const t = readJson(file);
    if (t && alive(t.pid)) live.push({ ...t, file });
    else fs.rmSync(file, { force: true });
  }
  return live;
}

/** Held slots; slots of dead pids or past their deadline are freed. */
function holders() {
  const held = [];
  for (let k = 1; k <= MAX; k += 1) {
    const dir = path.join(SLOTS, String(k));
    if (!fs.existsSync(dir)) continue;
    const owner = readJson(path.join(dir, "owner.json"));
    if (!owner) {
      // mkdir won but owner.json not written yet: give it 30 s.
      const st = fs.statSync(dir, { throwIfNoEntry: false });
      if (st && Date.now() - st.mtimeMs > 30_000) fs.rmSync(dir, { recursive: true, force: true });
      else held.push({ slot: k, pid: 0, label: "(starting)", since: Date.now() });
      continue;
    }
    const overdue = owner.deadline && Date.now() > owner.deadline + 5 * 60_000;
    if (!alive(owner.pid) || overdue) {
      fs.rmSync(dir, { recursive: true, force: true });
      continue;
    }
    held.push({ slot: k, ...owner });
  }
  return held;
}

function describe(held) {
  return held.map((h) => `${h.label} ${age(h.since)}`).join(", ") || "none";
}

function lastAdmitMs() {
  const st = fs.statSync(LAST_ADMIT, { throwIfNoEntry: false });
  return st ? st.mtimeMs : 0;
}

/** Decide for the queue head. Returns null to admit, or the reason to wait. */
function waitReason(held, waitedMs) {
  if (held.length === 0) return null;
  if (held.length >= MAX) return `${held.length}/${MAX} gates running`;
  const load = load1();
  const sinceAdmit = Date.now() - lastAdmitMs();
  if (sinceAdmit < SETTLE_MS) return `settling ${Math.ceil((SETTLE_MS - sinceAdmit) / 1000)}s after the last admission`;
  if (load < ADMIT_LOAD) return null;
  if (waitedMs >= PATIENCE_MS && load <= HOLD_LOAD) return null;
  return `load1 ${load.toFixed(1)} ≥ ${ADMIT_LOAD}`;
}

function takeSlot(owner) {
  for (let k = 1; k <= MAX; k += 1) {
    const dir = path.join(SLOTS, String(k));
    try {
      fs.mkdirSync(dir);
    } catch {
      continue;
    }
    fs.writeFileSync(path.join(dir, "owner.json"), JSON.stringify(owner));
    fs.writeFileSync(LAST_ADMIT, String(Date.now()));
    return dir;
  }
  return null;
}

function status() {
  const held = holders();
  const queue = tickets();
  console.log(`load1 ${load1().toFixed(1)} · admit < ${ADMIT_LOAD} · hold > ${HOLD_LOAD} · max ${MAX}`);
  console.log(`running ${held.length}/${MAX}:`);
  for (const h of held) console.log(`  slot ${h.slot} pid ${h.pid} ${h.label} ${age(h.since)} ${h.cwd ?? ""}`);
  console.log(`queued ${queue.length}:`);
  queue.forEach((t, i) => console.log(`  ${i + 1}. pid ${t.pid} ${t.label} waiting ${age(t.since)} ${t.cwd ?? ""}`));
}

function parseArgs(argv) {
  const opts = { label: null, timeoutMin: num("CSTACK_GATE_TIMEOUT_MIN", 30), cmd: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--") {
      opts.cmd = argv.slice(i + 1);
      break;
    }
    if (a === "--label") opts.label = argv[++i];
    else if (a === "--timeout") opts.timeoutMin = Number(argv[++i]);
    else if (a === "status") opts.status = true;
    else if (a === "-h" || a === "--help") opts.help = true;
    else {
      opts.cmd = argv.slice(i);
      break;
    }
  }
  return opts;
}

function childEnv() {
  const out = { ...env, CSTACK_GATE_HELD: "1" };
  out.VITEST_MAX_WORKERS ||= "4";
  out.npm_config_workspace_concurrency ||= "4";
  return out;
}

/** Every descendant pid of `root`, deepest first. */
function descendants(root) {
  const out = spawnSync("ps", ["-axo", "pid=,ppid="], { encoding: "utf8" }).stdout || "";
  const kids = new Map();
  for (const line of out.trim().split("\n")) {
    const [pid, ppid] = line.trim().split(/\s+/).map(Number);
    if (!kids.has(ppid)) kids.set(ppid, []);
    kids.get(ppid).push(pid);
  }
  const order = [];
  const walk = (pid) => {
    for (const kid of kids.get(pid) ?? []) {
      walk(kid);
      order.push(kid);
    }
  };
  walk(root);
  return order;
}

function killTree(root, signal) {
  for (const pid of [...descendants(root), root]) {
    try {
      process.kill(pid, signal);
    } catch {}
  }
}

// The child stays in the caller's process group, so a launcher that kills the
// worker's group (sume-bg-remote kill, a mass exit) takes the gate down too.
function runChild(cmd, timeoutMin, onExit) {
  const argv = NICE && NICE !== "0" ? ["nice", "-n", NICE, ...cmd] : cmd;
  const child = spawn(argv[0], argv.slice(1), { stdio: "inherit", env: childEnv() });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    console.error(`cstack-gate: timeout after ${timeoutMin} min; killing the gate`);
    killTree(child.pid, "SIGTERM");
    setTimeout(() => killTree(child.pid, "SIGKILL"), 10_000).unref();
  }, timeoutMin * 60_000);
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => killTree(child.pid, sig));
  }
  child.on("exit", (code, signal) => {
    clearTimeout(timer);
    onExit(timedOut ? 124 : code ?? (signal ? 128 + (os.constants.signals[signal] ?? 1) : 1));
  });
  return child;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(fs.readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 28).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    return;
  }
  fs.mkdirSync(QUEUE, { recursive: true });
  fs.mkdirSync(SLOTS, { recursive: true });
  if (opts.status) return status();
  if (opts.cmd.length === 0) {
    console.error("cstack-gate: usage: cstack-gate [--label name] [--timeout min] -- <command…>");
    process.exit(2);
  }
  const label = opts.label || `${env.SUME_BG_REMOTE_JOB || path.basename(process.cwd())}:${path.basename(opts.cmd[1] ?? opts.cmd[0])}`;
  if (env.CSTACK_GATE_OFF === "1" || env.CSTACK_GATE_HELD === "1") {
    runChild(opts.cmd, opts.timeoutMin, (code) => process.exit(code));
    return;
  }

  const since = Date.now();
  const me = { pid: process.pid, label, cwd: process.cwd(), cmd: opts.cmd.join(" ").slice(0, 300), since };
  const ticket = path.join(QUEUE, `${String(since).padStart(15, "0")}-${String(process.pid).padStart(7, "0")}.json`);
  fs.writeFileSync(ticket, JSON.stringify(me));
  const dropTicket = () => fs.rmSync(ticket, { force: true });
  process.on("exit", dropTicket);
  const leaveQueue = (sig) => process.exit(128 + os.constants.signals[sig]);
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, leaveQueue);

  let slot = null;
  let lastNote = 0;
  for (;;) {
    const queue = tickets();
    const position = queue.findIndex((t) => t.file === ticket) + 1;
    const held = holders();
    const reason =
      position === 1 ? waitReason(held, Date.now() - since) : `position ${position} of ${queue.length}, behind ${queue[0]?.label}`;
    if (reason === null) {
      slot = takeSlot({ ...me, since: Date.now(), waited_ms: Date.now() - since, deadline: Date.now() + opts.timeoutMin * 60_000 });
      if (slot) break;
    }
    if (Date.now() - lastNote >= 15_000) {
      lastNote = Date.now();
      console.error(`cstack-gate: ${label} queued ${age(since)}: ${reason ?? "slot race"} · running: ${describe(held)} · load1 ${load1().toFixed(1)}`);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
  dropTicket();
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.off(sig, leaveQueue);
  const waited = Date.now() - since;
  console.error(`cstack-gate: ${label} admitted to ${path.basename(slot)}/${MAX} after ${age(since)} (load1 ${load1().toFixed(1)}, VITEST_MAX_WORKERS=${childEnv().VITEST_MAX_WORKERS}, nice ${NICE})`);
  const release = () => fs.rmSync(slot, { recursive: true, force: true });
  process.on("exit", release);
  fs.appendFileSync(path.join(STATE, "gate.log"), `${new Date().toISOString()} admit ${label} waited_ms=${waited} load1=${load1().toFixed(1)}\n`);
  runChild(opts.cmd, opts.timeoutMin, (code) => {
    release();
    fs.appendFileSync(path.join(STATE, "gate.log"), `${new Date().toISOString()} exit ${label} code=${code} ran_ms=${Date.now() - since - waited}\n`);
    process.exit(code);
  });
}

main().catch((error) => {
  console.error(`cstack-gate: ${error?.stack ?? error}`);
  process.exit(1);
});
