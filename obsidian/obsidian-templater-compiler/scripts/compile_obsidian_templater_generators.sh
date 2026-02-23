#!/bin/bash
set -euo pipefail

# Obsidian Templater Compiler (dynamic + robust)
#
# Responsibilities:
# 1) Discover file-creation templates from QuickAdd choices, daily-notes config,
#    and a fixed scan root (9-System/Templates/quickadd)
# 2) Resolve final note-type records with clear source/origin semantics
# 3) Generate writer scripts and manifest for obsidian-templater-add

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VAULT_ROOT=""
TARGET_SKILL_DIR=""
SCRIPTS_DIR=""
TMP_DIR=""

# Required by user: fixed template scan root (vault-relative)
SCAN_ROOT_REL="9-System/Templates/quickadd"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  echo "Usage: $0 --vault-root <path> --target-skill-dir <path>"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vault-root)
        [[ $# -lt 2 ]] && { log_error "Missing value for --vault-root"; exit 1; }
        VAULT_ROOT="$2"
        shift 2
        ;;
      --target-skill-dir)
        [[ $# -lt 2 ]] && { log_error "Missing value for --target-skill-dir"; exit 1; }
        TARGET_SKILL_DIR="$2"
        shift 2
        ;;
      *)
        log_error "Unknown parameter: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$VAULT_ROOT" || -z "$TARGET_SKILL_DIR" ]]; then
    log_error "Missing required parameters"
    usage
    exit 1
  fi

  if [[ ! -d "$VAULT_ROOT" ]]; then
    log_error "Vault root does not exist: $VAULT_ROOT"
    exit 1
  fi

  SCRIPTS_DIR="$TARGET_SKILL_DIR/scripts"
  mkdir -p "$SCRIPTS_DIR"
  if [[ ! -w "$SCRIPTS_DIR" ]]; then
    log_error "Target scripts directory is not writable: $SCRIPTS_DIR"
    exit 3
  fi

  TMP_DIR="$(mktemp -d)"
}

validate_prerequisites() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 is required but not found"
    exit 2
  fi

  local scan_root_abs="$VAULT_ROOT/$SCAN_ROOT_REL"
  if [[ ! -d "$scan_root_abs" ]]; then
    log_error "Template scan root missing: $scan_root_abs"
    exit 4
  fi
}

# Resolve path against vault root and allow implicit .md suffix.
resolve_template_path() {
  local raw_path="$1"
  local candidate="$VAULT_ROOT/$raw_path"

  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ "$candidate" != *.md && -f "$candidate.md" ]]; then
    printf '%s\n' "$candidate.md"
    return 0
  fi
  return 1
}

normalize_folder() {
  local folder="$1"
  [[ -z "$folder" ]] && printf '/\n' || printf '%s\n' "$folder"
}

