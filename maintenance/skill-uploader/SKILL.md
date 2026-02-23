---
name: skill-uploader
description: Upload and synchronize Claude skills to a GitHub repository via an agent-confirmed workflow. Use when the user wants to add or update skills in git, rebuild the skill catalog README, or migrate root-level skills into categorized directories.
---

# Skill Uploader

Use this skill when the user wants to synchronize one or more skills into a git repository and keep the skill catalog consistent.

## Key Responsibilities

1. Agent performs existence check and category decision.
2. Agent asks 1-2 confirmation questions when a decision is ambiguous.
3. Agent submits confirmed decisions to the script via CLI parameters.
4. Script executes deterministic file sync, README rebuild, and git push.

## Primary Workflow

1. Inspect target repo and determine `add` vs `update` per skill.
2. For new skills, determine category and confirm with user.
3. Run uploader with `--confirm` and explicit category mapping when needed.
4. Verify commit result and report changed paths/commit summary.

## Execution Contract

```bash
bash ~/.claude/skills/skill-uploader/scripts/upload_skill.sh <skill...> --confirm [options]
```

Important:

- Without `--confirm` (and without `--skip-checks`), script only prints a plan and exits.
- New skills should pass explicit category (`skill:category` or `--category`) unless existing location can be resolved.

## Progressive References

- For CLI options, mapping rules, migration behavior, README rebuild rules, and examples:
  - `references/operations-reference.md`
- For repository structure conventions and maintenance rules (migrated from root `CLAUDE.md`):
  - `references/repository-maintenance-reference.md`
