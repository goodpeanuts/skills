# Template to Script Mapping Rules (Dynamic)

This document defines the compiler's dynamic mapping workflow from discovered templates to generated scripts.

## Mapping Principle

The compiler does not assume specific template filenames or note types.

It discovers candidate templates and derives mapping metadata from template content:
- `note_type`: inferred from frontmatter `id:` prefix
- `script_name`: `create-<note_type>.sh`
- `template_rel_path`: relative path from vault root
- `default_folder`: resolved from configuration with priority rules
- `source`/`origin`: discovery provenance for conflict resolution

## Discovery Sources and Priority

Candidates are collected from:
1. QuickAdd template choices in `.obsidian/plugins/quickadd/data.json` (priority 3)
2. Vault-wide `*.templater.md` scan (priority 2)
3. Daily-notes template in `.obsidian/daily-notes.json` (priority 1)

When multiple candidates resolve to the same `note_type`, higher priority wins.

After winning template selection:
- if a `daily` source exists for that same `note_type`, final `default_folder`, `file_name_mode`, and `file_name_format` are overridden by daily-notes settings
- template file path still follows the selected winner from priority resolution

## File-Creation Template Filter

A candidate is treated as a file-creation template only if, after removing a leading `<%* ... -%>` block (if present), the first non-empty line is YAML frontmatter start `---`.

This excludes fragment-only templates.

## Note Type Inference

`note_type` is inferred from the `id:` line in frontmatter:
1. Read first `id:` line
2. Remove templater/date placeholders (e.g. `<% ... %>`, `{{DATE:...}}`, trailing timestamp digits)
3. Extract leading token matching `[A-Za-z][A-Za-z0-9_-]*`
4. Lowercase token becomes `note_type`

If no valid token is found, candidate is discarded.

## Generated Script Contract

For each resolved `note_type`, generate `create-<note_type>.sh` that:
- requires `--vault-root`
- requires `--file-name` only when `file_name_mode = "manual"` (ignored with warning for `daily_format`)
- supports `--out-dir`, `--dry-run`, `--tags`, `--info`
- loads template at runtime from `template_rel_path`
- renders placeholders using current local time
- preserves template structure/body
- applies filename increment collision policy
- always normalizes rendered `tags: "a b"` to YAML array in frontmatter

## Runtime Rendering Rules

The renderer supports:
- Templater date placeholders: `tp.date.now(...)`
- Date placeholders: `{{DATE:...}}`
- Prompt placeholders: `tp.system.prompt(...)` / `await tp.system.prompt(...)`
- Tag placeholder: `<% tags %>`

Unknown expressions are left as-is; template remains the source of truth.

## Stale Script Prevention

Before regenerating scripts, compiler removes existing `create-*.sh` files in target `scripts/`.

This ensures generated output exactly matches current discovered set.

## Manifest Contract

`manifest.json` is the authoritative output index and includes per-script:
- `type`
- `template_rel_path`
- `default_folder`
- `file_name_mode`
- `file_name_format`
- `source`
- `origin`

Downstream consumers must discover available script types from `manifest.json`, not from hardcoded type lists.
