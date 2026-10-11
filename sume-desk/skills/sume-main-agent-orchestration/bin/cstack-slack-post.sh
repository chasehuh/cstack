#!/usr/bin/env bash
# Post a worker's completion report to Slack #coding-agents as ONE thread reply
# (docs/SLACK-REPORT.md). Runs through the ego-browser Slack web client that
# is signed in as Chase on desk Macs; there is no bot token on the desk.
#
#   cstack-slack-post --job <slug> --text-file <path> [--issue N] [--title "<short what>"] \
#                     [--file <clip-or-image>]… [--lane Opus] [--dry-run]
#
# Thread: the newest #coding-agents parent that names the job slug, the
# issue (#N), or starts with --title. None → a new parent
# "<title> — `<Lane> : <slug> (#N)`", then the report as its first reply.
# Files (10 at most) go on that same reply. --dry-run finds the thread and
# posts nothing. Prints `SLACK: <permalink>` (exit 0) or
# `SLACK: not posted — <reason>` (exit 1; exit 2 for a bad text or argument).
# The Slack token stays inside the page; it is never printed.
set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  DIR=$(cd "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done

CHANNEL="${CSTACK_SLACK_CHANNEL:-C0A9L7AU5HS}"
TEAM="${CSTACK_SLACK_TEAM:-T0A8XBLULMD}"
EXPECT_USER="${CSTACK_SLACK_USER:-chase}"
EGO="${CSTACK_SLACK_EGO:-ego-browser}"
MAX_CHARS=600

JOB=""
TEXT_FILE=""
ISSUE=""
TITLE=""
LANE=""
DRY_RUN=0
FILES=()

usage() { sed -n '2,15p' "$SOURCE" | sed 's/^# \{0,1\}//'; }
bad() { echo "SLACK: not posted — $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB=${2:-}; shift 2 ;;
    --text-file) TEXT_FILE=${2:-}; shift 2 ;;
    --issue) ISSUE=${2#\#}; shift 2 ;;
    --title) TITLE=${2:-}; shift 2 ;;
    --lane) LANE=${2:-}; shift 2 ;;
    --file) FILES+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) bad "unknown option $1" ;;
  esac
done

[[ "$JOB" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || bad "--job <slug> required ([a-zA-Z0-9._-])"
[[ -z "$ISSUE" || "$ISSUE" =~ ^[0-9]+$ ]] || bad "--issue takes a number"
[[ -s "$TEXT_FILE" ]] || bad "--text-file missing or empty: $TEXT_FILE"
if grep -Eq 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abcp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY' "$TEXT_FILE"; then
  bad "text looks like it contains a credential; remove it"
fi
CHARS=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().strip()))' "$TEXT_FILE")
[[ "$CHARS" -le "$MAX_CHARS" ]] || bad "text is $CHARS characters; the report limit is $MAX_CHARS"
[[ ${#FILES[@]} -le 10 ]] || bad "at most 10 files per reply (got ${#FILES[@]})"
ABS_FILES=()
for f in "${FILES[@]+"${FILES[@]}"}"; do
  [[ -f "$f" ]] || bad "--file not found: $f"
  ABS_FILES+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")
done

if [[ -z "$LANE" ]]; then
  _m=$(printf '%s' "${AGENT_HUMAN_STREAM_MODEL:-}" | tr '[:upper:]' '[:lower:]')
  case "${AGENT_HUMAN_STREAM_BACKEND:-claude}" in
    grok) LANE=Grok ;;
    codex) LANE=Codex ;;
    *)
      case "$_m" in
        *fable*) LANE=Fable ;;
        *sonnet*) LANE=Sonnet ;;
        *haiku*) LANE=Haiku ;;
        *) LANE=Opus ;;
      esac
      ;;
  esac
fi

