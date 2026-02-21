#!/bin/bash
# Upload skills to GitHub repository

set -e

# Default paths
SOURCE_DIR="$HOME/.claude/skills"
TARGET_DIR="/home/dell/skills"

# Parse arguments
if [ $# -eq 0 ]; then
    echo "Usage: $0 skill-name [skill-name-2 ...] [--source-dir DIR] [--target-dir DIR] [--message MSG]"
    echo "Example: $0 my-skill --source-dir /path/to/skills --target-dir /path/to/repo --message 'Add my-skill'"
    exit 1
fi

SKILLS=()
COMMIT_MSG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --source-dir)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --target-dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        --message)
            COMMIT_MSG="$2"
            shift 2
            ;;
        *)
            SKILLS+=("$1")
            shift
            ;;
    esac
done

if [ ${#SKILLS[@]} -eq 0 ]; then
    echo "Error: No skill names provided"
    exit 1
fi

echo "📦 Uploading skills to GitHub"
echo "   Source: $SOURCE_DIR"
echo "   Target: $TARGET_DIR"
echo "   Skills: ${SKILLS[*]}"
echo

# Copy each skill to target directory
for skill in "${SKILLS[@]}"; do
    src_path="$SOURCE_DIR/$skill"
    dest_path="$TARGET_DIR/$skill"

    if [ ! -d "$src_path" ]; then
        echo "❌ Error: Skill '$skill' not found at $src_path"
        exit 1
    fi

    echo "📁 Copying $skill..."
    rm -rf "$dest_path"
    cp -r "$src_path" "$TARGET_DIR/"
done

echo "✅ All skills copied"
echo

# Generate commit message if not provided
if [ -z "$COMMIT_MSG" ]; then
    if [ ${#SKILLS[@]} -eq 1 ]; then
        COMMIT_MSG="Update skill: ${SKILLS[0]}"
    else
        COMMIT_MSG="Update skills: ${SKILLS[*]}"
    fi
fi

# Git operations
echo "🚀 Performing git operations..."
cd "$TARGET_DIR"

git add "${SKILLS[@]}"

# Check if there are changes to commit
if git diff --cached --quiet; then
    echo "ℹ️  No new changes to commit"
else
    git commit -m "$COMMIT_MSG"
    echo "✅ Commit created"
fi

# Push to remote
echo "📤 Pushing to remote..."
git push
echo "✅ Push completed"

echo
echo "🎉 Upload completed successfully!"
