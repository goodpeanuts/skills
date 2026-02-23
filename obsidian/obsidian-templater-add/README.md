# Obsidian Templater Add

Create Obsidian notes using compiled writer scripts.

## Prerequisite

If `scripts/` is missing or behavior is stale, run `obsidian-templater-compiler` first.

## Usage

```bash
# manual filename mode
bash scripts/create-<type>.sh \
  --vault-root /mnt/d/obsidian/obsidianx \
  --file-name "My Note"
```

## Runtime Rules

- `file_name_mode=manual`: `--file-name` required.
- `file_name_mode=daily_format`: `--file-name` ignored with warning.
- `default_folder!=/`: `--out-dir` ignored with warning.
- To place file elsewhere when folder is fixed: create first, then `mv <src> <dst>`.

## Generated Files

Managed by compiler and ignored by git:

- `scripts/common.sh`
- `scripts/create-*.sh`
- `scripts/manifest.json`
