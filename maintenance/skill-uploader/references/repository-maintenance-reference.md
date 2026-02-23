# Repository Maintenance Reference

This reference was migrated from root `CLAUDE.md` into `skill-uploader` so repository governance lives with the uploader skill.

## Repository Purpose

- Backup and version control for Claude skills
- Centralized distribution point for skill updates
- Consistent organization and structure for discoverability

## Repository Structure

```text
/home/dell/skills/
├── obsidian/                    # Obsidian-specific skills
├── productive-skills/           # Productivity and personal management
├── developer-skills/            # Development and programming tools
├── automation-skills/           # Automation and scripting utilities
├── maintenance/                 # Self-bootstrapping and repository tools
└── README.md                    # Root skill catalog
```

## Directory Definitions

| Directory | Purpose | Examples |
|-----------|---------|----------|
| `obsidian/` | Obsidian vault integration skills | obsidian-templater-add |
| `productive-skills/` | Productivity, note-taking, writing | writing-assistant |
| `developer-skills/` | Development and coding workflows | rust-project |
| `automation-skills/` | Automation, scripting, operations | wsl-ssh-sync-with-host |
| `maintenance/` | Repository/tool maintenance skills | skill-uploader |

## Skill Naming Convention

- Use kebab-case.
- Recommended pattern: `<domain>-<function>-<variant>` when applicable.

Examples:

- `obsidian-templater-add`
- `wsl-ssh-sync-with-host`
- `rust-project`

## Skill Directory Contents

Typical layout:

- `SKILL.md` (required)
- `scripts/` (optional)
- `references/` (optional)
- `assets/` (optional)

## Root README Maintenance Rules

`README.md` should represent current repository state:

1. Scan skill directories under category folders.
2. Parse `SKILL.md` frontmatter fields:
   - `name`
   - `description`
3. Group by category based on directory location.
4. Sort entries alphabetically.
5. Update `> Last updated` date.

## Adding New Skills

Classification decision guide:

1. Obsidian-specific -> `obsidian/`
2. Repository/tool maintenance -> `maintenance/`
3. Otherwise by primary function:
   - Productivity/writing/notes -> `productive-skills/`
   - Development/coding -> `developer-skills/`
   - Automation/operations -> `automation-skills/`

Process:

1. Place skill in the selected category directory.
2. Ensure `SKILL.md` has valid frontmatter.
3. Run `skill-uploader` workflow.
4. Verify README catalog updates.

## SKILL.md Frontmatter Format

```yaml
---
name: skill-name
description: One or two sentences describing when to use this skill
---
```

## File Placement Rules

- Category folders should contain skill directories, not loose files.
- Skill directories contain their own implementation files.
- Root should primarily contain repository-level files (for example `README.md`).

## Maintenance Checklist

- Verify skill category is correct.
- Verify skill directory name uses kebab-case.
- Verify `SKILL.md` frontmatter is valid.
- Verify README catalog and last-updated date are current.

## Conflict Resolution

When category is ambiguous:

1. Choose nearest matching category.
2. Escalate to user for confirmation when needed.
3. Document rationale in workflow notes or commit message.

## Migration Guidance

When moving skills between categories:

1. Prefer `git mv` to preserve history.
2. Update README links.
3. Verify no broken links remain.
4. Verify `skill-uploader` still resolves expected destination.
