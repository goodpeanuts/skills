# Skill Uploader Operations Reference

This file contains detailed execution behavior for `scripts/upload_skill.sh`.

## Command

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh <skill...> [options]
```

## Skill Input Formats

- `skill-name`
- `skill-name:category`

Example:

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh my-skill:maintenance --mode add --confirm
```

## Options

- `--source-dir DIR`
  Source skills directory. Default: `~/.claude/skills`

- `--target-dir DIR`
  Target git repository directory. Default: `/home/dell/skills`

- `--message MSG`
  Custom commit message.

- `--category VALUE`
  Category override formats:
  - `category` (single skill only)
  - `skill:category`
  - `skill=category`

- `--mode add|update|auto`
  - `add`: fail if skill already exists
  - `update`: fail if skill does not exist
  - `auto`: infer from repository state

- `--confirm`
  Confirms user decisions were already collected by the agent.

- `--skip-checks`
  Bypass confirmation gate and execute directly.

- `--skip-readme`
  Skip README catalog rebuild.

- `--migrate-flat` / `--no-migrate-flat`
  Control migration of root-level skill directories.

- `--dry-run`
  Print action plan without changing files.

## Confirmation Gate

When `--confirm` is not provided and `--skip-checks` is not set:

1. Script computes and prints execution plan.
2. Script exits without file changes.

## Category Resolution Priority

1. Explicit category passed by agent
2. Existing categorized location in repository
3. Heuristic inference from skill name and `SKILL.md` description
4. Fail with message requesting explicit category

## Flat Skill Migration

Flat skill means a root-level directory like `./my-skill/SKILL.md`.

With `--migrate-flat`:

- Copy to `./<category>/<skill>/`
- Remove `./<skill>/` when destination is categorized

With `--no-migrate-flat`:

- Keep existing flat location when category is unresolved

## README Rebuild Policy

When `--skip-readme` is not set, script rebuilds `README.md` skill catalog:

1. Scan first-level directories dynamically.
2. Treat valid directories as categories.
3. Parse each skill's `SKILL.md` frontmatter `description`.
4. Regenerate `## Skill Catalog` section.
5. Sort categories and skills alphabetically.
6. Update `> Last updated: YYYY-MM-DD`.

If flat skills remain, they appear under `Uncategorized Skills`.

## Git Behavior

1. Stage affected skill paths and `README.md` (if updated).
2. If no staged diff, exit success without commit.
3. Commit (auto message when omitted) and push.

## Example Invocations

Add:

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh ai-research-helper \
  --category maintenance \
  --mode add \
  --confirm
```

Update:

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh skill-uploader \
  --mode update \
  --confirm
```

Preview:

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh my-skill \
  --category automation-skills \
  --mode auto \
  --dry-run
```
