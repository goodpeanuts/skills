# GitHub Trending Report Output Contract

This document defines machine-checkable rules for report outputs.

## 1. Required Files

Under `github_trending/<period>/<YYYY-MM-DD>/`, all files must exist:
1. `original_trending.html`
2. `report_<YYYY-MM-DD>.md`
3. `report_<YYYY-MM-DD>.html`
4. `report_manifest.json`

## 2. Path Contract

1. `<period>` must be one of: `daily`, `weekly`, `monthly`.
2. `<YYYY-MM-DD>` must match the date used in report filenames and metadata.
3. Filenames must use the exact date from the directory name.

## 3. Source Completeness Contract

1. `original_trending.html` is the source of truth.
2. `source_item_count` in `report_manifest.json` must equal extracted source repo count.
3. Expected source count is usually 10-25; counts below 10 should be treated as suspicious.

## 4. Markdown Contract

`report_<date>.md` must include:
1. Top-level title matching date.
2. `## 📊 概述与趋势分析`
3. `## 🚀 热门项目详细分析`
4. Repo sections with exact pattern:
   `### N. [owner/repo](https://github.com/owner/repo)`
5. Required fields in each repo section:
   1. `是什么`
   2. `作用`
   3. `效果`
   4. `项目分析`
   5. `建议`
6. Numbering must be sequential from `1..N`.

## 5. HTML Contract

`report_<date>.html` must include:
1. `.overview-section`
2. `.repo-card` per repo
3. `.tag` badges (at least one per card)
4. `.suggestion-box` per card
5. Section heading `🚀 热门项目详细分析`
6. For each card: valid GitHub repo link and labels:
   1. `是什么`
   2. `作用`
   3. `效果`
   4. `项目分析`

Disallowed:
1. Markdown backticks in HTML body text.
2. Invalid HTML structure patterns like `<p><ul>` or `<p><ol>`.

## 6. Manifest Contract

`report_manifest.json` must include:
1. `date` (string, `YYYY-MM-DD`)
2. `period` (`daily|weekly|monthly`)
3. `source_item_count` (integer)
4. `reported_item_count` (integer)
5. `repos` (ordered list)

Each `repos[]` item must include:
1. `rank` (1-based sequential integer)
2. `repo` (`owner/repo`)
3. `url` (`https://github.com/owner/repo`)

## 7. Cross-File Consistency

All counts must match exactly:
1. source list count from `original_trending.html`
2. markdown repo section count
3. html `.repo-card` count
4. `reported_item_count`
5. `len(repos)` in manifest

Any mismatch is a hard failure.

## 8. Source-to-Report Repo Identity (Critical)

Use `original_trending.html` as canonical source list.

For every generated report, these three repo sequences must exactly match source list:
1. Markdown repo sequence
2. HTML repo-card repo sequence
3. Manifest `repos[].repo` sequence

Exact match means:
1. Same length
2. Same repo names
3. Same order

If any repo is missing, replaced, or re-ordered, validation must fail.
