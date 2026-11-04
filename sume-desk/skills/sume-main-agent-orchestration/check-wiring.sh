#!/usr/bin/env bash
# Verify Claude Code and Codex resolve to the same cstack SoT tree
# (chasehuh/cstack), not a forked rsync copy, and the M5 is the Mini.
set -uo pipefail

realpath_py() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || true
}

SKILL_LINK="$HOME/.agents/skills/sume-main-agent-orchestration"
GT_LINK="$HOME/.agents/skills/sume-gt-mq"
CSTACK_SRC="$HOME/.cstack/src"
SOT="$SKILL_LINK/SKILL.md"
fail=0

ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fail=1; }

SKILL_REAL="$(realpath_py "$SKILL_LINK")"
SRC_REAL="$(realpath_py "$CSTACK_SRC")"
GT_REAL="$(realpath_py "$GT_LINK")"

[ -f "$SOT" ] && ok "SoT exists: $SOT" || bad "SoT missing: $SOT"

if [ -n "$SRC_REAL" ] && [ -d "$SRC_REAL/.git" ]; then
  ok "cstack src: $CSTACK_SRC → $SRC_REAL"
  origin="$(git -C "$SRC_REAL" remote get-url origin 2>/dev/null || true)"
  if printf '%s' "$origin" | grep -q 'chasehuh/cstack'; then
    ok "origin is chasehuh/cstack"
  else
    bad "origin is not chasehuh/cstack: ${origin:-missing}"
  fi
  expect="$SRC_REAL/sume-desk/skills/sume-main-agent-orchestration"
  if [ "$SKILL_REAL" = "$expect" ]; then
    ok "orchestration skill is the cstack tree (not a rsync copy)"
  else
    bad "orchestration skill $SKILL_REAL != $expect"
  fi
  expect_gt="$SRC_REAL/sume-desk/skills/sume-gt-mq"
  if [ "$GT_REAL" = "$expect_gt" ]; then
    ok "sume-gt-mq skill is the cstack tree"
  else
    bad "sume-gt-mq $GT_REAL != $expect_gt"
  fi
else
  bad "missing ~/.cstack/src git checkout"
fi

grep -q "## The desk today" "$SOT" \
  && ok "SoT has The desk today" \
  || bad "SoT missing The desk today section"

HOSTS_ENV="$SRC_REAL/sume-desk/hosts.env"
m5=$(sed -n 's/^CSTACK_MINI_SSH_M5=//p' "$HOSTS_ENV" 2>/dev/null | tail -n 1)
have=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}CSTACK_MINI_SSH=//p' "$HOME/.cstack/mini-ssh.env" 2>/dev/null | tail -n 1 | tr -d "\"'")
if [ -n "$m5" ] && [ "$have" = "$m5" ]; then
  ok "~/.cstack/mini-ssh.env → M5 ($m5)"
else
  bad "~/.cstack/mini-ssh.env CSTACK_MINI_SSH=${have:-missing}, want M5 ${m5:-?} (re-run install.sh)"
fi

GT_SKILL="$GT_LINK/SKILL.md"
if [ -f "$GT_SKILL" ]; then
  if grep -q "cstack-gt-wait-merge" "$GT_SKILL"; then
    ok "gt-mq cook is cstack-gt-wait-merge"
  else
    bad "gt-mq SKILL.md missing cstack-gt-wait-merge"
  fi
  if grep -q "sleep 20   # 15" "$GT_SKILL"; then
    bad "gt-mq SKILL.md still has the old 20s grep cookbook"
  else
    ok "gt-mq SKILL.md has no old 20s grep cookbook"
  fi
else
  bad "gt-mq SKILL.md missing"
fi

if command -v cstack-gt-wait-merge >/dev/null 2>&1; then
  ok "cstack-gt-wait-merge on PATH"
else
  bad "cstack-gt-wait-merge not on PATH"
fi

if command -v cstack-clone >/dev/null 2>&1; then
  ok "cstack-clone on PATH"
else
  bad "cstack-clone not on PATH"
fi

# Skill discovery per harness — compare realpaths (hub may be a symlink).
for dir in "$HOME/.codex/skills" "$HOME/.claude/skills"; do
  link="$dir/sume-main-agent-orchestration"
  if [ -e "$link" ] || [ -L "$link" ]; then
    target="$(realpath_py "$link")"
    if [ -n "$SKILL_REAL" ] && [ "$target" = "$SKILL_REAL" ]; then
      ok "symlink resolves: $link"
    else
      bad "symlink broken or wrong target: $link -> ${target:-missing} (want $SKILL_REAL)"
    fi
  else
    bad "symlink missing: $link"
  fi
done

# Codex entry point (Claude Code inherits it via CLAUDE.md import).
grep -q "sume-main-agent-orchestration/SKILL.md" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry point references SoT" \
  || bad "codex entry point missing SoT reference: ~/.codex/AGENTS.md"


grep -q "Sume worker mode (always on)" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry has the worker-mode lock (sume#7839)" \
  || bad "codex entry missing worker-mode lock: re-run install.sh"

grep -q "Sume code comments (always on)" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry has the no-code-comments rule (docs/CODE-COMMENTS.md)" \
  || bad "codex entry missing no-code-comments rule: re-run install.sh"

grep -q "Sume feature flags (always on)" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry has the no-feature-flags rule (docs/FEATURE-FLAGS.md)" \
  || bad "codex entry missing no-feature-flags rule: re-run install.sh"

grep -q "Sume release lock (always on)" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry has the release lock (docs/RELEASE-LOCK.md)" \
  || bad "codex entry missing release lock: re-run install.sh"

grep -q "Sume browser: ego-browser only (always on)" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry has the ego-browser-only rule (docs/BROWSER.md)" \
  || bad "codex entry missing ego-browser-only rule: re-run install.sh"

grep -q "codex/AGENTS.md" "$HOME/.claude/CLAUDE.md" \
  && ok "claude imports codex entry point" \
  || bad "claude entry point does not import ~/.codex/AGENTS.md"

exit $fail
