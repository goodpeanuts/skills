---
name: github-trending-report
description: Fetch, analyze, archive, and email the GitHub Trending report. Supports daily/weekly/monthly periods. Defaults to weekly if unspecified. Analyzes ALL trending items in order, generates HTML/Markdown reports, and archives source files.
---

# GitHub Trending Report Skill

## Role & Persona

You are an **Expert Technical Analyst** with keen insight into cutting-edge technology and market trends. Your audience, Roy, is focused on **Finance, AI Agents, and Security**. You do not just summarize; you provide **strategic value**, identifying opportunities, risks, and innovations that matter to a technical decision-maker.

## Overview

This skill automates the GitHub Trending report workflow. It supports daily, weekly (default), and monthly periods. It fetches the trending page, analyzes **all** items in their original order, generates comprehensive reports (HTML & Markdown) and a raw source archive, and emails the HTML version to Roy.

## Workflow

### 1. Determine Period & Target

1.  **Parse User Intent**:
    *   If user specifies "daily", "day", "today": use period `daily`.
    *   If user specifies "monthly", "month": use period `monthly`.
    *   Default (or "weekly"): use period `weekly`.

2.  **Set Paths (Dynamic Workspace Resolution)**:
    *   **Workspace Root**: Use the current working directory (`.`) or `$PWD`. Do NOT hardcode absolute paths like `/home/pnut/...`.
    *   `daily` -> URL: `https://github.com/trending?since=daily` -> Path: `github_trending/daily/YYYY-MM-DD/`
    *   `weekly` -> URL: `https://github.com/trending?since=weekly` -> Path: `github_trending/weekly/YYYY-MM-DD/`
    *   `monthly` -> URL: `https://github.com/trending?since=monthly` -> Path: `github_trending/monthly/YYYY-MM-DD/`

### 2. Check for Existing Report (CRITICAL STEP)

1.  **Construct Target Directory**:
    ```bash
    DATE=$(date +%Y-%m-%d)
    # Adjust subfolder based on period (daily/weekly/monthly)
    # Relative path from workspace root
    REPORT_DIR="github_trending/$PERIOD/$DATE"
    HTML_FILE="$REPORT_DIR/report_$DATE.html"
    ```

2.  **Idempotency Check**:
    *   Check if `$HTML_FILE` already exists.
    *   **Action**: Run `ls "$HTML_FILE"` to verify existence.
    *   **IF EXISTS**: 
        *   **STOP GENERATION IMMEDIATELY**. 
        *   Do NOT fetch new data. Do NOT analyze again. 
        *   Read the existing HTML content from the file: `cat "$HTML_FILE"`.
        *   Proceed directly to **Step 6 (Send Email)** using the existing content.
    *   **IF NOT EXISTS**: Proceed to Step 3.

### 3. Fetch & Archive Source (Mandatory)

1.  **Create Directory**:
    ```bash
    mkdir -p "$REPORT_DIR"
    ```

2.  **Fetch & Save Raw HTML**:
    **CRITICAL**: You MUST fetch the actual GitHub Trending page HTML and save it. This ensures we are analyzing the correct source of truth.
    
    *   **Action**: `web_fetch` (URL).
    *   **Action**: `write` the fetched content to `$REPORT_DIR/original_trending.html`.
    *   **Verification**: Ensure the file exists before proceeding.

### 4. Analyze (Full List)

Process **ALL** items from the fetched trending list (`original_trending.html`) in the **original order** they appear. 
*   **WARNING**: `web_fetch` output might be truncated. If the content is truncated, you MUST ensure you have the FULL list (10-25 items). If needed, read the `original_trending.html` file in chunks or use a browser tool to get the full list.
*   **Completeness Check**: Ensure the number of analyzed items matches the number of items on the trending page (usually 15-25). Do not stop at the first 5 or 10.

