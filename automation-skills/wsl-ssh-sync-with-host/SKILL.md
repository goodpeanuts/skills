---
name: wsl-ssh-sync-with-host
description: Configure WSL to share SSH keys and configuration with Windows, solving permission issues (chmod/chown) on NTFS mounts. Use when users want to reuse their Windows .ssh directory in WSL or encounter UNPROTECTED PRIVATE KEY FILE errors.
---

# WSL SSH Sync

This skill automates the configuration required to safely share SSH keys between Windows and WSL (Windows Subsystem for Linux).

## Problem

By default, WSL mounts Windows drives (e.g., `/mnt/c`) with 777 permissions. SSH requires strict permissions (600) for private keys. Standard `chmod` commands fail on WSL mounts unless the `metadata` option is enabled in `/etc/wsl.conf`.

## Solution

This skill provides a script to:
1.  Symlink the Windows `.ssh` directory to `~/.ssh` in WSL.
2.  Check for the required `metadata` mount option in `/etc/wsl.conf`.
3.  Apply correct permissions (`chmod 600`) to keys and config files.

## Usage

### 1. Run the Sync Script

Execute the provided script to set up the symlink and fix permissions.

```bash
./scripts/sync_ssh.sh [windows_username]
```

If the Windows username is not provided, the script attempts to auto-detect it.

### 2. Verify Mount Options (Critical)

If the script warns about missing `metadata` options:

1.  Edit `/etc/wsl.conf`:
    ```ini
    [automount]
    options = "metadata"
    ```
2.  **Restart WSL** (Required):
    Run `wsl --shutdown` in Windows PowerShell/CMD.
3.  Re-run the script or manually run `chmod 600 ~/.ssh/id_rsa`.

## Troubleshooting

- **"Bad owner or permissions"**: Ensure `~/.ssh/config` is also set to 600.
- **chmod has no effect**: The drive is not mounted with `metadata`. See step 2 above.
