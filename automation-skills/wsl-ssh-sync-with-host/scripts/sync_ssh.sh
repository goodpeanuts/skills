#!/bin/bash
set -e

# WSL SSH Sync Script
# Automates the linking and permission fixing for sharing Windows SSH keys with WSL.

# 1. Determine Windows SSH Path
if [ -n "$1" ]; then
    WINDOWS_USER="$1"
    SSH_PATH="/mnt/c/Users/$WINDOWS_USER/.ssh"
else
    # Try to detect via cmd.exe if available, otherwise default to current user if names match, or ask input
    WIN_HOME=$(cmd.exe /c "echo %UserProfile%" 2>/dev/null | tr -d '\r')
    if [ -n "$WIN_HOME" ]; then
        SSH_PATH=$(wslpath "$WIN_HOME")/.ssh
    else
        echo "Could not detect Windows user. Usage: ./sync_ssh.sh <windows_username>"
        exit 1
    fi
fi

echo "Targeting Windows SSH directory: $SSH_PATH"

if [ ! -d "$SSH_PATH" ]; then
    echo "Error: Directory $SSH_PATH does not exist."
    exit 1
fi

# 2. Configure Symlink
if [ -d "$HOME/.ssh" ] && [ ! -L "$HOME/.ssh" ]; then
    echo "Backing up existing local .ssh directory to .ssh.bak..."
    mv "$HOME/.ssh" "$HOME/.ssh.bak"
fi

if [ ! -L "$HOME/.ssh" ]; then
    echo "Creating symlink..."
    ln -s "$SSH_PATH" "$HOME/.ssh"
else
    echo "Symlink already exists."
fi

# 3. Check Mount Options (Critical for Permissions)
if ! grep -q "metadata" /etc/wsl.conf 2>/dev/null; then
    echo "⚠️  CRITICAL WARNING: /etc/wsl.conf is missing 'metadata' option."
    echo "Files in /mnt/c cannot have their permissions modified without this."
    echo "Run this command to fix it:"
    echo "  echo -e '[automount]\noptions = \"metadata\"' | sudo tee -a /etc/wsl.conf"
    echo "Then RESTART WSL (wsl --shutdown in PowerShell) and run this script again."
else
    echo "WSL mount options look good."
fi

# 4. Fix Permissions
echo "Applying strict permissions to SSH keys..."

# Directory itself
chmod 700 "$HOME/.ssh"

# Private keys and config (secure)
# We grep specific common key names or all files that don't look like public keys
find "$HOME/.ssh" -type f -not -name "*.pub" -not -name "known_hosts*" -exec chmod 600 {} + 2>/dev/null || echo "Warning: Could not chmod some files. Check wsl.conf metadata setting."

# Config and known_hosts must be 600
chmod 600 "$HOME/.ssh/config" 2>/dev/null || true
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true

# Public keys (readable)
find "$HOME/.ssh" -name "*.pub" -exec chmod 644 {} + 2>/dev/null || true

echo "✅ SSH Sync configuration complete."
ls -ld "$HOME/.ssh"
