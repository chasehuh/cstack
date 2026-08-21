#!/usr/bin/env bash
# Verify that Codex, Cursor, and Claude Code all resolve to the same
# orchestration SoT file.
set -uo pipefail

SKILL_DIR="$HOME/.agents/skills/sume-main-agent-orchestration"
SOT="$SKILL_DIR/SKILL.md"
fail=0

ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fail=1; }

[ -f "$SOT" ] && ok "SoT exists: $SOT" || bad "SoT missing: $SOT"

grep -q "Harness Scope" "$SOT" \
  && ok "SoT has Harness Scope" \
  || bad "SoT missing Harness Scope section"

grep -q "Cursor-only — Opus / background-worker monitoring" "$SOT" \
  && ok "SoT has Cursor-only Opus monitoring" \
  || bad "SoT missing Cursor-only Opus monitoring section"

# Skill discovery symlinks per harness.
for dir in "$HOME/.codex/skills" "$HOME/.claude/skills" "$HOME/.cursor/skills"; do
  link="$dir/sume-main-agent-orchestration"
  if [ -L "$link" ]; then
    # Resolve relative symlink targets (e.g. ../../.agents/skills/...).
    target="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$link" 2>/dev/null || true)"
    if [ "$target" = "$SKILL_DIR" ]; then
      ok "symlink resolves: $link"
    else
      bad "symlink broken or wrong target: $link -> ${target:-missing}"
    fi
  elif [ -d "$link" ]; then
    target="$(cd "$link" 2>/dev/null && pwd)"
    if [ "$target" = "$SKILL_DIR" ]; then
      ok "directory present: $link"
    else
      bad "directory wrong target: $link -> ${target:-missing}"
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

# Cursor pointer rules must stay pointers, not forked copies.
# Allow the words "Cursor-only" / "claude-human-stream" in the pointer;
# forbid restating the full model routing table (Opus 5 / Grok 4.5 lines).
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
