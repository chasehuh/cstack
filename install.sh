#!/usr/bin/env bash
# Install the Sume desk flow onto this machine so any agent follows it.
# Real SoT is this checkout of chasehuh/cstack (pointed at ~/.cstack/src).
# Usage:
#   ./install.sh
#   ./install.sh --sume-com /path/to/sume-com
# One-click refresh:
#   ./bootstrap.sh --sume-com ~/sume/sume-com
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK="$ROOT/sume-desk"
SUME_COM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sume-com)
      SUME_COM="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--sume-com <path>]" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$DESK/skills/sume-main-agent-orchestration" ]; then
  echo "missing pack: $DESK/skills/sume-main-agent-orchestration" >&2
  exit 1
fi

mkdir -p "$HOME/.cstack/state" "$HOME/.cstack/state/prompts"
# Machine SoT: prefer a real clone at ~/.cstack/src. Never ln -sfn a
# directory onto itself (that replaces the clone with a broken symlink).
CANON="$HOME/.cstack/src"
ROOT_REAL="$(cd "$ROOT" && pwd)"
if [ -d "$CANON/.git" ] && [ "$(cd "$CANON" && pwd)" = "$ROOT_REAL" ]; then
  echo "SoT checkout is $CANON"
elif [ -e "$CANON" ] && [ ! -L "$CANON" ] && [ -d "$CANON/.git" ]; then
  echo "NOTE: $CANON is a real clone; not retargeting it to $ROOT_REAL"
  echo "      Re-run $CANON/install.sh (or ./bootstrap.sh) to publish that tree."
else
  ln -sfn "$ROOT_REAL" "$CANON"
  echo "SoT pointer: ~/.cstack/src → $ROOT_REAL"
fi

# Move wrapper logs out of the skill tree before we replace rsync copies
# with symlinks into the git checkout.
OLD_STATE="$HOME/.agents/skills/sume-main-agent-orchestration/state"
if [ -d "$OLD_STATE" ] && [ ! -L "$HOME/.agents/skills/sume-main-agent-orchestration" ]; then
  rsync -a "$OLD_STATE/" "$HOME/.cstack/state/"
  echo "migrated runtime state → ~/.cstack/state"
fi

link_skill() {
  local name="$1"
  local src="$DESK/skills/$name"
  local dest="$HOME/.agents/skills/$name"
  [ -d "$src" ] || return 0
  mkdir -p "$HOME/.agents/skills"
  if [ -L "$dest" ]; then
    ln -sfn "$src" "$dest"
  elif [ -d "$dest" ]; then
    rm -rf "$dest"
    ln -sfn "$src" "$dest"
  else
    ln -sfn "$src" "$dest"
  fi
  echo "skill SoT: $dest → $src"
  for harness in "$HOME/.claude/skills" "$HOME/.codex/skills" \
                 "$HOME/.cursor/skills"; do
    mkdir -p "$harness"
    ln -sfn "$src" "$harness/$name"
    echo "linked: $harness/$name"
  done
}

echo "== skills (symlink → cstack, not rsync copy) =="
link_skill sume-main-agent-orchestration
link_skill sume-gt-mq
link_skill github-mega-issue
link_skill mobidoo-live-commerce-update
# Engineering skills adapted from pstack (docs/PSTACK.md).
link_skill sume-principles
link_skill sume-architect
link_skill sume-blast-radius
link_skill sume-automate-me
# Simplified Technical English (docs/STE.md).
link_skill sume-ste

echo "== user Cursor rules =="
mkdir -p "$HOME/.cursor/rules"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$DESK/cursor-rules/user/" "$HOME/.cursor/rules/"
else
  cp -a "$DESK/cursor-rules/user/." "$HOME/.cursor/rules/"
fi

if [ -n "$SUME_COM" ]; then
  echo "== sume-com repo rules → $SUME_COM =="
  mkdir -p "$SUME_COM/.cursor/rules"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$DESK/cursor-rules/sume-com/" "$SUME_COM/.cursor/rules/"
  else
    cp -a "$DESK/cursor-rules/sume-com/." "$SUME_COM/.cursor/rules/"
  fi
fi

