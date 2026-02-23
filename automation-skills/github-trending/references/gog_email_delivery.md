# gog Email Delivery Reference

Use this reference only when Step 4 (send email) is required.

## 1. gog CLI Installation

This skill uses `gog` CLI for sending email reports. Ensure:

```bash
# Check gog is installed
which gog && gog --version

# Should output something like: v0.11.0
```

If not installed, warn and report, abort sending, but allow report generation to proceed for archival purposes.

## 2. gog Authentication Verification

Before sending, verify gog authentication is configured:

```bash
# Check for gog config directory
ls -la ~/.config/gogcli/

# Required files:
# - config.json        (keyring_backend setting)
# - credentials.json   (OAuth client credentials)
# - .keyring_password  (encrypted keyring password for non-interactive use)
# - keyring/           (token storage directory)
```

## 3. Detecting Keyring Password (Critical for Non-Interactive Environments)

When running in a non-interactive environment (no TTY), gog requires `GOG_KEYRING_PASSWORD` to unlock token storage.

How to find the keyring password:

```bash
cat ~/.config/gogcli/.keyring_password
```

Verify authentication works:

```bash
export GOG_KEYRING_PASSWORD="$(cat ~/.config/gogcli/.keyring_password)"
export GOG_ACCOUNT="your-email@gmail.com"
gog gmail list "in:inbox" --max 1
```

If this returns results without prompting for password, authentication is correctly configured.

## 4. Common Authentication Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `no TTY available for keyring file backend password prompt` | Missing `GOG_KEYRING_PASSWORD` | Set env var from `.keyring_password` file |
| `missing --account` | No account specified | Set `GOG_ACCOUNT` or use `--account` flag |
| `read token: no such file` | Token not stored | Run `gog auth add <email>` interactively first |

## 5. Sending Email with gog

Always include both environment variables:

```bash
export GOG_KEYRING_PASSWORD="$(cat ~/.config/gogcli/.keyring_password)"
export GOG_ACCOUNT="<user-email>"

gog gmail send \
  --to "$RECIPIENT_EMAIL" \
  --subject "GitHub Weekly Trending Report ($DATE)" \
  --body-html "$(cat $HTML_FILE)"
```