# Build candidate list as JSON objects, not TSV, to avoid field-position fragility.
collect_candidates_json() {
  local out_json="$1"
  local quickadd_config="$VAULT_ROOT/.obsidian/plugins/quickadd/data.json"
  local daily_config="$VAULT_ROOT/.obsidian/daily-notes.json"
  local scan_root_abs="$VAULT_ROOT/$SCAN_ROOT_REL"

  : > "$TMP_DIR/choices.json"
  : > "$TMP_DIR/daily.json"

  if [[ -f "$quickadd_config" ]]; then
    if ! python3 - "$quickadd_config" > "$TMP_DIR/choices.json" <<'PY'; then
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

rows = []
for c in data.get("choices", []):
    if not isinstance(c, dict):
        continue
    if c.get("type") != "Template":
        continue
    template_path = c.get("templatePath")
    if not isinstance(template_path, str) or not template_path.strip():
        continue

    folder = "/"
    folder_cfg = c.get("folder", {})
    if isinstance(folder_cfg, dict) and folder_cfg.get("enabled", False):
        folders = folder_cfg.get("folders", [])
        if isinstance(folders, list) and folders and isinstance(folders[0], str) and folders[0].strip():
            folder = folders[0]

    rows.append({
        "source": "choice",
        "priority": 30,
        "template_rel": template_path,
        "folder": folder,
        "origin": str(c.get("name", "quickadd-choice"))
    })

print(json.dumps(rows, ensure_ascii=False))
PY
      log_warning "QuickAdd config parse failed; continuing without choice candidates"
      echo '[]' > "$TMP_DIR/choices.json"
    fi
  else
    log_warning "QuickAdd config missing: $quickadd_config; continuing without choice candidates"
    echo '[]' > "$TMP_DIR/choices.json"
  fi

  if [[ -f "$daily_config" ]]; then
    if ! python3 - "$daily_config" > "$TMP_DIR/daily.json" <<'PY'; then
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

rows = []
template = data.get("template")
folder = data.get("folder", "/")
fmt = data.get("format", "YYYY-MM-DD")

if isinstance(template, str) and template.strip():
    if not isinstance(folder, str) or not folder.strip():
        folder = "/"
    if not isinstance(fmt, str) or not fmt.strip():
        fmt = "YYYY-MM-DD"
    rows.append({
        "source": "daily",
        "priority": 10,
        "template_rel": template,
        "folder": folder,
        "origin": "daily-notes",
        "daily_format": fmt,
    })

print(json.dumps(rows, ensure_ascii=False))
PY
      log_warning "Daily notes config parse failed; continuing without daily candidate"
      echo '[]' > "$TMP_DIR/daily.json"
    fi
  else
    log_warning "Daily notes config missing: $daily_config; continuing without daily candidate"
    echo '[]' > "$TMP_DIR/daily.json"
  fi

  # Build scan candidates in Python for stable path handling.
  python3 - "$scan_root_abs" > "$TMP_DIR/scan.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
rows = []
for p in sorted(root.glob("*.templater.md")):
    rows.append({
        "source": "scan",
        "priority": 20,
        "template_abs": str(p),
        "folder": "/",
        "origin": "scan-root",
    })
print(json.dumps(rows, ensure_ascii=False))
PY

  # Merge and resolve template absolute paths for non-scan sources.
  python3 - "$TMP_DIR/choices.json" "$TMP_DIR/daily.json" "$TMP_DIR/scan.json" "$VAULT_ROOT" > "$out_json" <<'PY'
import json
import sys
from pathlib import Path

choices_path, daily_path, scan_path, vault_root = sys.argv[1:]
vault = Path(vault_root)

choices = json.load(open(choices_path, "r", encoding="utf-8"))
daily = json.load(open(daily_path, "r", encoding="utf-8"))
scan = json.load(open(scan_path, "r", encoding="utf-8"))


def resolve_template_path(rel: str):
    p = vault / rel
    if p.is_file():
        return str(p)
    if p.suffix != ".md":
        p2 = Path(str(p) + ".md")
        if p2.is_file():
            return str(p2)
    return ""

rows = []
for rec in choices + daily:
    rel = rec.get("template_rel", "")
    abs_path = resolve_template_path(rel) if isinstance(rel, str) else ""
    if not abs_path:
        continue
    out = dict(rec)
    out["template_abs"] = abs_path
    rows.append(out)

rows.extend(scan)
print(json.dumps(rows, ensure_ascii=False, indent=2))
PY
}

generate_common_sh() {
  local output_file="$SCRIPTS_DIR/common.sh"

  cat > "$output_file" <<'EOF_COMMON'
#!/bin/bash
# Common utilities for note creation scripts.
# Keep helpers deterministic and side-effect free.

get_date() { date +"%Y-%m-%d-%A"; }
get_created_time() { date +"%Y-%m-%d %H:%M:%S"; }
get_timestamp_id() { date +"%Y%m%d%H%M%S"; }

# Convert moment-style date tokens used in Obsidian config to strftime.
get_filename_from_format() {
  local moment_fmt="$1"
  local strf="$moment_fmt"
  strf="${strf//YYYY/%Y}"
  strf="${strf//MM/%m}"
  strf="${strf//DD/%d}"
  strf="${strf//dddd/%A}"
  strf="${strf//HH/%H}"
  strf="${strf//mm/%M}"
  strf="${strf//ss/%S}"
  date +"$strf"
}

yaml_escape() {
  local input="$1"
  input="${input//\\/\\\\}"
  input="${input//\"/\\\"}"
  input="${input//$'\n'/\\n}"
  echo "$input"
}

get_incremented_filename() {
  local base_path="$1"
  local dir="$(dirname "$base_path")"
  local filename="$(basename "$base_path" .md)"
  local counter=1
  local test_path="$base_path"

  while [[ -f "$test_path" ]]; do
    test_path="$dir/$filename $counter.md"
    counter=$((counter + 1))
  done
  echo "$test_path"
}

ensure_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p "$dir"
}

write_file() {
  local filepath="$1"
  local content="$2"
  echo "$content" > "$filepath"
}

resolve_template_runtime_path() {
  local vault_root="$1"
  local template_rel="$2"
  local path="$vault_root/$template_rel"
  if [[ -f "$path" ]]; then
    echo "$path"
  elif [[ "$path" != *.md && -f "$path.md" ]]; then
    echo "$path.md"
  else
    echo ""
  fi
}

