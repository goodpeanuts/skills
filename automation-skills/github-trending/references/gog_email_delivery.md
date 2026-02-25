# gog Email Delivery Reference

Use this reference only for Step 3 (send email).

## Scope

This file is a minimal fallback checklist.
Assume gog account/auth configuration is already completed externally.
All send parameters must be read from environment variables.

## Environment Variable Setup (Required)

Configure env vars in a persistent environment location before running the skill:
1. System-level environment settings (if your runtime loads them)
2. `~/.bashrc`
3. `~/.zshrc`

Required vars:
1. `GOG_ACCOUNT`
2. `GOG_KEYRING_PASSWORD`
3. `TRENDING_REPORT_RECIPIENT` (default recipient)

Example (direct env-var usage):

```bash
export GOG_ACCOUNT=zen9ha0@gmail.com
export GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.keyring_password 2>/dev/null)
export TRENDING_REPORT_RECIPIENT=zen9ha0@gmail.com
```

After editing rc file, reload it:

```bash
source ~/.bashrc
# or
source ~/.zshrc
```

## Quick Preconditions

Before retrying send, check:
1. `gog` is available in PATH.
2. `GOG_ACCOUNT` is non-empty.
3. `GOG_KEYRING_PASSWORD` is non-empty.
4. `RECIPIENT_EMAIL` or `TRENDING_REPORT_RECIPIENT` is non-empty.
5. Report HTML exists and is non-empty.

Example checks:

```bash
command -v gog >/dev/null 2>&1
gog --version
[ -n "$GOG_ACCOUNT" ]
[ -n "$GOG_KEYRING_PASSWORD" ]
: "${RECIPIENT_EMAIL:=${TRENDING_REPORT_RECIPIENT:-}}"
[ -n "$RECIPIENT_EMAIL" ]
[ -s "$HTML_FILE" ]
```

## Send Command Template

```bash
gog gmail send \
  --to "$RECIPIENT_EMAIL" \
  --subject "GitHub $(echo $PERIOD | sed 's/./\\U&/') Trending Report ($DATE)" \
  --body-html "$(cat \"$HTML_FILE\")"
```

## Failure Rule

If any precondition fails, stop and report the missing prerequisite.
Do not send with incomplete prerequisites.
