// Hermetic tests for the cstack desk patch on tokenmaxxing 1.10.0 (cstack#25).
// Runs the patched CLI as a subprocess against a throwaway HOME, a file-backed
// fake keychain (TOKENMAXXING_FAKE_KEYCHAIN_DIR) and a local fake token/roles
// server, so nothing here touches the login keychain or platform.claude.com.
//
//   TOKENMAXXING_SRC=/path/to/patched/tokenmaxxing bun test desk.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const SRC = process.env.TOKENMAXXING_SRC ?? join(homedir(), ".bun/install/global/node_modules/tokenmaxxing");
const MAIN = join(SRC, "src", "main.ts");
const USER = "desk-test";
const LIVE_SERVICE = "Claude Code-credentials";
const H = 3_600_000;

const ORG = { A: "aaaaaaaa-0000-4000-8000-00000000000a", B: "bbbbbbbb-0000-4000-8000-00000000000b", C: "cccccccc-0000-4000-8000-00000000000c" } as const;
type Name = keyof typeof ORG;

setDefaultTimeout(60_000);

const tokens = new Map<string, Name>();
const calls = { token: 0, roles: 0 };
type Behavior = "ok" | "rejected" | "invalid_grant" | "claude-only" | "forbidden";
const refreshBehavior = new Map<string, Behavior>();
const secrets: string[] = [];

function secret(kind: "oat" | "ort", name: string): string {
  const s = `sk-ant-${kind}01-desktest-${name}-${Math.random().toString(36).slice(2)}${"x".repeat(40)}`;
  secrets.push(s);
  return s;
}

let server: ReturnType<typeof Bun.serve>;
let base = "";

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/token") {
        calls.token++;
        const body = (await req.json()) as { refresh_token: string };
        const fromClaude = req.headers.get("x-desk-test-client") === "claude-code";
        const behavior = refreshBehavior.get(body.refresh_token) ?? "rejected";
        if (behavior === "claude-only" && !fromClaude) return Response.json({ type: "error", error: { type: "invalid_request_error", message: "Invalid request" } }, { status: 400 });
        if (behavior === "forbidden") return new Response("<html>blocked</html>", { status: 403 });
        if (behavior === "invalid_grant") return Response.json({ error: "invalid_grant", error_description: "Refresh token revoked" }, { status: 400 });
        if (behavior === "rejected") return Response.json({ type: "error", error: { type: "invalid_request_error", message: "Refresh token not found or invalid" } }, { status: 400 });
        const owner = [...tokens.entries()].find(([t]) => t === body.refresh_token)?.[1] ?? "A";
        const access = secret("oat", `${owner}-refreshed`);
        const refresh = secret("ort", `${owner}-refreshed`);
        tokens.set(access, owner);
        tokens.set(refresh, owner);
        refreshBehavior.set(refresh, "ok");
        return Response.json({ access_token: access, refresh_token: refresh, expires_in: 8 * 3600 });
      }
      if (url.pathname === "/roles") {
        calls.roles++;
        const auth = req.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
        const owner = tokens.get(auth);
        if (!owner) return Response.json({ type: "error", error: { type: "authentication_error", message: "Invalid bearer token" } }, { status: 401 });
        return Response.json({ organization_uuid: ORG[owner], organization_name: `org ${owner}` });
      }
      return new Response("not found", { status: 404 });
    },
  });
  base = `http://127.0.0.1:${server.port}`;
});

afterAll(() => server.stop(true));

type Blob = { claudeAiOauth: { accessToken: string; refreshToken: string; expiresAt?: number; scopes: string[]; subscriptionType: string } };

function blob(owner: Name, opts: { expiresIn?: number | null; refresh?: Behavior; known?: boolean } = {}): Blob {
  const access = secret("oat", owner);
  const refresh = secret("ort", owner);
  if (opts.known !== false) tokens.set(access, owner);
  tokens.set(refresh, owner);
  refreshBehavior.set(refresh, opts.refresh ?? "ok");
  const oauth: Blob["claudeAiOauth"] = { accessToken: access, refreshToken: refresh, scopes: ["user:inference", "user:profile"], subscriptionType: "max" };
  if (opts.expiresIn !== null) oauth.expiresAt = Date.now() + (opts.expiresIn ?? 6 * H);
  return { claudeAiOauth: oauth };
}