# Render supported placeholders from template text.
# Intentionally strict: only replace known placeholders to avoid accidental substitutions.
render_template() {
  local template_path="$1"
  local tags_escaped="$2"
  local info_escaped="$3"
  local date_val="$4"
  local created_val="$5"
  local ts_val="$6"

  DATE_VAL="$date_val" CREATED_VAL="$created_val" TS_VAL="$ts_val" TAGS_VAL="$tags_escaped" INFO_VAL="$info_escaped" \
    python3 - "$template_path" <<'PY'
import os
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()

if text.startswith("<%*"):
    end = text.find("-%>")
    if end != -1:
        text = text[end + 3 :].lstrip("\n")

# Whitelist only known safe substitutions.
replacements = {
    r'<%\s*tp\.date\.now\("YYYY-MM-DD-dddd"\)\s*%>': os.environ.get("DATE_VAL", ""),
    r'<%\s*tp\.date\.now\("YYYY-MM-DD HH:mm:ss"\)\s*%>': os.environ.get("CREATED_VAL", ""),
    r'<%\s*tp\.date\.now\("YYYYMMDDHHmmss"\)\s*%>': os.environ.get("TS_VAL", ""),
    r'\{\{DATE:YYYY-MM-DD-dddd\}\}': os.environ.get("DATE_VAL", ""),
    r'\{\{DATE:YYYY-MM-DD HH:mm:ss\}\}': os.environ.get("CREATED_VAL", ""),
    r'\{\{DATE:YYYYMMDDHHmmss\}\}': os.environ.get("TS_VAL", ""),
    r'<%\s*tags\s*%>': os.environ.get("TAGS_VAL", ""),
    r'<%\s*await\s+tp\.system\.prompt\("info:"\)\s*%>': os.environ.get("INFO_VAL", ""),
    r'<%\s*tp\.system\.prompt\("info:"\)\s*%>': os.environ.get("INFO_VAL", ""),
}

for pattern, value in replacements.items():
    text = re.sub(pattern, lambda _m, v=value: v, text)

print(text, end="")
PY
}

# Convert only frontmatter tags from string to YAML array.
fix_tags_frontmatter() {
  local input="$1"
  python3 - "$input" <<'PY'
import re
import sys

content = sys.argv[1]
lines = content.split("\n")

if not lines or lines[0].strip() != "---":
    print(content, end="")
    raise SystemExit(0)

# Find frontmatter end.
end = None
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        end = i
        break

if end is None:
    print(content, end="")
    raise SystemExit(0)

front = lines[:end + 1]
rest = lines[end + 1:]
out = []

for line in front:
    m = re.match(r'^(\s*)tags:\s*"([^"]*)"\s*$', line)
    if not m:
        out.append(line)
        continue

    indent = m.group(1)
    tags_str = m.group(2).strip()
    out.append(f"{indent}tags:")
    if tags_str:
        for tag in tags_str.split():
            out.append(f"{indent}  - {tag}")

print("\n".join(out + rest), end="")
PY
}
EOF_COMMON

  chmod +x "$output_file"
  log_success "Generated common.sh"
}

generate_create_script() {
  local note_type="$1"
  local template_rel="$2"
  local default_folder="$3"
  local file_name_mode="$4"
  local file_name_format="$5"
  local output_file="$SCRIPTS_DIR/create-$note_type.sh"

  cat > "$output_file" <<'EOF_SCRIPT'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DEFAULT_FOLDER="__DEFAULT_FOLDER__"
TEMPLATE_REL_PATH="__TEMPLATE_REL_PATH__"
FILE_NAME_MODE="__FILE_NAME_MODE__"
FILE_NAME_FORMAT="__FILE_NAME_FORMAT__"

FILE_NAME=""
OUT_DIR=""
VAULT_ROOT=""
TAGS=""
INFO=""
DRY_RUN=false

warn() {
  echo "Warning: $*" >&2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --file-name)
      FILE_NAME="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --vault-root)
      VAULT_ROOT="$2"
      shift 2
      ;;
    --tags)
      TAGS="$2"
      shift 2
      ;;
    --info)
      INFO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown parameter: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$VAULT_ROOT" ]]; then
  echo "Error: --vault-root is required"
  exit 1
fi

if [[ "$FILE_NAME_MODE" == "manual" ]]; then
  if [[ -z "$FILE_NAME" ]]; then
    echo "Error: --file-name is required"
    exit 1
  fi
