#!/usr/bin/env bash
# Verify Cursor, Claude Code, Codex, and Grok Build all resolve to the
# same cstack SoT tree (chasehuh/cstack), not a forked rsync copy.
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

grep -q "Harness Scope" "$SOT" \
  && ok "SoT has Harness Scope" \
  || bad "SoT missing Harness Scope section"

grep -q "Cursor-only — Opus / background-worker monitoring" "$SOT" \
  && ok "SoT has Cursor-only Opus monitoring" \
  || bad "SoT missing Cursor-only Opus monitoring section"

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

if [ -f "$HOME/.grok/hooks/sume-desk.json" ] && grep -q "grok-desk-hook.sh" "$HOME/.grok/hooks/sume-desk.json"; then
  ok "Grok desk hook installed (~/.grok/hooks/sume-desk.json)"
else
  bad "Grok desk hook missing: run install.sh (sumelabs/sume#5706)"
fi

if command -v agent-holders >/dev/null 2>&1; then
  ok "agent-holders on PATH"
else
  bad "agent-holders not on PATH (steer-kill helper)"
fi

if command -v cstack-clone >/dev/null 2>&1; then
  ok "cstack-clone on PATH"
else
  bad "cstack-clone not on PATH"
fi

# Skill discovery per harness — compare realpaths (hub may be a symlink).
for dir in "$HOME/.codex/skills" "$HOME/.claude/skills" \
           "$HOME/.cursor/skills" "$HOME/.grok/skills"; do
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

grep -q "Cursor-only" "$HOME/.codex/AGENTS.md" \
  && ok "codex entry notes Cursor-only ignore" \
  || bad "codex entry missing Cursor-only ignore note"

grep -q "codex/AGENTS.md" "$HOME/.claude/CLAUDE.md" \
  && ok "claude imports codex entry point" \
  || bad "claude entry point does not import ~/.codex/AGENTS.md"

if [ -f "$HOME/.grok/AGENTS.md" ] && grep -q "sume-main-agent-orchestration/SKILL.md" "$HOME/.grok/AGENTS.md"; then
  ok "grok entry point references SoT"
else
  bad "grok entry point missing SoT reference: ~/.grok/AGENTS.md"
fi

# Cursor pointer rules must stay pointers, not forked copies.
check_pointer() {
  local rule="$1"
  if [ ! -f "$rule" ]; then
    bad "cursor pointer missing: $rule"
    return
  fi
  if ! grep -q "sume-main-agent-orchestration/SKILL.md" "$rule"; then
    bad "cursor rule does not point at SoT: $rule"
    return
  fi
  if grep -qE "Pipeline 1|Opus owns PR authoring|Never use Opus 5 for code" "$rule"; then
    bad "cursor rule forked SoT content: $rule"
  else
    ok "cursor pointer rule: $rule"
  fi
}

check_pointer "$HOME/.cursor/rules/main-agent-orchestration.mdc"

while IFS= read -r rule; do
  check_pointer "$rule"
done < <(find "$HOME/sume" "$HOME/chase" "$HOME/dooi" -maxdepth 4 \
  -path "*/.cursor/rules/main-agent-orchestration.mdc" \
  -not -path "*/node_modules/*" -not -path "*worktree*" -not -path "*PURGE*" 2>/dev/null)

exit $fail
