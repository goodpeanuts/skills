---
name: github-trending
description: Fetch, deeply analyze, validate, archive, and email strict GitHub Trending reports (daily/weekly/monthly) with full-list coverage and source-to-report consistency checks.
---

# GitHub Trending Report Skill

## Prerequisites (Conditional)

Email-delivery prerequisites are only required when executing Step 4 (send email).  
Do not load these details for report generation-only runs.  
Load `references/gog_email_delivery.md` only when sending is needed.

## Goal

Generate a strictly formatted GitHub Trending report that is:
1. Complete (all trending items, original order)
2. Insightful (repo-level technical analysis based on README + structure + key code when needed)
3. Verifiable (must pass `scripts/check_existing_report.py` and `scripts/validate_report.py`)

## Audience & Tone

Audience is Roy (focus: Finance, AI Agents, Security). Analysis must be technical, evidence-based, and actionable.

## Required References

Always use these files as hard references:
1. Markdown template: `references/example_report.md`
2. HTML template: `references/example_report.html`
3. Output contract: `references/output_contract.md`
4. Email delivery reference (Step 4 only): `references/gog_email_delivery.md`

## Input Contract

### 1. Resolve period

Map user intent to `PERIOD`:
1. `daily`: user says daily/day/today
2. `monthly`: user says monthly/month
3. default: `weekly`

### 2. Resolve paths

Use workspace-relative paths only.

```bash
DATE=$(date +%Y-%m-%d)
REPORT_DIR="github_trending/$PERIOD/$DATE"
HTML_FILE="$REPORT_DIR/report_$DATE.html"
MD_FILE="$REPORT_DIR/report_$DATE.md"
SOURCE_FILE="$REPORT_DIR/original_trending.html"
MANIFEST_FILE="$REPORT_DIR/report_manifest.json"
```

Trending URL by period:
1. `daily`: `https://github.com/trending?since=daily`
2. `weekly`: `https://github.com/trending?since=weekly`
3. `monthly`: `https://github.com/trending?since=monthly`

## Workflow (Single Route, Mandatory)

Normal runs MUST use this split workflow only. Do not use removed one-click/orchestrator routes.

### Step 1: Check Existing Report First

Run:

```bash
python3 scripts/check_existing_report.py \
  --base-dir github_trending \
  --period "$PERIOD" \
  --date "$DATE"
```

State transitions by exit code:
1. `0` (`existing_valid`): Skip generation and go to Step 4 (send email).
2. `10` (`missing`): Continue to Step 2 (fetch source + generate).
3. `20` (`existing_invalid`): Continue to Step 2 (regenerate).

### Step 2: Fetch Source + Generate Report

Mandatory before validation:
1. Ensure `REPORT_DIR` exists.
2. Fetch GitHub Trending page HTML for selected period.
3. Save source to `SOURCE_FILE`.
4. `SOURCE_FILE` must exist and be non-empty.
5. Generate:
   1. `report_$DATE.md`
   2. `report_$DATE.html`
   3. `report_manifest.json`

### Step 3: Validate and Retry If Needed

Run:

```bash
python3 scripts/validate_report.py \
  --report-dir "$REPORT_DIR" \
  --period "$PERIOD" \
  --date "$DATE"
```

Retry policy:
1. If validation passes: continue to Step 4.
2. If validation fails: regenerate reports and validate again.
3. Maximum retries: 2.
4. If still failing: stop and do not send email.

### Step 4: Send Email (Only After Validation Pass)

Email policy:
1. Use `gog gmail send`.
2. Recipient should default to your own mailbox from `TRENDING_REPORT_RECIPIENT`.
3. `--recipient` override is allowed.
4. Never hardcode personal email addresses in skill/scripts.
5. Before sending, follow `references/gog_email_delivery.md` for gog installation/auth checks and non-interactive keyring handling.

Example:

```bash
gog gmail send \
  --to "$RECIPIENT_EMAIL" \
  --subject "GitHub $(echo $PERIOD | sed 's/./\U&/') Trending Report ($DATE)" \
  --body-html "$(cat \"$HTML_FILE\")"
```

## Analysis Depth Requirement (Mandatory)

For each trending repo, analysis must be evidence-driven and not shallow.

### Baseline (every repo, required)
1. Read repository README.
2. Inspect repository structure (root layout + key directories/files).
3. Extract architecture/usage/target-user signals from README + structure.

### Deep Dive (every repo, conditionally required)

If README/structure is insufficient or claims are non-trivial, inspect key code files.

Trigger signals include:
1. Claimed performance/security/finance strategy advantage.
2. Complex agent orchestration or runtime/sandbox design.
3. Ambiguous implementation details that affect recommendation quality.

Deep-dive minimum:
1. Inspect at least 2 key code/module evidence points when triggered.
2. Reflect these findings in `项目分析` as "how it works" + "why it matters" + risks/tradeoffs.

### Report Quality Standard

For each repo output:
1. Do not stop at feature summaries.
2. Provide architecture-level judgment and deployment/operational implications.
3. Provide actionable advice aligned to Finance/AI/Security.

## Generation Requirements (Mandatory)

Generate all files in `REPORT_DIR`:
1. `original_trending.html`
2. `report_$DATE.md`
3. `report_$DATE.html`
4. `report_manifest.json`

`report_manifest.json` must include:
1. `date` (`YYYY-MM-DD`)
2. `period` (`daily|weekly|monthly`)
3. `source_item_count` (integer)
4. `reported_item_count` (integer)
5. `repos` (ordered list with `rank`, `repo`, `url`)

For each repo, include:
1. Rank (`#1`, `#2`, ...)
2. Name (`owner/repo`) with valid GitHub hyperlink
3. Tags (at least one)
4. `是什么`
5. `作用`
6. `效果`
7. `项目分析`
8. `建议`

## HTML Contract (Strict)

Generated HTML must follow `references/example_report.html` and include:
1. `.overview-section`
2. `.repo-card` (one per repo)
3. `.tag` badges
4. `.suggestion-box`
5. Section title `🚀 热门项目详细分析`

Prohibited:
1. Plain unordered list fallback for repo details
2. Markdown backticks in HTML body text
3. Missing required fields in repo cards

## Markdown Contract (Strict)

Markdown must follow `references/example_report.md` and include:
1. Top title: `# GitHub 本<周期>技术趋势报告($DATE)`
2. `## 📊 概述与趋势分析`
3. `## 🚀 热门项目详细分析`
4. One section per repo:
   `### N. [owner/repo](https://github.com/owner/repo)`
5. Required field order:
   1. `是什么`
   2. `作用`
   3. `效果`
   4. `项目分析`
   5. `建议`

## Output Directory Contract

```text
github_trending/
└── <period>/
    └── YYYY-MM-DD/
        ├── original_trending.html
        ├── report_YYYY-MM-DD.md
        ├── report_YYYY-MM-DD.html
        └── report_manifest.json
```

## Failure Handling

Stop and return errors if any of the following occurs:
1. Missing required output files
2. Source item count mismatch with Markdown/HTML/manifest
3. Non-sequential ranking
4. Missing required analysis fields
5. Invalid GitHub repository links
6. Output path/date/period mismatch

Never send email when validation fails.