const FAKE_CLAUDE = `#!/usr/bin/env bun
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const dir = process.env.CLAUDE_CONFIG_DIR ?? "";
const h = new Bun.CryptoHasher("sha256");
h.update(dir.normalize("NFC"));
const service = "Claude Code-credentials-" + h.digest("hex").slice(0, 8);
const file = join(process.env.TOKENMAXXING_FAKE_KEYCHAIN_DIR ?? "", encodeURIComponent(service) + "." + encodeURIComponent(process.env.USER ?? "") + ".json");
const blob = JSON.parse(readFileSync(file, "utf8"));
const res = await fetch(process.env.TOKENMAXXING_OAUTH_TOKEN_URL ?? "", { method: "POST", headers: { "content-type": "application/json", "x-desk-test-client": "claude-code" }, body: JSON.stringify({ grant_type: "refresh_token", refresh_token: blob.claudeAiOauth.refreshToken }) });
if (res.ok) {
  const t = await res.json();
  blob.claudeAiOauth = { ...blob.claudeAiOauth, accessToken: t.access_token, refreshToken: t.refresh_token, expiresAt: Date.now() + t.expires_in * 1000 };
  writeFileSync(file, JSON.stringify(blob));
}
`;

let home = "";
let kc = "";
let tm = "";

const kcFile = (service: string) => join(kc, `${encodeURIComponent(service)}.${encodeURIComponent(USER)}.json`);
const parkedService = (n: Name) => `tokenmaxxing-cred-${ORG[n].slice(0, 8)}`;
const liveFile = () => join(home, ".claude", ".credentials.json");
const readJson = (p: string) => JSON.parse(readFileSync(p, "utf8"));
const accounts = () => readJson(join(tm, "accounts.json")) as { activeAccountUuid: string; accounts: { accountUuid: string; label: string; needsReauth?: boolean; lastRefreshRejected?: { status: number; code: string | null } }[] };
const acct = (n: Name) => accounts().accounts.find((a) => a.accountUuid === ORG[n])!;
const liveToken = () => (readJson(kcFile(LIVE_SERVICE)) as Blob).claudeAiOauth.accessToken;
const fileToken = () => (readJson(liveFile()) as Blob).claudeAiOauth.accessToken;
const parkedToken = (n: Name) => (readJson(kcFile(parkedService(n))) as Blob).claudeAiOauth.accessToken;

function account(n: Name, usage: { five: number; week: number; weekResetH: number }) {
  const oauthAccount = { accountUuid: ORG[n], emailAddress: `${n.toLowerCase()}@desk.test`, organizationUuid: ORG[n], organizationName: `org ${n}` };
  const now = Date.now();
  return {
    accountUuid: ORG[n],
    email: oauthAccount.emailAddress,
    organizationUuid: ORG[n],
    label: n,
    keychainItem: parkedService(n),
    oauthAccount,
    addedAt: new Date(now - 30 * 24 * H).toISOString(),
    lastUsage: { fiveHour: { usedPercentage: usage.five, resetsAt: now + 2 * H }, sevenDay: { usedPercentage: usage.week, resetsAt: now + usage.weekResetH * H } },
    lastUsageAt: now,
  };
}

type Stamp = { at: number; status: number; code: string | null };
const DEAD: Blob = { claudeAiOauth: { accessToken: "", refreshToken: "", expiresAt: 0, scopes: [], subscriptionType: "max" } };

