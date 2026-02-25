---
name: github-trending
description: Fetch, analyze, validate, and email strict GitHub Trending reports (daily/weekly/monthly) with full-list coverage and source-to-report consistency checks.
---

# GitHub Trending Report Skill

## Goal

Generate a strict GitHub Trending report for user that is:
1. Complete (all trending items, original order)
2. Insightful (evidence-based repo analysis)
3. Verifiable (must pass validation before sending)

## Required References

Always use these files as hard references:
1. Markdown template: `references/example_report.md`
2. HTML template: `references/example_report.html`
3. Output contract: `references/output_contract.md`

Use this file only in Step 3 when sending fails:
1. Email send fallback reference: `references/gog_email_delivery.md`

**Example interpretation rule (critical)**: Examples in `references/example_report.md` and `references/example_report.html` are format/structure references only, not depth benchmarks. See `references/output_contract.md` Section 10 for details.

## Input Contract

Summary:
- Map user intent to `PERIOD` (daily/weekly/monthly)
- Resolve `SKILL_DIR` from skill location
- Use fixed `OUTPUT_ROOT="$HOME/.github_trending"` (no override)
- Build `REPORT_DIR`, file paths, and trending URL from period and date

Required variables:
```bash
SKILL_DIR="<absolute-path-to-skill-directory>"
SCRIPTS_DIR="$SKILL_DIR/scripts"
DATE=$(date +%Y-%m-%d)
OUTPUT_ROOT="$HOME/.github_trending"
REPORT_DIR="$OUTPUT_ROOT/$PERIOD/$DATE"
HTML_FILE="$REPORT_DIR/report_$DATE.html"
MD_FILE="$REPORT_DIR/report_$DATE.md"
SOURCE_FILE="$REPORT_DIR/original_trending.html"
MANIFEST_FILE="$REPORT_DIR/report_manifest.json"
```

Path rules (mandatory):
1. `SKILL_DIR` must be the directory that contains `SKILL.md`.
2. Output root must be `~/.github_trending`.
3. Do not allow output root overrides via env vars or CLI flags.
4. Never call scripts with hardcoded relative paths like `python3 scripts/...`.

## Analysis Requirements (Mandatory)

Analysis must be evidence-driven AND personalized.

### Personalization (Critical):
All analysis fields must be actionable and context-specific. See `references/output_contract.md` Section 11 for:
- Required elements for each field (效果, 项目分析, 建议)
- Actionable recommendation requirements (specific action + scope + prerequisite + expected outcome)
- Templates and good/bad examples
- Forbidden generic phrases

### Evidence Collection:
Collect baseline evidence for every repo. Deep dive when README/structure is insufficient or claims are non-trivial. See `references/output_contract.md` Section 13 for detailed requirements.

### Parallel Analysis (Mandatory):
Spawn parallel sub-agents for each repo in Step 2. See `references/output_contract.md` Section 14 for:
- Concurrency pattern (launch all in single message)
- Sub-agent task requirements (must reference Section 11 and Section 13)
- Aggregation and error handling

## Workflow (Single Route, Mandatory)

Use this single route only:
1. Fetch source (with existing-report gate)
2. Analyze + generate report
3. Send email (only after validation pass)

### Step 1: Fetch Source (With Existing-Report Gate)

Run existing-report gate first:

```bash
python3 "$SCRIPTS_DIR/check_existing_report.py" \
  --period "$PERIOD" \
  --date "$DATE"
```

State transitions by exit code:
1. `0` (`existing_valid`): reuse existing artifacts and jump to Step 3.
2. `10` (`missing`): continue with source fetch and Step 2.
3. `20` (`existing_invalid`): continue with source fetch and Step 2.

If generation is needed:
1. Ensure `REPORT_DIR` exists.
2. Fetch selected trending page HTML.
3. Save source to `SOURCE_FILE`.
4. `SOURCE_FILE` must exist and be non-empty.

### Step 2: Analyze + Generate + Validate

Generate all required outputs in `REPORT_DIR` following `references/output_contract.md` Sections 4-6:
1. `original_trending.html`
2. `report_$DATE.md`
3. `report_$DATE.html`
4. `report_manifest.json`

Run validation:

```bash
python3 "$SCRIPTS_DIR/validate_report.py" \
  --report-dir "$REPORT_DIR" \
  --period "$PERIOD" \
  --date "$DATE"
```

If validation fails, follow `references/output_contract.md` Section 15.

### Step 3: Send Email (After Validation Pass Only)

Assume gog is already configured externally with `GOG_ACCOUNT` and `GOG_KEYRING_PASSWORD` set in persistent environment.

Send email directly:

```bash
gog gmail send \
  --to "$GOG_ACCOUNT" \
  --subject "GitHub $(echo $PERIOD | sed 's/./\\U&/') Trending Report ($DATE)" \
  --body-html "$(cat \"$HTML_FILE\")"
```

If send fails, follow `references/gog_email_delivery.md` minimal fallback checks, then retry once.

## Output Structure

Output directory structure:

```text
~/.github_trending/
└── <period>/
    └── YYYY-MM-DD/
        ├── original_trending.html
        ├── report_YYYY-MM-DD.md
        ├── report_YYYY-MM-DD.html
        └── report_manifest.json
```
