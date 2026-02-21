---
name: skill-uploader
description: Upload and synchronize Claude skills to GitHub repository with automatic git commit and push. Use when the user wants to upload newly created or updated skills to their GitHub repository. Triggers on requests like "upload skill to GitHub", "sync skills to repo", "push skills to remote", "upload new skills", or when the user mentions moving skills to their git repository.
---

# Skill Uploader

Upload Claude skills to GitHub repository with automatic version control.

## Workflow

1. Copy skills from source directory to target GitHub repository
2. Stage changes with git add
3. Commit with auto-generated or custom message
4. Push to remote repository

## Basic Usage

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh skill-name
```

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh skill1 skill2 skill3
```

## Examples

**Upload skills from project directory:**
```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh obsidian-templater-add obsidian-templater-compiler --source-dir /mnt/d/obsidian/obsidianx/.claude/skills
```

**Upload global skills:**
```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh my-skill
```

**Upload with custom commit message:**
```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh skill-name --message "Add new feature"
```

## Options

- `--source-dir DIR` - Source directory containing skills (default: `~/.claude/skills`)
- `--target-dir DIR` - Target GitHub repository directory (default: `/home/dell/skills`)
- `--message MSG` - Custom commit message (auto-generated if not provided)

## Default Paths

- **Source**: `~/.claude/skills` (global skills directory)
- **Target**: `/home/dell/skills` (GitHub repository)