function seed(input: { live: Blob | null; parked: Partial<Record<Name, Blob | string>>; file?: Blob | null; claudeBin?: string; stamps?: Partial<Record<Name, Stamp>>; usage?: Partial<Record<Name, { five: number; week: number; weekResetH: number }>> }) {
  home = mkdtempSync(join(tmpdir(), "tm-desk-"));
  kc = join(home, "fake-keychain");
  tm = join(home, ".config", "tokenmaxxing");
  mkdirSync(kc, { recursive: true });
  mkdirSync(tm, { recursive: true });
  mkdirSync(join(home, ".claude"), { recursive: true });
  const usage = { A: { five: 100, week: 40, weekResetH: 72 }, B: { five: 0, week: 0, weekResetH: 24 }, C: { five: 0, week: 30, weekResetH: 140 }, ...input.usage };
  writeFileSync(join(tm, "accounts.json"), JSON.stringify({ version: 1, activeAccountUuid: ORG.A, accounts: (["A", "B", "C"] as Name[]).map((n) => ({ ...account(n, usage[n]), ...(input.stamps?.[n] ? { lastRefreshRejected: input.stamps[n] } : {}) })) }, null, 2));
  writeFileSync(join(tm, "config.json"), JSON.stringify({ claudeBin: input.claudeBin ?? "/usr/bin/true" }));
  writeFileSync(join(home, ".claude.json"), JSON.stringify({ oauthAccount: account("A", usage.A).oauthAccount }));
  if (input.live) writeFileSync(kcFile(LIVE_SERVICE), JSON.stringify({ ...input.live, mcpOAuth: { keep: "keychain-side" } }));
  if (input.file !== undefined ? input.file : input.live) writeFileSync(liveFile(), JSON.stringify({ ...(input.file ?? input.live), mcpOAuth: { keep: "file-side" } }), { mode: 0o600 });
  for (const [n, b] of Object.entries(input.parked)) writeFileSync(kcFile(parkedService(n as Name)), typeof b === "string" ? b : JSON.stringify(b));
}

async function run(args: string[], extra: Record<string, string> = {}) {
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: home,
    USER,
    NO_COLOR: "1",
    TOKENMAXXING_FAKE_KEYCHAIN_DIR: kc,
    TOKENMAXXING_OAUTH_TOKEN_URL: `${base}/token`,
    TOKENMAXXING_OAUTH_ROLES_URL: `${base}/roles`,
    TOKENMAXXING_LIVE_FILE_MIRROR: "1",
    ...extra,
  };
  const p = Bun.spawn(["bun", "run", MAIN, ...args], { env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  const out = { code: await p.exited, stdout, stderr };
  const logFile = join(tm, "tokenmaxxing.log");
  const log = existsSync(logFile) ? readFileSync(logFile, "utf8") : "";
  for (const s of secrets) {
    expect(out.stdout).not.toContain(s);
    expect(out.stderr).not.toContain(s);
    expect(log).not.toContain(s);
  }
  return out;
}

beforeEach(() => {
  calls.token = 0;
  calls.roles = 0;
});

describe("switch with a refresh endpoint that answers HTTP 400", () => {
  test("an unexpired parked access token is installed without calling the token endpoint", async () => {
    const live = blob("A", { expiresIn: 3 * H });
    const parkedB = blob("B", { expiresIn: 6 * H, refresh: "rejected" });
    seed({ live, parked: { A: blob("A", { expiresIn: 1 * H }), B: parkedB, C: blob("C") } });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("switched to B");
    expect(r.stdout).toContain("refresh skipped");
    expect(calls.token).toBe(0);
    expect(liveToken()).toBe(parkedB.claudeAiOauth.accessToken);
    expect(fileToken()).toBe(parkedB.claudeAiOauth.accessToken);
    expect(accounts().activeAccountUuid).toBe(ORG.B);
    expect(readJson(join(home, ".claude.json")).oauthAccount.accountUuid).toBe(ORG.B);
    expect(parkedToken("A")).toBe(live.claudeAiOauth.accessToken);
    expect(readJson(liveFile()).mcpOAuth).toEqual({ keep: "file-side" });
    expect(readJson(kcFile(LIVE_SERVICE)).mcpOAuth).toEqual({ keep: "keychain-side" });
    expect(statSync(liveFile()).mode & 0o777).toBe(0o600);
    const d = await run(["doctor"]);
    expect(d.stdout).toContain("live access token verifies as active (b@desk.test)");
    expect(d.stdout).toContain("live keychain item and the credentials file hold the same credential");
  });

  test("an expired parked token whose refresh is rejected is not installed and is not marked needs-reauth", async () => {
    const live = blob("A", { expiresIn: 3 * H });
    seed({ live, parked: { B: blob("B", { expiresIn: -1 * H, refresh: "rejected" }), C: blob("C") } });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("refresh_rejected (HTTP 400 invalid_request_error)");
    expect(liveToken()).toBe(live.claudeAiOauth.accessToken);
    expect(accounts().activeAccountUuid).toBe(ORG.A);
    expect(acct("B").needsReauth).toBeFalsy();
    expect(acct("B").lastRefreshRejected).toMatchObject({ status: 400, code: "invalid_request_error" });
    const d = await run(["doctor"]);
    expect(d.stdout).toContain("b@desk.test: parked access expired and last refresh_rejected (HTTP 400 invalid_request_error)");
    expect(d.stdout).toContain("c@desk.test: parked access token verifies (switchable without refresh");
  });

  test("bare switch skips a rejected candidate and lands on the next account with a usable access token", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: blob("B", { expiresIn: -1 * H, refresh: "rejected" }), C: blob("C", { expiresIn: 5 * H, refresh: "rejected" }) } });
    const r = await run(["switch"]);
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("skipping B: access token expired and refresh_rejected (HTTP 400 invalid_request_error)");
    expect(r.stdout).toContain("switched to C");
    expect(accounts().activeAccountUuid).toBe(ORG.C);
    expect(calls.token).toBe(1);
  });

  test("invalid_grant still marks the account needs-reauth and does not install it", async () => {
    const live = blob("A", { expiresIn: 3 * H });
    seed({ live, parked: { B: blob("B", { expiresIn: -1 * H, refresh: "invalid_grant" }), C: blob("C") } });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("B's refresh token is dead");
    expect(acct("B").needsReauth).toBe(true);
    expect(liveToken()).toBe(live.claudeAiOauth.accessToken);
  });

  test("when tokenmaxxing's refresh is rejected, Claude Code refreshes the parked grant and the switch completes", async () => {
    const fake = join(tmpdir(), `tm-desk-fake-claude-${process.pid}.ts`);
    writeFileSync(fake, FAKE_CLAUDE, { mode: 0o755 });
    const parkedB = blob("B", { expiresIn: -1 * H, refresh: "claude-only" });
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: parkedB }, claudeBin: fake });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("switched to B");
    expect(calls.token).toBe(2);
    expect(liveToken()).not.toBe(parkedB.claudeAiOauth.accessToken);
    expect(parkedToken("B")).toBe(liveToken());
    expect(acct("B").lastRefreshRejected).toBeUndefined();
    expect(readFileSync(join(tm, "tokenmaxxing.log"), "utf8")).toContain("swap.refreshed_via_claude");
  });

  test("an expiring parked token still refreshes when the endpoint accepts it", async () => {
    const parkedB = blob("B", { expiresIn: 2 * 60_000, refresh: "ok" });
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: parkedB } });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(0);
    expect(calls.token).toBe(1);
    expect(liveToken()).not.toBe(parkedB.claudeAiOauth.accessToken);
    expect(parkedToken("B")).toBe(liveToken());
  });
});

