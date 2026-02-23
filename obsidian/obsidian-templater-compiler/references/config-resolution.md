# Configuration Resolution Details (Dynamic)

This document defines how the compiler resolves default output directories and template paths from Obsidian configuration.

## Configuration Inputs

- `.obsidian/plugins/quickadd/data.json`
- `.obsidian/daily-notes.json`

QuickAdd and Daily Notes config are optional-at-runtime:
- if missing/unparseable, compiler logs warning and continues with remaining discovery sources
- compilation fails only when no valid file-creation templates can be resolved overall

## Template Path Resolution

For a configured template path:
1. Resolve relative to vault root
2. If exact path missing and suffix is not `.md`, try `<path>.md`
3. If still missing, skip that candidate and continue discovery

## Default Folder Resolution

### From QuickAdd Choices

For each template choice:
- If `folder.enabled == true` and `folder.folders[0]` is a non-empty string, use it
- Otherwise use `/`

### From Daily Notes

- Use `daily-notes.json.folder` if non-empty string
- Otherwise use `/`

## Folder Precedence for Final Type Mapping

After candidate merge by `note_type` priority:
- If a `daily` source exists for that `note_type`, override final `default_folder` with daily folder
- Otherwise keep folder from selected winning candidate

This allows daily folder policy to apply without hardcoding a specific note type.

## Filename Policy Resolution

The compiler also resolves filename policy per discovered note type:

- Default policy: `file_name_mode = "manual"` and `file_name_format = ""`
- If a note type is linked to a daily-notes template candidate:
  - `file_name_mode = "daily_format"`
  - `file_name_format = daily-notes.json.format` (fallback: `YYYY-MM-DD`)

Runtime effect in generated writer scripts:
- `manual`: `--file-name` is required
- `daily_format`: filename is generated from current date/time using the configured format; passed `--file-name` is ignored with warning

## Output Directory Priority at Runtime

Generated writer scripts resolve output path as:
1. If `default_folder != "/"`, enforce `default_folder` and ignore passed `--out-dir` with warning
2. Otherwise use CLI `--out-dir` when provided
3. Otherwise use script embedded `default_folder` (`/`)

Normalization:
- `--out-dir /` => vault root
- relative paths => `vault_root/<relative>`
- absolute paths => used as-is

## Example: Daily Notes Naming

Given:

```json
{
  "format": "YYYY-MM-DD",
  "folder": "9-System/Diary"
}
```

Generated diary writer behavior:
- output directory defaults to `9-System/Diary`
- filename is generated as current date (e.g., `2026-02-21.md`)
- passing `--file-name` is ignored with warning

## Failure Model

- Exit `2`: runtime prerequisite missing (for example `python3`)
- Exit `3`: target output path not writable
- Exit `4`: scan root missing or no valid file-creation templates discovered

## Migration Notes

Because discovery and resolution are dynamic:
- new templates can be introduced without compiler code edits
- renamed choice names can still be picked up via scan path
- downstream usage should rely on generated `manifest.json`