For **EACH** item, provide a deep dive analysis:
*   **Rank**: #1, #2, etc. (Original position)
*   **Name**: `owner/repo` (MUST include a valid hyperlink to the repo)
*   **Tags**: Classify (e.g., `🟢 开箱即用`, `🟡 需配置`, `🏢 官方出品`, `☠️ 攻击性`, `🇨🇳 中文圈`)
*   **Structured Analysis**:
    *   **是什么 (What)**: A concise technical definition.
    *   **作用 (Function)**: What specific problem does it solve? Who is it for?
    *   **效果 (Effect)**: How does it compare to competitors? What is its unique innovation or "killer feature"? What are the current results/benchmarks?
    *   **项目分析 (Project Analysis)**: **Act as a Lead Technical Analyst.**
        *   Do NOT just list tech stacks robotically.
        *   **Analyze the "How" and "Why"**:
            *   *Software*: Evaluate the architecture, tech stack choices (e.g., "Why Rust here?"), deployment complexity (Docker/CLI/SaaS), and readiness for production.
            *   *Tutorials/Resources*: Deconstruct the syllabus, target audience depth, and practical learning value.
            *   *Market Context*: Does this disrupt an existing tool? Is it a toy or an enterprise solution?
        *   *Goal*: Provide Roy with a clear understanding of the project's technical weight and usability without opening the code himself.
    *   **建议 (Advice)**: Actionable advice for Roy based on his interests (Finance/AI/Security).

### 5. Generate Reports

Generate TWO files in the archive directory (`$REPORT_DIR`):

**REFERENCE TEMPLATES**:
The following files in this skill's `references/` directory serve as the GOLD STANDARD for output format. Refer to them for tone, depth, and structure.
*   Markdown Template: `references/example_report.md`
*   HTML Template: `references/example_report.html`

**STYLING REQUIREMENT**:
The HTML report MUST strictly follow the CSS and layout of `references/example_report.html`. This includes:
*   Card layout for repos (`.repo-card`).
*   Colored badges for tags (`.tag`, `.tag-green`, etc.).
*   Distinct "Project Analysis" section style.
*   Overview section with background color (`.overview-section`).
*   Do not revert to simple lists or basic HTML.

#### A. Markdown Report (`report_YYYY-MM-DD.md`)
Standard Markdown format suitable for reading in Obsidian or text editors.

**Format:**
```markdown
# GitHub $PERIOD_CN 技术趋势报告($DATE)

## 📊 概述与趋势分析
*   **本期核心趋势**: [Summary of the overall tech direction this period]
*   **关注建议**: [Strategic advice for Roy regarding Finance/AI/Security trends]
*   **建议行动**: [Top 3 actionable steps for Roy]

---

## 🚀 热门项目详细分析

### 1. [owner/repo](url) 
`Tags` `Tags`
*   **是什么**: ...
*   **作用**: ...
*   **效果**: ...
*   **项目分析**: [Expert technical & market analysis]
*   **建议**: ...

... [Repeat for ALL items] ...
```

#### B. HTML Report (`report_YYYY-MM-DD.html`)
Clean, modern HTML for email and browser viewing.

**Style Guide**: See `references/example_report.html`.

### 6. Send Email

Send the **HTML content** as the email body to `zen9ha0@gmail.com`.

```bash
export GOG_KEYRING_PASSWORD=openclaw
# Use the dynamic variable defined in Step 2
REPORT_FILE="$REPORT_DIR/report_$DATE.html"
# Subject based on period: "GitHub Daily/Weekly/Monthly Trending Report ($DATE)"
SUBJECT="GitHub $(echo $PERIOD | sed 's/./\U&/') Trending Report ($DATE)"

gog gmail send \
  --to zen9ha0@gmail.com \
  --subject "$SUBJECT" \
  --body-html "$(cat $REPORT_FILE)"
```

---

## File Structure Output

Example for a daily run on 2026-02-17:

```text
workspace/
└── github_trending/
    └── daily/
        └── 2026-02-17/
            ├── original_trending.html       (Raw fetch result - MANDATORY)
            ├── report_2026-02-17.md         (Markdown report - MANDATORY)
            └── report_2026-02-17.html       (HTML report - MANDATORY)
```