describe("the periodic check (LaunchAgent) path", () => {
  test("check moves off a 5-hour-exhausted account past a rejected candidate", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: blob("B", { expiresIn: -1 * H, refresh: "rejected" }), C: blob("C", { expiresIn: 5 * H, refresh: "rejected" }) } });
    const now = Date.now();
    writeFileSync(join(tm, "usage.json"), JSON.stringify({ fiveHour: { usedPercentage: 100, resetsAt: now + 2 * H }, sevenDay: { usedPercentage: 40, resetsAt: now + 72 * H }, org: ORG.A, ts: now, model: null }));
    writeFileSync(join(tm, "model-usage.json"), JSON.stringify({ perModel: {}, org: ORG.A, ts: now, sampledAt: now }));
    const r = await run(["check"]);
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("switched to C");
    expect(accounts().activeAccountUuid).toBe(ORG.C);
    expect(liveToken()).toBe(fileToken());
    expect(readFileSync(join(tm, "tokenmaxxing.log"), "utf8")).toContain("decide.candidate_rejected account=bbbbbbbb");
  });
});

describe("harvest of the outgoing live credential", () => {
  test("a live credential with no expiresAt whose refresh is rejected is not parked back", async () => {
    const parkedA = blob("A", { expiresIn: 4 * H });
    seed({ live: blob("A", { expiresIn: null, refresh: "rejected" }), parked: { A: parkedA, B: blob("B") } });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(0);
    expect(parkedToken("A")).toBe(parkedA.claudeAiOauth.accessToken);
  });

  test("a live credential whose refresh is rejected but whose access token still verifies is parked when its slot is empty", async () => {
    const live = blob("A", { expiresIn: 30_000, refresh: "rejected" });
    seed({ live, parked: { B: blob("B") } });
    expect((await run(["switch", "B"])).code).toBe(0);
    expect(parkedToken("A")).toBe(live.claudeAiOauth.accessToken);
  });

  test("a live access token the roles endpoint rejects (401) is not parked back", async () => {
    const parkedA = blob("A", { expiresIn: 4 * H });
    seed({ live: blob("A", { expiresIn: 3 * H, known: false }), parked: { A: parkedA, B: blob("B") } });
    const r = await run(["switch", "B"]);
    expect(r.code).toBe(0);
    expect(parkedToken("A")).toBe(parkedA.claudeAiOauth.accessToken);
  });

  test("a newer parked grant is not overwritten by an older live one", async () => {
    const parkedA = blob("A", { expiresIn: 7 * H });
    seed({ live: blob("A", { expiresIn: 2 * H }), parked: { A: parkedA, B: blob("B") } });
    expect((await run(["switch", "B"])).code).toBe(0);
    expect(parkedToken("A")).toBe(parkedA.claudeAiOauth.accessToken);
  });
});