elif [[ "$FILE_NAME_MODE" == "daily_format" ]]; then
  if [[ -n "$FILE_NAME" ]]; then
    warn "--file-name is ignored for this note type. filename is fixed by FILE_NAME_FORMAT='$FILE_NAME_FORMAT' and cannot be overridden."
  fi
  FILE_NAME="$(get_filename_from_format "$FILE_NAME_FORMAT")"
  if [[ -z "$FILE_NAME" ]]; then
    echo "Error: failed to generate filename from format"
    exit 1
  fi
else
  echo "Error: unsupported FILE_NAME_MODE=$FILE_NAME_MODE"
  exit 1
fi

# For templates with non-root default folder, output location is fixed and cannot be overridden.
if [[ "$DEFAULT_FOLDER" != "/" ]]; then
  if [[ -n "$OUT_DIR" ]]; then
    warn "--out-dir is ignored for this note type. default output is '$DEFAULT_FOLDER' and cannot be overridden."
  fi
  OUT_DIR="$DEFAULT_FOLDER"
elif [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$DEFAULT_FOLDER"
fi

if [[ "$OUT_DIR" == "/" ]]; then
  OUT_DIR="$VAULT_ROOT"
elif [[ "$OUT_DIR" != /* ]]; then
  OUT_DIR="$VAULT_ROOT/$OUT_DIR"
fi

TEMPLATE_PATH="$(resolve_template_runtime_path "$VAULT_ROOT" "$TEMPLATE_REL_PATH")"
if [[ -z "$TEMPLATE_PATH" ]]; then
  echo "Error: template not found: $TEMPLATE_REL_PATH"
  exit 1
fi

ensure_dir "$OUT_DIR"

DATE_VAL="$(get_date)"
CREATED_VAL="$(get_created_time)"
TS_VAL="$(get_timestamp_id)"
TAGS_ESCAPED="$(yaml_escape "$TAGS")"
INFO_ESCAPED="$(yaml_escape "$INFO")"

CONTENT="$(render_template "$TEMPLATE_PATH" "$TAGS_ESCAPED" "$INFO_ESCAPED" "$DATE_VAL" "$CREATED_VAL" "$TS_VAL")"

# Always normalize tags frontmatter so rendered `tags: "a b"` becomes YAML array.
CONTENT="$(fix_tags_frontmatter "$CONTENT")"

BASE_PATH="$OUT_DIR/$FILE_NAME.md"
FINAL_PATH="$(get_incremented_filename "$BASE_PATH")"

if [[ "$DRY_RUN" == true ]]; then
  echo "=== DRY RUN ==="
  echo "Output path: $FINAL_PATH"
  echo "Content:"
  echo "$CONTENT"
else
  write_file "$FINAL_PATH" "$CONTENT"
  echo "Created: $FINAL_PATH"
fi
EOF_SCRIPT

  python3 - "$output_file" "$default_folder" "$template_rel" "$file_name_mode" "$file_name_format" <<'PY'
import sys

path, default_folder, template_rel, file_name_mode, file_name_format = sys.argv[1:]
text = open(path, "r", encoding="utf-8").read()
text = text.replace("__DEFAULT_FOLDER__", default_folder)
text = text.replace("__TEMPLATE_REL_PATH__", template_rel)
text = text.replace("__FILE_NAME_MODE__", file_name_mode)
text = text.replace("__FILE_NAME_FORMAT__", file_name_format)
open(path, "w", encoding="utf-8").write(text)
PY

  chmod +x "$output_file"
  log_success "Generated create-$note_type.sh"
}

generate_manifest_from_records() {
  local records_json="$1"
  local output_file="$SCRIPTS_DIR/manifest.json"

  python3 - "$records_json" "$VAULT_ROOT" > "$output_file" <<'PY'
import json
import sys
from datetime import datetime

records_path, vault_root = sys.argv[1:]
records = json.load(open(records_path, "r", encoding="utf-8"))

manifest = {
    "generated_at": datetime.now().astimezone().isoformat(),
    "vault_root": vault_root,
    "scripts": {}
}

for rec in records:
    script_name = f"create-{rec['note_type']}.sh"
    manifest["scripts"][script_name] = {
        "type": rec["note_type"],
        "template_rel_path": rec["template_rel"],
        "default_folder": rec["default_folder"],
        "file_name_mode": rec["file_name_mode"],
        "file_name_format": rec["file_name_format"],
        "source": rec["source"],
        "origin": rec["origin"],
    }

print(json.dumps(manifest, ensure_ascii=False, indent=2))
PY

  log_success "Generated manifest.json"
}

main() {
  parse_args "$@"
  validate_prerequisites

  log_info "Starting Obsidian templater compilation..."
  log_info "Vault root: $VAULT_ROOT"
  log_info "Target skill: $TARGET_SKILL_DIR"
  log_info "Scan root: $SCAN_ROOT_REL"

  local candidates_json="$TMP_DIR/candidates.json"
  collect_candidates_json "$candidates_json"

  local records_json="$TMP_DIR/records.json"
  python3 - "$candidates_json" "$VAULT_ROOT" > "$records_json" <<'PY'
import json
import re
import sys
from pathlib import Path

candidates_path, vault_root = sys.argv[1:]
vault = Path(vault_root)
candidates = json.load(open(candidates_path, "r", encoding="utf-8"))


def read_text(path: str):
    try:
        return Path(path).read_text(encoding="utf-8")
    except Exception:
        return ""


def strip_leading_templater_script(text: str) -> str:
    if text.startswith("<%*"):
        end = text.find("-%>")
        if end != -1:
            return text[end + 3 :].lstrip("\n")
    return text


def is_file_creation_template(path: str) -> bool:
    text = strip_leading_templater_script(read_text(path))
    for line in text.splitlines():
        if not line.strip():
            continue
        return line.strip() == "---"
    return False


def extract_note_type(path: str) -> str:
    text = read_text(path)
    id_line = None
    for line in text.splitlines():
        if re.match(r"^id:\s*", line):
            id_line = line
            break
    if not id_line:
        return ""
    value = re.sub(r"^id:\s*", "", id_line).strip().strip('"\'')
    value = re.sub(r"<%.*?%>", "", value)
    value = re.sub(r"\{\{DATE:YYYYMMDDHHmmss\}\}", "", value)
    value = re.sub(r"\d{14}$", "", value)
    m = re.match(r"([A-Za-z][A-Za-z0-9_-]*)", value)
    return m.group(1).lower() if m else ""


best = {}
daily_meta = {}

for rec in candidates:
    template_abs = rec.get("template_abs", "")
    if not template_abs or not Path(template_abs).is_file():
        continue
    if not is_file_creation_template(template_abs):
        continue

    nt = extract_note_type(template_abs)
    if not nt:
        continue

    rel = str(Path(template_abs).relative_to(vault)).replace("\\", "/")
    current = {
        "note_type": nt,
        "template_abs": template_abs,
        "template_rel": rel,
        "default_folder": rec.get("folder") or "/",
        "file_name_mode": "manual",
        "file_name_format": "N/A",
        "source": rec.get("source", "unknown"),
        "origin": rec.get("origin", "unknown"),
        "priority": int(rec.get("priority", 0)),
    }

    prev = best.get(nt)
    if prev is None or current["priority"] > prev["priority"]:
        best[nt] = current

    if rec.get("source") == "daily":
        daily_meta[nt] = {
            "folder": rec.get("folder") or "/",
            "format": rec.get("daily_format") or "YYYY-MM-DD",
        }

for nt, meta in daily_meta.items():
    if nt in best:
        best[nt]["default_folder"] = meta["folder"]
        best[nt]["file_name_mode"] = "daily_format"
        best[nt]["file_name_format"] = meta["format"]

records = [best[k] for k in sorted(best.keys())]
print(json.dumps(records, ensure_ascii=False, indent=2))
PY

  local record_count
  record_count="$(python3 - "$records_json" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], 'r', encoding='utf-8'))))
PY
)"

  if [[ "$record_count" -eq 0 ]]; then
    log_error "No valid file-creation templates discovered"
    exit 4
  fi

  log_info "Discovered $record_count note type(s)"

  generate_common_sh
  rm -f "$SCRIPTS_DIR"/create-*.sh

  while IFS=$'\t' read -r note_type template_rel default_folder file_name_mode file_name_format source origin; do
    generate_create_script "$note_type" "$template_rel" "$default_folder" "$file_name_mode" "$file_name_format"
    log_info "  type=$note_type source=$source origin=$origin folder=$default_folder file_name_mode=$file_name_mode"
  done < <(python3 - "$records_json" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1], 'r', encoding='utf-8')):
    print("\t".join([
        r['note_type'],
        r['template_rel'],
        r['default_folder'],
        r['file_name_mode'],
        r['file_name_format'],
        r['source'],
        r['origin'],
    ]))
PY
)

  generate_manifest_from_records "$records_json"

  log_success "Compilation complete!"
  log_info "Generated files in: $SCRIPTS_DIR"
}

main "$@"