echo "== host bins on PATH =="
mkdir -p "$HOME/.local/bin"
BIN="$HOME/.agents/skills/sume-main-agent-orchestration/bin"
GTBIN="$HOME/.agents/skills/sume-gt-mq/bin"
ln -sfn "$BIN/agent-human-stream.sh" "$HOME/.local/bin/agent-human-stream"
ln -sfn "$BIN/claude-human-stream.sh" "$HOME/.local/bin/claude-human-stream"
ln -sfn "$BIN/sume-bg-launch.sh" "$HOME/.local/bin/sume-bg-launch"
# Mini side of --host mini; installed on every machine so laptop and Mini
# run the same checkout (docs/MINI-WORKER-HOST.md).
ln -sfn "$BIN/sume-bg-remote.sh" "$HOME/.local/bin/sume-bg-remote"
# Mini crontab entry point (docs/MINI-CRON.md).
ln -sfn "$BIN/sume-cron-job.sh" "$HOME/.local/bin/sume-cron-job"
# Worker completion report → #coding-agents (docs/SLACK-REPORT.md).
ln -sfn "$BIN/cstack-slack-post.sh" "$HOME/.local/bin/cstack-slack-post"
ln -sfn "$GTBIN/cstack-clone.sh" "$HOME/.local/bin/cstack-clone"
ln -sfn "$GTBIN/cstack-clone-rm.sh" "$HOME/.local/bin/cstack-clone-rm"
ln -sfn "$GTBIN/cstack-mirror-sync.sh" "$HOME/.local/bin/cstack-mirror-sync"
ln -sfn "$GTBIN/cstack-gt-wait-merge.sh" "$HOME/.local/bin/cstack-gt-wait-merge"
# Heavy-gate admission + ego task-space reaper (sume#12962).
ln -sfn "$GTBIN/cstack-gate.mjs" "$HOME/.local/bin/cstack-gate"
ln -sfn "$BIN/cstack-ego-reap.mjs" "$HOME/.local/bin/cstack-ego-reap"
ln -sfn "$BIN/cstack-kill-guard.sh" "$HOME/.local/bin/pkill"
ln -sfn "$BIN/cstack-kill-guard.sh" "$HOME/.local/bin/killall"
chmod +x "$BIN/agent-human-stream.sh" "$BIN/agent-human-stream.py" \
  "$BIN/agent-human-stream.test.py" \
  "$BIN/claude-human-stream.sh" "$BIN/claude-human-stream.py" \
  "$BIN/sume-bg-launch.sh" "$BIN/sume-bg-remote.sh" "$BIN/sume-bg-launch.test.sh" \
  "$BIN/sume-cron-job.sh" "$BIN/sume-cron-job.test.sh" \
  "$BIN/cstack-slack-post.sh" "$BIN/slack-report.test.sh" \
  "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" \
  "$HOME/.agents/skills/sume-gt-mq/install-symlinks.sh" \
  "$GTBIN/cstack-clone.sh" "$GTBIN/cstack-clone-rm.sh" \
  "$GTBIN/cstack-mirror-sync.sh" "$GTBIN/cstack-gt-wait-merge.sh" \
  "$GTBIN/cstack-gt-wait-merge.test.sh" \
  "$GTBIN/cstack-gate.mjs" "$BIN/cstack-ego-reap.mjs" "$BIN/cstack-kill-guard.sh" \
  "$DESK/skills/sume-principles/sync-from-pstack.sh" \
  "$DESK/skills/sume-ste/sync-from-upstream.sh" \
  "$DESK/skills/sume-ste/scripts/ste_check.py" \
  "$ROOT/bootstrap.sh" || true
echo "== gh stack extension =="
if command -v gh >/dev/null 2>&1; then
  if ! gh extension list 2>/dev/null | grep -q 'github/gh-stack'; then
    gh extension install github/gh-stack || echo "warn: gh extension install github/gh-stack failed" >&2
  fi
fi
if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  echo "NOTE: add \$HOME/.local/bin to PATH (e.g. in ~/.zshrc)"
fi

# Codex owns the full pointer snippet; Claude Code imports it via
# `@~/.codex/AGENTS.md` (check-wiring.sh asserts that import exists).
append_entry() {
  local f="$1" snip="$2" marker="$3"
  [ -f "$snip" ] || return 0
  mkdir -p "$(dirname "$f")"
  touch "$f"
  if ! grep -q "$marker" "$f"; then
    echo "" >> "$f"
    cat "$snip" >> "$f"
    echo "appended pointer: $f"
  fi
}
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/codex-agents-snippet.md" \
  "sume-main-agent-orchestration/SKILL.md"