describe("live file mirror (keychain item <-> ~/.claude/.credentials.json)", () => {
  test("a file refreshed by an SSH worker wins over the stale keychain copy and is parked on switch", async () => {
    const stale = blob("A", { expiresIn: 1 * H });
    const workerRefreshed = blob("A", { expiresIn: 7 * H });
    seed({ live: stale, file: workerRefreshed, parked: { B: blob("B") } });
    writeFileSync(join(tm, "live-mirror.json"), JSON.stringify({ synced: null, ts: Date.now() }));
    const s = await run(["sync-file"]);
    expect(s.code).toBe(0);
    expect(s.stdout).toContain("-> keychain");
    expect(liveToken()).toBe(workerRefreshed.claudeAiOauth.accessToken);
    expect(readJson(kcFile(LIVE_SERVICE)).mcpOAuth).toEqual({ keep: "keychain-side" });
    expect((await run(["switch", "B"])).code).toBe(0);
    expect(parkedToken("A")).toBe(workerRefreshed.claudeAiOauth.accessToken);
  });

  test("a keychain-side change after the last sync is copied to the file", async () => {
    const first = blob("A", { expiresIn: 2 * H });
    seed({ live: first, parked: {} });
    expect((await run(["sync-file"])).stdout).toContain("hold the same live credential");
    const rotated = blob("A", { expiresIn: 1 * H });
    writeFileSync(kcFile(LIVE_SERVICE), JSON.stringify(rotated));
    const s = await run(["sync-file"]);
    expect(s.stdout).toContain("keychain -> ");
    expect(fileToken()).toBe(rotated.claudeAiOauth.accessToken);
  });

  test("a file Claude Code dead-cleared is replaced from the keychain", async () => {
    const good = blob("A", { expiresIn: 2 * H });
    seed({ live: good, file: DEAD, parked: {} });
    await run(["sync-file"]);
    expect(fileToken()).toBe(good.claudeAiOauth.accessToken);
  });

  test("an expired keychain copy is not pushed over a file Claude Code dead-cleared (no refresh ping-pong)", async () => {
    seed({ live: blob("A", { expiresIn: -1 * H }), file: DEAD, parked: {} });
    await run(["sync-file"]);
    expect(fileToken()).toBe("");
  });

  test("an SSH session (keychain locked) cannot switch, says why, and reads the file as live", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: blob("B") } });
    writeFileSync(join(kc, "LOCKED"), "");
    const r = await run(["switch", "B"], { CLAUDE_SECURESTORAGE_CONFIG_DIR: join(home, ".claude") });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("login keychain is not readable from this session");
    expect(accounts().activeAccountUuid).toBe(ORG.A);
    const s = await run(["sync-file"]);
    expect(s.stdout).toContain("is the live store here");
    const d = await run(["doctor"]);
    expect(d.stdout).toContain("login keychain not readable from this session");
  });
});

