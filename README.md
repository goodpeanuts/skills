# Claude Skills Repository

> Last updated: 2026-02-23

This repository serves as a centralized backup and distribution hub for Claude skills.

## Skill Catalog

### Obsidian Skills

| Skill Name | Description |
|------------|-------------|
| [obsidian-templater-add](./obsidian/obsidian-templater-add) | Create Obsidian notes by executing compiled templater writer scripts and enforcing filename and output-folder contracts. |
| [obsidian-templater-compiler](./obsidian/obsidian-templater-compiler) | Compile Obsidian templater templates into deterministic note-creation shell scripts and manifest for obsidian-templater-add. |

### Productivity Skills

| Skill Name | Description |
|------------|-------------|
| [financial-advisor](./productive-skills/financial-advisor) | Professional financial analysis for Suishouji bookkeeping users, including health scoring, cash flow, debt/asset structure, transaction patterns, and actionable recommendations from report data. |

### Automation Skills

| Skill Name | Description |
|------------|-------------|
| [github-trending-report](./automation-skills/github-trending-report) | Fetch, analyze, archive, and email the GitHub Trending report. Supports daily/weekly/monthly periods. Defaults to weekly if unspecified. Analyzes ALL trending items in order, generates HTML/Markdown reports, and archives source files. |
| [wsl-ssh-sync-with-host](./automation-skills/wsl-ssh-sync-with-host) | Configure WSL to share SSH keys and configuration with Windows, solving permission issues (chmod/chown) on NTFS mounts. Use when users want to reuse their Windows .ssh directory in WSL or encounter UNPROTECTED PRIVATE KEY FILE errors. |

### Maintenance Skills

| Skill Name | Description |
|------------|-------------|
| [skill-uploader](./maintenance/skill-uploader) | Upload and synchronize Claude skills to GitHub repository with automatic git commit and push. Use when the user wants to upload newly created or updated skills to their GitHub repository. |

## Quick Start

1. Copy the desired skill to your local `~/.claude/skills/` directory
2. Restart Claude Code or reload skills
3. The skill will be available in your session

## Structure

```
obsidian/              - Obsidian-specific skills
productive-skills/      - Productivity and personal management
automation-skills/      - Automation and scripting utilities
maintenance/            - Repository maintenance tools
```

## Naming Convention

All skill directories use **kebab-case** naming (lowercase with hyphens).

## License

See individual skill directories for license information.