append_entry "$HOME/.claude/CLAUDE.md" \
  "$ROOT/sume-desk/claude-import-snippet.md" \
  "codex/AGENTS.md"
# Separate marker upgrades existing main-agent imports on laptop and Mini.
# Workers must see the completion lock even when they skip orchestration.
append_entry "$HOME/.claude/CLAUDE.md" \
  "$ROOT/sume-desk/claude-author-snippet.md" \
  "## Sume author completion (always on)"
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/worker-mode-snippet.md" \
  "## Sume worker mode (always on)"
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/code-comments-snippet.md" \
  "## Sume code comments (always on)"
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/feature-flags-snippet.md" \
  "## Sume feature flags (always on)"
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/release-lock-snippet.md" \
  "## Sume release lock (always on)"
append_entry "$HOME/.codex/AGENTS.md" \
  "$ROOT/sume-desk/browser-snippet.md" \
  "## Sume browser: ego-browser only (always on)"

refresh_section() {
  local f="$1" snip="$2"
  [ -f "$f" ] && [ -f "$snip" ] || return 0
  python3 - "$f" "$snip" <<'PY'
import sys

path, snip = sys.argv[1], sys.argv[2]
with open(snip, encoding="utf-8") as fh:
    new = fh.read().rstrip("\n") + "\n"
heading = new.splitlines()[0]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines(keepends=True)
starts = [i for i, line in enumerate(lines) if line.rstrip("\n") == heading]
if len(starts) != 1:
    raise SystemExit(0)
start = starts[0]
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
if "".join(lines[start:end]).rstrip("\n") + "\n" == new:
    raise SystemExit(0)
lines[start:end] = [new + ("\n" if end < len(lines) else "")]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("".join(lines))
print(f"refreshed pointer: {path} ({heading})")
PY
}
refresh_section "$HOME/.codex/AGENTS.md" "$ROOT/sume-desk/codex-agents-snippet.md"
refresh_section "$HOME/.claude/CLAUDE.md" "$ROOT/sume-desk/claude-author-snippet.md"
refresh_section "$HOME/.codex/AGENTS.md" "$ROOT/sume-desk/worker-mode-snippet.md"
refresh_section "$HOME/.codex/AGENTS.md" "$ROOT/sume-desk/browser-snippet.md"
refresh_section "$HOME/.claude/CLAUDE.md" "$ROOT/sume-desk/claude-import-snippet.md"

# Existing snippets keep the old marker, so append the wait cook if missing.
ensure_wait_hint() {
  local f="$1"
  [ -f "$f" ] || return 0
  if ! grep -q "cstack-gt-wait-merge" "$f"; then
    printf '\nAfter `gh stack submit` on sume-com, run `cstack-gt-wait-merge` (do not hand-roll a sleep/grep loop).\n' >> "$f"
    echo "updated wait hint: $f"
  fi
}
ensure_wait_hint "$HOME/.codex/AGENTS.md"
ensure_wait_hint "$HOME/.claude/CLAUDE.md"

python3 - "$ROOT/sume-desk/hosts.env" "$HOME/.cstack/mini-ssh.env" <<'PY'
import os, re, sys, time

hosts, target = sys.argv[1], sys.argv[2]
want = None
with open(hosts, encoding="utf-8") as fh:
    for line in fh:
        m = re.match(r"\s*CSTACK_MINI_SSH_M5=(\S+)", line)
        if m:
            want = m.group(1).strip("'\"")
if not want:
    raise SystemExit(0)
new_line = f"export CSTACK_MINI_SSH={want}\n"
old = open(target, encoding="utf-8").read() if os.path.exists(target) else ""
lines = old.splitlines(keepends=True)
pat = re.compile(r"\s*(export\s+)?CSTACK_MINI_SSH=")
out, seen = [], False
for line in lines:
    if pat.match(line):
        if not seen:
            out.append(new_line)
            seen = True
        continue
    out.append(line if line.endswith("\n") else line + "\n")
if not seen:
    out.append(new_line)