command -v "$EGO" >/dev/null 2>&1 || { echo "SLACK: not posted — $EGO not on PATH (print SLACK_TEXT: in the final block)"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The page script gets its config as a JSON literal (ego's node does not see this env).
python3 - "$TMP/script.mjs" "$TEXT_FILE" "$JOB" "$ISSUE" "$TITLE" "$LANE" "$CHANNEL" "$TEAM" "$EXPECT_USER" "$DRY_RUN" "${ABS_FILES[@]+"${ABS_FILES[@]}"}" <<'PY'
import json, sys
out, text_file, job, issue, title, lane, channel, team, user, dry, *files = sys.argv[1:]
cfg = {
    "text": open(text_file, encoding="utf-8").read().strip(),
    "job": job, "issue": issue, "title": title, "lane": lane,
    "channel": channel, "team": team, "user": user,
    "dryRun": dry == "1", "files": files,
}
js = r"""
const cfg = __CFG__;
const task = await taskSpace(`slack post ${cfg.job}`);
const page = task.page("p1");
await page.goto(`https://app.slack.com/client/${cfg.team}/${cfg.channel}`);
await page.waitForFunction((team) => {
  try { return !!JSON.parse(localStorage.localConfig_v2).teams[team].token; } catch { return false; }
}, cfg.team, { timeout: 45000 });
if (cfg.files.length && !cfg.dryRun) {
  await page.evaluate(() => {
    const input = document.createElement("input");
    input.type = "file"; input.multiple = true; input.id = "cstack-slack-files"; input.style.display = "none";
    document.body.appendChild(input);
  });
  await page.setInputFiles("#cstack-slack-files", cfg.files);
}
const r = await page.evaluate(async (cfg) => {
  const token = JSON.parse(localStorage.localConfig_v2).teams[cfg.team].token;
  const call = async (method, params) => {
    const form = new FormData();
    form.append("token", token);
    for (const [k, v] of Object.entries(params)) form.append(k, v);
    return (await fetch(`/api/${method}`, { method: "POST", body: form })).json();
  };
  const me = await call("auth.test", {});
  if (!me.ok) return { ok: false, error: `auth.test: ${me.error}` };
  if (cfg.user && me.user !== cfg.user) return { ok: false, error: `Slack web client is signed in as ${me.user}, not ${cfg.user}` };

  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const slugRe = new RegExp(`(^|[^a-z0-9-])${esc(cfg.job.toLowerCase())}([^a-z0-9-]|$)`);
  const issueRe = cfg.issue ? new RegExp(`(#|/issues/|/pull/)${cfg.issue}(?![0-9])`) : null;
  const title = (cfg.title || "").trim().toLowerCase();
  const names = (text) => {
    const t = (text || "").toLowerCase();
    return slugRe.test(t) || (issueRe && issueRe.test(t)) ||
      (title && (t === title || t.startsWith(`${title} `)));
  };
  let thread = null;
  let cursor = "";
  for (let i = 0; i < 3 && !thread; i++) {
    const h = await call("conversations.history", { channel: cfg.channel, limit: "200", ...(cursor ? { cursor } : {}) });
    if (!h.ok) return { ok: false, error: `conversations.history: ${h.error}` };
    const hit = (h.messages || []).find((m) => !m.thread_ts || m.thread_ts === m.ts ? names(m.text) : false);
    if (hit) thread = hit.ts;
    cursor = h.response_metadata?.next_cursor || "";
    if (!cursor) break;
  }
  if (!thread) {
    const s = await call("search.messages", { query: `${cfg.job} in:<#${cfg.channel}>`, count: "20", sort: "timestamp" });
    const hit = (s.messages?.matches || []).find((m) => names(m.text));
    if (hit) thread = (hit.permalink || "").match(/thread_ts=([\d.]+)/)?.[1] || hit.ts;
  }
  const parentText = `${cfg.title || cfg.job} — \`${cfg.lane} : ${cfg.job}${cfg.issue ? ` (#${cfg.issue})` : ""}\``;
  const link = async (ts) => (await call("chat.getPermalink", { channel: cfg.channel, message_ts: ts })).permalink || null;
  if (cfg.dryRun) {
    return { ok: true, dryRun: true, user: me.user, thread: thread ? await link(thread) : null,
             newParent: thread ? null : parentText, chars: cfg.text.length };
  }
  let created = false;
  if (!thread) {
    const p = await call("chat.postMessage", { channel: cfg.channel, text: parentText });
    if (!p.ok) return { ok: false, error: `parent chat.postMessage: ${p.error}` };
    thread = p.ts;
    created = true;
  }
  const input = document.getElementById("cstack-slack-files");
  const files = input ? [...input.files] : [];
  if (!files.length) {
    const p = await call("chat.postMessage", { channel: cfg.channel, thread_ts: thread, text: cfg.text });
    if (!p.ok) return { ok: false, error: `chat.postMessage: ${p.error}`, thread: await link(thread) };
    return { ok: true, created, link: await link(p.ts) };
  }
  const ids = [];
  for (const file of files) {
    const u = await call("files.getUploadURLExternal", { filename: file.name, length: String(file.size) });
    if (!u.ok) return { ok: false, error: `files.getUploadURLExternal: ${u.error}`, thread: await link(thread) };
    const form = new FormData();
    form.append("file", file);
    const up = await fetch(u.upload_url, { method: "POST", body: form });
    if (!up.ok) return { ok: false, error: `upload ${file.name}: HTTP ${up.status}`, thread: await link(thread) };
    ids.push({ id: u.file_id, title: file.name });
  }
  const c = await call("files.completeUploadExternal", {
    files: JSON.stringify(ids), channel_id: cfg.channel, thread_ts: thread, initial_comment: cfg.text,
  });
  if (!c.ok) return { ok: false, error: `files.completeUploadExternal: ${c.error}`, thread: await link(thread) };
  const want = new Set(ids.map((f) => f.id));
  for (let i = 0; i < 10; i++) {
    await new Promise((res) => setTimeout(res, 1500));
    const rep = await call("conversations.replies", { channel: cfg.channel, ts: thread, limit: "200" });
    const msg = (rep.messages || []).reverse().find((m) => (m.files || []).some((f) => want.has(f.id)));
    if (msg) return { ok: true, created, link: await link(msg.ts) };
  }
  return { ok: true, created, link: await link(thread), note: "files posted; reply link not found yet, thread link given" };
}, cfg);
console.log("CSTACK_SLACK_RESULT " + JSON.stringify(r));
if (r.ok) await task.finish({ keep: [] });
"""
open(out, "w", encoding="utf-8").write(js.replace("__CFG__", json.dumps(cfg, ensure_ascii=False)))
PY

set +e
OUT=$("$EGO" nodejs <"$TMP/script.mjs" 2>&1)
RC=$?
set -e
LINE=$(printf '%s\n' "$OUT" | sed -n 's/^CSTACK_SLACK_RESULT //p' | tail -n 1)
if [[ -z "$LINE" ]]; then
  echo "SLACK: not posted — ego-browser run failed (rc=$RC): $(printf '%s' "$OUT" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
  exit 1
fi
python3 - "$LINE" "$CHARS" <<'PY'
import json, sys
r, chars = json.loads(sys.argv[1]), sys.argv[2]
if not r.get("ok"):
    print(f"SLACK: not posted — {r.get('error')}" + (f" (thread: {r['thread']})" if r.get("thread") else ""))
    sys.exit(1)
if r.get("dryRun"):
    where = r.get("thread") or f"new parent: {r.get('newParent')}"
    print(f"dry run ({chars} chars, signed in as {r.get('user')}): would reply in {where}")
    sys.exit(0)
if r.get("created"):
    print("new parent posted for this job")
if r.get("note"):
    print(f"note: {r['note']}")
print(f"SLACK: {r.get('link')}")
PY
