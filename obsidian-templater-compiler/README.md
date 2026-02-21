# Obsidian Templater Compiler

Compile Obsidian templater templates into writer scripts for `obsidian-templater-add`.

## Main Script

- `scripts/compile_obsidian_templater_generators.sh`

## Usage

```bash
bash scripts/compile_obsidian_templater_generators.sh \
  --vault-root /mnt/d/obsidian/obsidianx \
  --target-skill-dir /mnt/d/obsidian/obsidianx/.claude/skills/obsidian-templater-add
```

## Output

Generated into target `scripts/`:

- `common.sh`
- `create-<note_type>.sh`
- `manifest.json`

## Notes

- Template scan root is fixed to `9-System/Templates/quickadd`.
- Config parse failures (QuickAdd/Daily Notes) are warnings; compile only fails when no valid templates are resolved.