new = "".join(out)
if new != old:
    if old:
        bak = f"{target}.bak.{time.strftime('%Y%m%dT%H%M%S')}"
        with open(bak, "w", encoding="utf-8") as fh:
            fh.write(old)
        print(f"mini host: {target} → {want} (old file kept as {bak})")
    else:
        print(f"mini host: wrote {target} → {want}")
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(new)
PY

if [ -x "$GTBIN/cstack-gt-wait-merge.test.sh" ]; then
  echo "== cstack-gt-wait-merge matcher =="
  "$GTBIN/cstack-gt-wait-merge.test.sh"
fi

if [ -x "$BIN/sume-bg-launch.test.sh" ] && [ "${CSTACK_SKIP_HOST_TESTS:-0}" != "1" ]; then
  echo "== sume-bg-launch host routing (offline, no Mini) =="
  "$BIN/sume-bg-launch.test.sh" || echo "NOTE: sume-bg-launch host tests failed (CSTACK_SKIP_HOST_TESTS=1 to skip)"
  echo "== sume-cron-job (offline) =="
  "$BIN/sume-cron-job.test.sh" || echo "NOTE: sume-cron-job tests failed (CSTACK_SKIP_HOST_TESTS=1 to skip)"
  echo "== slack-report tail (offline) =="
  "$BIN/slack-report.test.sh" || echo "NOTE: slack-report tests failed (CSTACK_SKIP_HOST_TESTS=1 to skip)"
fi

if [ -x "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" ]; then
  echo "== wiring check =="
  "$HOME/.agents/skills/sume-main-agent-orchestration/check-wiring.sh" || true
fi

echo ""
echo "== tokenmaxxing (local Claude supervisor) =="
if command -v tokenmaxxing >/dev/null 2>&1; then
  # Desk build: pinned 1.10.0 + cstack patch (no-op unless 1.10.0 is installed).
  "$DESK/tokenmaxxing/install-tokenmaxxing-desk.sh" --if-pinned \
    || echo "WARN: tokenmaxxing desk patch not applied - see docs/TOKENMAXXING.md"
  tokenmaxxing doctor || true
  echo "Claude workers use tokenmaxxing — see docs/TOKENMAXXING.md"
else
  echo "NOTE: tokenmaxxing not on PATH. Opus/Fable expect the supervisor"
  echo "      (~/.config/tokenmaxxing/bin ahead of real claude)."
  echo "      Install: bun add -g tokenmaxxing@1.10.0 && tokenmaxxing init"
  echo "      Docs: $ROOT/docs/TOKENMAXXING.md"
fi

if [ -x "$HOME/.local/bin/cstack-mirror-sync" ]; then
  echo "== cstack mirror (sume-com objects) =="
  "$HOME/.local/bin/cstack-mirror-sync" || echo "NOTE: seed later with cstack-mirror-sync"
fi

echo ""
echo "Installed. SoT is chasehuh/cstack (this checkout), not a rsync fork."
echo "pointer: ~/.cstack/src"
echo "policy:  ~/.agents/skills/sume-main-agent-orchestration/SKILL.md"
echo "land:    ~/.agents/skills/sume-gt-mq/SKILL.md"
echo "land:    cstack-gt-wait-merge  (after gh stack submit: validate green → GitHub merge queue)"
echo "clone:   cstack-clone / cstack-clone-rm / cstack-mirror-sync"
echo "state:   ~/.cstack/state/opus-live"
echo "slack:   workers post one Korean report to #coding-agents at completion (opt out: --no-slack-report / CSTACK_SLACK_REPORT=0) — docs/SLACK-REPORT.md"
echo "mini:    sume-bg-launch --host mini = the M5 (sume-desk/hosts.env → ~/.cstack/mini-ssh.env) — docs/MINI-WORKER-HOST.md"
echo "prompts: ~/.cstack/state/prompts (sume-bg-launch --prompt-dir)"
echo "harness: Claude Code main agent + Opus workers on the M5 (Codex reads the same entry)"
echo "LC:      ~/.agents/skills/mobidoo-live-commerce-update/SKILL.md"
echo "eng:     sume-architect / sume-blast-radius / sume-principles / sume-automate-me (pstack-derived, docs/PSTACK.md)"
echo "ste:     sume-ste (English technical docs only, docs/STE.md)"
echo "Claude:  docs/TOKENMAXXING.md (tokenmaxxing pool, not a single login)"
echo "Do not copy API keys / PEMs / tokenmaxxing accounts.json into this repo."
