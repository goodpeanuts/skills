#!/usr/bin/env bash
# Upload and synchronize skills to a git repository.

set -euo pipefail
shopt -s nullglob

SOURCE_DIR="$HOME/.claude/skills"
TARGET_DIR="/home/dell/skills"
COMMIT_MSG=""
MODE="auto"
CONFIRM=0
SKIP_README=0
SKIP_CHECKS=0
DRY_RUN=0
MIGRATE_FLAT=1

SKILLS=()
CATEGORY_ARGS=()
declare -A SKILL_SEEN=()
declare -A CATEGORY_BY_SKILL=()
declare -A STAGE_SEEN=()
STAGE_PATHS=()

usage() {
    cat <<'USAGE'
Usage:
  upload_skill.sh skill [skill2 ...] [options]
  upload_skill.sh skill:category [skill2:category2 ...] [options]

Options:
  --source-dir DIR        Source skills directory (default: ~/.claude/skills)
  --target-dir DIR        Target git repository directory (default: /home/dell/skills)
  --message MSG           Custom git commit message
  --category VALUE        Category override. VALUE can be:
                          - category               (single-skill invocation only)
                          - skill:category
                          - skill=category
  --mode add|update|auto Operation mode (default: auto)
  --confirm               Confirm that agent already collected user answers
  --skip-readme           Skip README.md rebuild
  --skip-checks           Skip confirmation gate and silent-overwrite checks
  --migrate-flat          Move root-level skill dirs into categorized layout (default)
  --no-migrate-flat       Keep root-level skill dirs unchanged when possible
  --dry-run               Show plan only; do not write files or run git
  -h, --help              Show this help

Examples:
  upload_skill.sh my-skill --category maintenance --mode add --confirm
  upload_skill.sh obsidian-templater-add:obsidian --confirm
  upload_skill.sh skill-a skill-b --category skill-a:maintenance --category skill-b:automation-skills --confirm
USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

add_stage_path() {
    local path="$1"
    if [[ -z "${STAGE_SEEN[$path]:-}" ]]; then
        STAGE_SEEN["$path"]=1
        STAGE_PATHS+=("$path")
    fi
}

add_skill() {
    local skill="$1"
    local category="${2:-}"

    [[ -n "$skill" ]] || die "Skill name cannot be empty"
    [[ "$skill" != */* ]] || die "Skill '$skill' cannot contain '/'"

    if [[ -z "${SKILL_SEEN[$skill]:-}" ]]; then
        SKILL_SEEN["$skill"]=1
        SKILLS+=("$skill")
    fi

    if [[ -n "$category" ]]; then
        CATEGORY_BY_SKILL["$skill"]="$category"
    fi
}

is_valid_category() {
    local category="$1"
    [[ "$category" =~ ^[A-Za-z0-9._-]+$ ]]
}

list_top_dirs() {
    local path
    for path in "$TARGET_DIR"/*; do
        [[ -d "$path" ]] || continue
        basename "$path"
    done | sort
}

find_existing_categories_for_skill() {
    local skill="$1"
    local category
    while IFS= read -r category; do
        [[ -n "$category" ]] || continue
        if [[ -f "$TARGET_DIR/$category/$skill/SKILL.md" ]]; then
            echo "$category"
        fi
    done < <(list_top_dirs)
}

parse_frontmatter_field() {
    local file="$1"
    local field="$2"

    [[ -f "$file" ]] || return 0

    awk -v field="$field" '
        BEGIN { in_frontmatter = 0 }
        NR == 1 && $0 == "---" { in_frontmatter = 1; next }
        in_frontmatter && $0 == "---" { exit }
        in_frontmatter {
            if ($0 ~ "^" field ":[[:space:]]*") {
                sub("^" field ":[[:space:]]*", "", $0)
                gsub(/^[\"\x27]|[\"\x27]$/, "", $0)
                print $0
                exit
            }
        }
    ' "$file"
}

infer_category() {
    local skill="$1"
    local skill_md="$2"
    local description
    local lower

    description="$(parse_frontmatter_field "$skill_md" "description")"
    lower="${description,,}"

    if [[ "$skill" == obsidian-* ]] || [[ "$lower" == *"obsidian"* ]]; then
        echo "obsidian"
        return 0
    fi

    if [[ "$lower" == *"maintenance"* ]] || [[ "$lower" == *"repository"*"skill"* ]] || [[ "$skill" == skill-* ]]; then
        echo "maintenance"
        return 0
    fi

    if [[ "$skill" == wsl-* ]] || [[ "$lower" == *"automation"* ]] || [[ "$lower" == *"script"* ]] || [[ "$lower" == *"operations"* ]]; then
        echo "automation-skills"
        return 0
    fi

    if [[ "$lower" == *"development"* ]] || [[ "$lower" == *"programming"* ]] || [[ "$lower" == *"coding"* ]] || [[ "$lower" == *"rust"* ]]; then
        echo "developer-skills"
        return 0
    fi

    if [[ "$lower" == *"productivity"* ]] || [[ "$lower" == *"note"* ]] || [[ "$lower" == *"writing"* ]] || [[ "$lower" == *"knowledge"* ]]; then
        echo "productive-skills"
        return 0
    fi

    return 1
}

category_title() {
    local category="$1"
    local words

    if [[ "$category" == "__uncategorized__" ]]; then
        echo "Uncategorized Skills"
        return 0
    fi

    words="$(echo "$category" | tr '-' ' ' | awk '{for (i=1; i<=NF; i++) {$i=toupper(substr($i,1,1)) substr($i,2)}; print}')"
    if [[ "${words,,}" == *"skills" ]]; then
        echo "$words"
    else
        echo "$words Skills"
    fi
}

sanitize_markdown_cell() {
    local value="$1"
    value="${value//$'\n'/ }"
    value="${value//|/\\|}"
    echo "$value"
}

is_category_dir_for_readme() {
    local category="$1"
    local path="$TARGET_DIR/$category"

    [[ -d "$path" ]] || return 1

    if [[ "$category" == "scripts" ]]; then
        return 1
    fi

    if [[ -f "$path/SKILL.md" ]]; then
        return 1
    fi

    if find "$path" -mindepth 1 -maxdepth 1 -type f | grep -q .; then
        return 1
    fi

    return 0
}

list_readme_categories() {
    local category
    while IFS= read -r category; do
        [[ -n "$category" ]] || continue
        if is_category_dir_for_readme "$category"; then
            echo "$category"
        fi
    done < <(list_top_dirs)
}

list_flat_skills() {
    local path
    for path in "$TARGET_DIR"/*; do
        [[ -d "$path" ]] || continue
        [[ -f "$path/SKILL.md" ]] || continue
        basename "$path"
    done | sort
}

rebuild_readme() {
    local readme="$TARGET_DIR/README.md"
    local today
    local tmp_current
    local tmp_timestamp
    local tmp_catalog
    local tmp_output

    today="$(date +%F)"
    tmp_current="$(mktemp)"
    tmp_timestamp="$(mktemp)"
    tmp_catalog="$(mktemp)"
    tmp_output="$(mktemp)"

    if [[ -f "$readme" ]]; then
        cp "$readme" "$tmp_current"
    else
        {
            echo "# Claude Skills Repository"
            echo
            echo "This repository serves as a centralized backup and distribution hub for Claude skills."
            echo
        } > "$tmp_current"
    fi

    awk -v today="$today" '
        BEGIN { replaced = 0 }
        {
            if (!replaced && $0 ~ /^> Last updated:/) {
                print "> Last updated: " today
                replaced = 1
                next
            }
            print
        }
        END {
            if (!replaced) {
                print ""
                print "> Last updated: " today
            }
        }
    ' "$tmp_current" > "$tmp_timestamp"

    {
        local category
        local skill_dir
        local skill_name
        local skill_md
        local description
        local row
        local sorted_rows
        local -a categories
        local -a flat_skills

        mapfile -t categories < <(list_readme_categories)
        mapfile -t flat_skills < <(list_flat_skills)
        if [[ ${#flat_skills[@]} -gt 0 ]]; then
            categories+=("__uncategorized__")
        fi

        printf "## Skill Catalog\n\n"

        if [[ ${#categories[@]} -eq 0 ]]; then
            printf "### Skills\n\n"
            printf "| Skill Name | Description |\n"
            printf "|------------|-------------|\n"
            printf "| *No skills in this repository* | |\n"
        fi

        for category in "${categories[@]}"; do
            printf "### %s\n\n" "$(category_title "$category")"
            printf "| Skill Name | Description |\n"
            printf "|------------|-------------|\n"

            sorted_rows=""

            if [[ "$category" == "__uncategorized__" ]]; then
                for skill_name in "${flat_skills[@]}"; do
                    skill_md="$TARGET_DIR/$skill_name/SKILL.md"
                    description="$(parse_frontmatter_field "$skill_md" "description")"
                    description="$(sanitize_markdown_cell "$description")"
                    row="| [$skill_name](./$skill_name) | $description |"
                    sorted_rows+="$skill_name"$'\t'"$row"$'\n'
                done
            else
                for skill_dir in "$TARGET_DIR/$category"/*; do
                    [[ -d "$skill_dir" ]] || continue
                    [[ -f "$skill_dir/SKILL.md" ]] || continue

                    skill_name="$(basename "$skill_dir")"
                    skill_md="$skill_dir/SKILL.md"
                    description="$(parse_frontmatter_field "$skill_md" "description")"
                    description="$(sanitize_markdown_cell "$description")"
                    row="| [$skill_name](./$category/$skill_name) | $description |"
                    sorted_rows+="$skill_name"$'\t'"$row"$'\n'
                done
            fi

            if [[ -n "$sorted_rows" ]]; then
                printf '%s' "$sorted_rows" | sort -t $'\t' -k1,1 | cut -f2-
            else
                printf "| *No skills in this category* | |\n"
            fi

            printf "\n"
        done
    } > "$tmp_catalog"

    awk -v catalog_file="$tmp_catalog" '
        function print_catalog( line) {
            while ((getline line < catalog_file) > 0) {
                print line
            }
            close(catalog_file)
        }

        BEGIN {
            in_catalog = 0
            replaced = 0
        }

        {
            if ($0 ~ /^## Skill Catalog$/) {
                print_catalog()
                in_catalog = 1
                replaced = 1
                next
            }

            if (in_catalog && $0 ~ /^## /) {
                in_catalog = 0
            }

            if (!in_catalog) {
                print $0
            }
        }

        END {
            if (!replaced) {
                if (NR > 0) {
                    print ""
                }
                print_catalog()
            }
        }
    ' "$tmp_timestamp" > "$tmp_output"

    mv "$tmp_output" "$readme"

    rm -f "$tmp_current" "$tmp_timestamp" "$tmp_catalog"
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            [[ $# -ge 2 ]] || die "Missing value for --source-dir"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --target-dir)
            [[ $# -ge 2 ]] || die "Missing value for --target-dir"
            TARGET_DIR="$2"
            shift 2
            ;;
        --message)
            [[ $# -ge 2 ]] || die "Missing value for --message"
            COMMIT_MSG="$2"
            shift 2
            ;;
        --category)
            [[ $# -ge 2 ]] || die "Missing value for --category"
            CATEGORY_ARGS+=("$2")
            shift 2
            ;;
        --mode)
            [[ $# -ge 2 ]] || die "Missing value for --mode"
            MODE="$2"
            shift 2
            ;;
        --confirm)
            CONFIRM=1
            shift
            ;;
        --skip-readme)
            SKIP_README=1
            shift
            ;;
        --skip-checks)
            SKIP_CHECKS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --migrate-flat)
            MIGRATE_FLAT=1
            shift
            ;;
        --no-migrate-flat)
            MIGRATE_FLAT=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                add_skill "$1"
                shift
            done
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            if [[ "$1" == *:* ]]; then
                IFS=':' read -r skill category <<< "$1"
                [[ -n "$skill" && -n "$category" ]] || die "Invalid skill spec '$1'. Use skill:category"
                add_skill "$skill" "$category"
            else
                add_skill "$1"
            fi
            shift
            ;;
    esac
done

[[ ${#SKILLS[@]} -gt 0 ]] || die "No skills provided"
[[ -d "$SOURCE_DIR" ]] || die "Source directory does not exist: $SOURCE_DIR"
[[ -d "$TARGET_DIR" ]] || die "Target directory does not exist: $TARGET_DIR"

case "$MODE" in
    add|update|auto) ;;
    *) die "Invalid --mode '$MODE'. Expected add, update, or auto" ;;
esac

for category_arg in "${CATEGORY_ARGS[@]}"; do
    if [[ "$category_arg" == *":"* ]]; then
        IFS=':' read -r skill category <<< "$category_arg"
        [[ -n "$skill" && -n "$category" ]] || die "Invalid --category value '$category_arg'"
        [[ -n "${SKILL_SEEN[$skill]:-}" ]] || die "--category references unknown skill '$skill'"
        CATEGORY_BY_SKILL["$skill"]="$category"
    elif [[ "$category_arg" == *"="* ]]; then
        IFS='=' read -r skill category <<< "$category_arg"
        [[ -n "$skill" && -n "$category" ]] || die "Invalid --category value '$category_arg'"
        [[ -n "${SKILL_SEEN[$skill]:-}" ]] || die "--category references unknown skill '$skill'"
        CATEGORY_BY_SKILL["$skill"]="$category"
    else
        if [[ ${#SKILLS[@]} -ne 1 ]]; then
            die "Plain --category value requires a single skill invocation"
        fi
        CATEGORY_BY_SKILL["${SKILLS[0]}"]="$category_arg"
    fi
done

declare -A RESOLVED_CATEGORY=()
declare -A RESOLVED_PATH=()
declare -A RESOLVED_REL_PATH=()
declare -A RESOLVED_OPERATION=()
declare -A REMOVE_FLAT=()

PREVIEW_ONLY=0
if [[ $SKIP_CHECKS -eq 0 && $CONFIRM -eq 0 ]]; then
    PREVIEW_ONLY=1
fi

echo "Preparing upload plan"
echo "  Source: $SOURCE_DIR"
echo "  Target: $TARGET_DIR"
echo "  Mode: $MODE"
echo "  Dry run: $DRY_RUN"
echo "  Skip checks: $SKIP_CHECKS"
echo "  Skip README: $SKIP_README"
echo

for skill in "${SKILLS[@]}"; do
    src_path="$SOURCE_DIR/$skill"
    skill_md="$src_path/SKILL.md"

    [[ -d "$src_path" ]] || die "Skill '$skill' not found at $src_path"

    explicit_category="${CATEGORY_BY_SKILL[$skill]:-}"
    if [[ -n "$explicit_category" ]]; then
        is_valid_category "$explicit_category" || die "Invalid category '$explicit_category' for skill '$skill'"
    fi

    mapfile -t candidates < <(find_existing_categories_for_skill "$skill")

    flat_exists=0
    if [[ -f "$TARGET_DIR/$skill/SKILL.md" ]]; then
        flat_exists=1
    fi

    if [[ -z "$explicit_category" && ${#candidates[@]} -gt 1 ]]; then
        die "Skill '$skill' exists in multiple categories (${candidates[*]}). Pass explicit --category"
    fi

    target_category=""
    if [[ -n "$explicit_category" ]]; then
        target_category="$explicit_category"
    elif [[ ${#candidates[@]} -eq 1 ]]; then
        target_category="${candidates[0]}"
    elif infer_category "$skill" "$skill_md" > /dev/null; then
        target_category="$(infer_category "$skill" "$skill_md")"
    fi

    target_path=""
    target_rel_path=""
    if [[ -n "$target_category" ]]; then
        target_path="$TARGET_DIR/$target_category/$skill"
        target_rel_path="$target_category/$skill"
    elif [[ $flat_exists -eq 1 && $MIGRATE_FLAT -eq 0 ]]; then
        target_path="$TARGET_DIR/$skill"
        target_rel_path="$skill"
    else
        die "Cannot determine category for '$skill'. Provide --category skill:category"
    fi

    existing_any=0
    if [[ $flat_exists -eq 1 || ${#candidates[@]} -gt 0 ]]; then
        existing_any=1
    fi

    resolved_operation=""
    case "$MODE" in
        add)
            [[ $existing_any -eq 0 ]] || die "Skill '$skill' already exists. Use --mode update or --mode auto"
            resolved_operation="add"
            ;;
        update)
            [[ $existing_any -eq 1 ]] || die "Skill '$skill' does not exist. Use --mode add or --mode auto"
            resolved_operation="update"
            ;;
        auto)
            if [[ $existing_any -eq 1 ]]; then
                resolved_operation="update"
            else
                resolved_operation="add"
            fi
            ;;
    esac

    remove_flat=0
    if [[ $flat_exists -eq 1 && "$target_path" != "$TARGET_DIR/$skill" && $MIGRATE_FLAT -eq 1 ]]; then
        remove_flat=1
    fi

    RESOLVED_CATEGORY["$skill"]="$target_category"
    RESOLVED_PATH["$skill"]="$target_path"
    RESOLVED_REL_PATH["$skill"]="$target_rel_path"
    RESOLVED_OPERATION["$skill"]="$resolved_operation"
    REMOVE_FLAT["$skill"]="$remove_flat"

    echo "- Skill: $skill"
    echo "  Operation: $resolved_operation"
    echo "  Category: ${target_category:-<flat>}"
    echo "  Destination: $target_path"
    if [[ $remove_flat -eq 1 ]]; then
        echo "  Flat migration: remove $TARGET_DIR/$skill"
    fi
done

if [[ $PREVIEW_ONLY -eq 1 ]]; then
    echo
    echo "Confirmation gate active. Agent must gather user answers and rerun with --confirm (or use --skip-checks)."
    echo "No changes were made."
    exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "Dry run completed. No changes were made."
    exit 0
fi

echo
echo "Applying skill updates"
for skill in "${SKILLS[@]}"; do
    src_path="$SOURCE_DIR/$skill"
    target_path="${RESOLVED_PATH[$skill]}"
    target_rel_path="${RESOLVED_REL_PATH[$skill]}"

    mkdir -p "$(dirname "$target_path")"
    rm -rf "$target_path"
    cp -R "$src_path" "$target_path"
    add_stage_path "$target_rel_path"

    if [[ "${REMOVE_FLAT[$skill]}" -eq 1 ]]; then
        rm -rf "$TARGET_DIR/$skill"
        add_stage_path "$skill"
    fi
done

if [[ $SKIP_README -eq 0 ]]; then
    echo "Rebuilding README.md"
    rebuild_readme
    add_stage_path "README.md"
fi

echo "Running git operations"
cd "$TARGET_DIR"

git add -A "${STAGE_PATHS[@]}"

if git diff --cached --quiet; then
    echo "No staged changes after update."
    exit 0
fi

if [[ -z "$COMMIT_MSG" ]]; then
    op_summary="sync"
    if [[ ${#SKILLS[@]} -eq 1 ]]; then
        if [[ "${RESOLVED_OPERATION[${SKILLS[0]}]}" == "add" ]]; then
            op_summary="Add new skill: ${SKILLS[0]}"
        else
            op_summary="Update skill: ${SKILLS[0]}"
        fi
    else
        op_summary="Sync skills: ${SKILLS[*]}"
    fi

    if [[ $SKIP_README -eq 0 ]]; then
        COMMIT_MSG="$op_summary (README updated)"
    else
        COMMIT_MSG="$op_summary"
    fi
fi

git commit -m "$COMMIT_MSG"
git push

echo "Upload completed successfully."
