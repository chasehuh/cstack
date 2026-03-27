# chase-skills

Reusable Claude Code skills for code review, PR management, and production audits.

## Skills

| Skill | Description | Usage |
|-------|-------------|-------|
| `/merge` | Review, fix, and merge multiple PRs in one shot | `$merge 94 96 95` |
| `/audit` | Production readiness scan → GitHub issues | `$audit` or `$audit src/lib/` |
| `/propose` | Feature idea → implementation-ready issue | `$propose add typing indicators` |
| `/generate-pr` | GitHub issue → merge-ready PR | `$generate-pr 39` |
| `/review` | Pre-landing PR review (dependency of merge/audit) | `$review` |

## Setup

### Option 1: Symlink into your project

```bash
# Link all skills at once
ln -s /path/to/chase-skills/.claude/skills/* /your-project/.claude/skills/

# Or link individual skills
ln -s /path/to/chase-skills/.claude/skills/merge /your-project/.claude/skills/merge
```

### Option 2: Use `--add-dir`

```bash
claude --add-dir /path/to/chase-skills
```

### Option 3: Personal skills (available in all projects)

```bash
# Copy to personal Claude skills directory
cp -r .claude/skills/* ~/.claude/skills/
```

## Directory Structure

Skills are duplicated in both `.claude/skills/` (Claude Code native) and `.agents/skills/` (gstack/plugin compatibility):

```
chase-skills/
├── .claude/skills/     # Claude Code native path
│   ├── merge/
│   ├── audit/
│   ├── propose/
│   ├── generate-pr/
│   └── review/
└── .agents/skills/     # gstack/plugin compatibility
    ├── merge/
    ├── audit/
    ├── propose/
    ├── generate-pr/
    └── review/
```

## Dependencies

- `review` is required by `merge`, `audit`, and `generate-pr` (they read `review/checklist.md`)
- GitHub CLI (`gh`) is required for all skills
- Node.js/npm for `merge` and `audit` (typecheck, tests)
