---
name: obsidian-templater-compiler
description: Compile Obsidian templater templates into deterministic note-creation shell scripts and manifest for obsidian-templater-add.
---

# Obsidian Templater Compiler

Compile discovered Obsidian note templates into executable Bash note-creation scripts for `obsidian-templater-add`.

## Purpose

This skill provides a migration-friendly compiler workflow:
- discovers candidate templates from configuration and template folders
- validates config/template prerequisites before generation
- generates one `create-<note_type>.sh` per discovered note type
- emits `manifest.json` as the source-of-truth contract for the writer skill
- propagates filename policy from config (manual vs date-format-driven)

No note type, template filename, or QuickAdd choice name is hardcoded in generation output.

## When to Use

- Initial setup of the note writer scripts
- After template changes
- After QuickAdd or Daily Notes config changes
- When moving this workflow to another vault

## Usage

```bash
bash scripts/compile_obsidian_templater_generators.sh \
  --vault-root <vault-path> \
  --target-skill-dir <obsidian-templater-add-skill-path>
```

## Parameters

- `--vault-root` (required): Vault root directory
- `--target-skill-dir` (required): Skill directory where `scripts/` will be regenerated

## Discovery Workflow

1. Read QuickAdd template choices from `.obsidian/plugins/quickadd/data.json`
2. Scan `9-System/Templates/quickadd/*.templater.md`
3. Read daily-notes template/folder from `.obsidian/daily-notes.json`
4. Keep only file-creation templates (frontmatter-based templates)
5. Infer `note_type` from template `id:` prefix
6. Resolve duplicates by source priority and produce a stable script set

## Output Contract

Generated in target skill `scripts/`:
- `common.sh`
- `create-<note_type>.sh` (dynamic set)
- `manifest.json`

`manifest.json` includes, per script:
- `type`
- `template_rel_path`
- `default_folder`
- `file_name_mode`
- `file_name_format`
- `source`
- `origin`

## Robustness Rules

- If QuickAdd or Daily Notes config is missing/unparseable, emit warning and continue discovery from remaining sources
- Fail on non-writable target path (`exit 3`)
- Fail when Python runtime is unavailable (`exit 2`)
- Fail when scan root is missing (`exit 4`)
- Fail when no valid file-creation templates are discovered (`exit 4`)
- Remove stale `create-*.sh` before writing new ones to prevent drift

## Exit Codes

- `0`: Success
- `1`: Parameter error
- `2`: Runtime prerequisite missing (for example `python3`)
- `3`: Target path not writable
- `4`: Template discovery/parsing failed (including missing scan root)

## References

- `references/template-mapping.md`
- `references/config-resolution.md`