describe("review follow-ups", () => {
  const lowUsage = { A: { five: 10, week: 10, weekResetH: 100 } };

  test("check moves off a dead live credential even under every usage bar", async () => {
    seed({ live: blob("A", { expiresIn: -1 * H }), file: DEAD, parked: { B: blob("B") }, usage: lowUsage });
    const now = Date.now();
    writeFileSync(join(tm, "usage.json"), JSON.stringify({ fiveHour: { usedPercentage: 10, resetsAt: now + 2 * H }, sevenDay: { usedPercentage: 10, resetsAt: now + 100 * H }, org: ORG.A, ts: now, model: null }));
    const r = await run(["check"]);
    expect(r.stdout).toContain("switched to B");
    expect(accounts().activeAccountUuid).toBe(ORG.B);
    expect(readFileSync(join(tm, "tokenmaxxing.log"), "utf8")).toContain("decide.live_dead");
  });

  test("bare switch moves off a dead live credential that is not over any bar", async () => {
    seed({ live: blob("A", { expiresIn: -1 * H }), file: DEAD, parked: { B: blob("B") }, usage: lowUsage });
    const r = await run(["switch"]);
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("switched to B");
  });

  test("a recently rejected account with under an hour left is skipped without calling the token endpoint", async () => {
    seed({
      live: blob("A", { expiresIn: 3 * H }),
      parked: { B: blob("B", { expiresIn: 5 * H }), C: blob("C", { expiresIn: 30 * 60_000, refresh: "rejected" }) },
      stamps: { C: { at: Date.now() - 5 * 60_000, status: 400, code: "invalid_request_error" } },
      usage: { B: { five: 0, week: 30, weekResetH: 140 }, C: { five: 0, week: 0, weekResetH: 24 } },
    });
    const r = await run(["switch"]);
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("skipping C: refresh_rejected");
    expect(r.stdout).toContain("switched to B");
    expect(calls.token).toBe(0);
  });

  test("an explicit switch retries a recently rejected account", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { C: blob("C", { expiresIn: -1 * H, refresh: "rejected" }) }, stamps: { C: { at: Date.now() - 5 * 60_000, status: 400, code: "invalid_request_error" } } });
    const r = await run(["switch", "C"]);
    expect(r.code).toBe(1);
    expect(calls.token).toBe(1);
  });

  test("a non-OAuth 403 from the token endpoint is transient: skipped, not stamped", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: blob("B", { expiresIn: -1 * H, refresh: "forbidden" }), C: blob("C") } });
    const r = await run(["switch"]);
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("skipping B: token refresh failed (HTTP 403)");
    expect(acct("B").lastRefreshRejected).toBeUndefined();
    expect(acct("B").needsReauth).toBeFalsy();
  });

  test("a corrupt parked item is skipped instead of aborting the switch", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: "{not json", C: blob("C") } });
    const r = await run(["switch"]);
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("skipping B: parked credential does not parse");
    expect(r.stdout).toContain("switched to C");
  });

  test("a check from an SSH session (keychain locked) writes nothing and logs keychain_unavailable", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: { B: blob("B") } });
    const now = Date.now();
    writeFileSync(join(tm, "usage.json"), JSON.stringify({ fiveHour: { usedPercentage: 100, resetsAt: now + 2 * H }, sevenDay: { usedPercentage: 40, resetsAt: now + 72 * H }, org: ORG.A, ts: now, model: null }));
    writeFileSync(join(kc, "LOCKED"), "");
    const before = readFileSync(join(tm, "accounts.json"), "utf8");
    const r = await run(["check"], { CLAUDE_SECURESTORAGE_CONFIG_DIR: join(home, ".claude") });
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("keychain-unavailable");
    expect(accounts().activeAccountUuid).toBe(ORG.A);
    expect(JSON.parse(before).activeAccountUuid).toBe(ORG.A);
    expect(readFileSync(join(tm, "tokenmaxxing.log"), "utf8")).toContain("decide.keychain_unavailable");
  });

  test("a GUI run with CLAUDE_SECURESTORAGE_CONFIG_DIR set is still refused", async () => {
    seed({ live: blob("A", { expiresIn: 3 * H }), parked: {} });
    const r = await run(["status"], { CLAUDE_SECURESTORAGE_CONFIG_DIR: join(home, ".claude") });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("CLAUDE_SECURESTORAGE_CONFIG_DIR is set");
  });

  test("the mirror does not copy a newer side whose token belongs to another account", async () => {
    const stale = blob("A", { expiresIn: 1 * H });
    const foreign = blob("B", { expiresIn: 7 * H });
    seed({ live: stale, file: foreign, parked: {} });
    const s = await run(["sync-file"]);
    expect(s.code).toBe(1);
    expect(liveToken()).toBe(stale.claudeAiOauth.accessToken);
  });
});

