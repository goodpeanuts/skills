# GitHub Trending Report Output Contract

This document defines machine-checkable rules for report outputs.

## 1. Required Files

For the workflow-selected report directory, all files must exist:
1. `original_trending.html`
2. `report_<YYYY-MM-DD>.md`
3. `report_<YYYY-MM-DD>.html`
4. `report_manifest.json`

## 2. Path Contract

1. `<period>` must be one of: `daily`, `weekly`, `monthly`.
2. `<YYYY-MM-DD>` must match the date used in report filenames and metadata.
3. Filenames must use the exact date from the directory name.
4. Output root policy is defined in `SKILL.md` (single source of truth).

## 3. Source Completeness Contract

1. `original_trending.html` is the source of truth.
2. `source_item_count` in `report_manifest.json` must equal extracted source repo count.
3. No fixed minimum source count is required; strict requirement is full correspondence with source list (same repos, same order, no omissions).

## 4. Unified Field Quality Contract

All output formats (Markdown/HTML) must include these fields with the following unified requirements:
These are semantic requirements and are not fully machine-gated by `scripts/validate_report.py`.

### 是什么
- **Structure**: 1-2 sentence description
- **Quality**: Concise, accurate repo summary

### 作用
- **Structure**: What problem it solves, for whom
- **Quality**: Clear value proposition and target audience

### 效果
- **Structure**: Attention signal + specific value
- **Quality Requirements**:
  - Must include observable attention/adoption signal (stars/forks/activity/momentum)
  - Must explain specific value for how to benefit daily work and improve productivity.
  - Template: "关注度[信号]，对我[具体工作场景]的价值是[具体帮助]"
  - Good: "关注度持续上升(stars周增500+)，对我的Agent PoC项目的价值是提供了一套可直接复用的沙箱隔离方案"
  - Bad: "关注度较高，值得关注"

### 项目分析
- **Structure**: Tech stack + mechanism + evidence + relevance + tradeoffs
- **Quality Requirements**:
  - Must include: technical stack, evidence-based mechanism analysis, risk/tradeoff
  - Deep dive required when README insufficient or claims are non-trivial (performance/security/finance-critical)
  - Template: "技术栈[XX]，核心机制[XX]，考虑到我的[项目/需求]，[具体帮助点]，但需注意[风险/限制]"
  - Good: "技术栈Python + async runtime，核心是事件驱动的任务调度器。考虑到我正在做的多Agent协同项目，它的异步编排机制可以直接解决当前串行执行的效率问题，但需注意其依赖Python 3.11+，与现有3.9环境不兼容"
  - Bad: "技术栈清晰，架构设计合理，适合深入学习"

### 建议
- **Structure**: Specific action + scope + prerequisite + expected outcome
- **Quality Requirements**:
  - **Required 4 elements**:
    1. Specific action (what exactly to do)
    2. Scope/boundary (where it applies, what's excluded)
    3. Prerequisite (what's needed before starting)
    4. Expected outcome (concrete benefit or metric)
  - **Forbidden phrases**: "建议关注", "值得研究", "可以尝试", "对提升XX能力有帮助", "建议深入学习", "建议进一步研究"
  - Good: "下周在Agent PoC中引入该项目的沙箱模块，替换当前简单的subprocess隔离。预计2天完成集成，可提升工具调用的安全性，但需先验证其对Windows环境的支持"
  - Bad: "建议深入学习该项目，对提升Agent开发能力有帮助"

### 概述与趋势分析 - 建议行动
- **Structure**: Overview section with prioritized action items
- **Quality Requirements**:
  - Must reference at least 2 specific repos from current report by name
  - Each action must include feasibility assessment (effort/risk/timeline)
  - Forbidden: generic advice applicable to any week
  - Good: "1. 本周优先评估 [microsoft/semantic-kernel] 的插件系统，可以解决当前Agent项目中工具注册混乱的问题，但需注意其与LangChain的生态差异"
  - Bad: "1. 每周优先审查 Top 项目的 stars/forks 增速"

## 5. Markdown Structure Contract

`report_<date>.md` must include:
1. Top-level title matching date
2. `## 📊 概述与趋势分析`
3. `## 🚀 热门项目详细分析`
4. Repo sections with exact pattern: `### N. [owner/repo](https://github.com/owner/repo)`
5. Sequential numbering from `1..N`

Each repo section must include all fields defined in Section 4 (Unified Field Quality Contract).

## 6. HTML Structure Contract

`report_<date>.html` must include:
1. `.overview-section`
2. `.repo-card` per repo
3. `.tag` badges (at least one per card)
4. `.suggestion-box` per card
5. Section heading `🚀 热门项目详细分析`

Each card must include all fields defined in Section 4 (Unified Field Quality Contract).

Disallowed:
- Markdown backticks in HTML body text
- Invalid HTML structure patterns (`<p><ul>`, `<p><ol>`)

## 7. Manifest Contract

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

## 8. Cross-File Consistency

All counts must match exactly:
1. source list count from `original_trending.html`
2. markdown repo section count
3. html `.repo-card` count
4. `reported_item_count`
5. `len(repos)` in manifest

Any mismatch is a hard failure.

## 9. Source-to-Report Repo Identity (Critical)

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

## 10. Example Interpretation (Critical)

`references/example_report.md` and `references/example_report.html` are demonstration files for output format, section structure, and field ordering.
They are not depth benchmarks.
Generated reports must be materially deeper than example wording, especially in `效果`, `项目分析`, and `建议`.

## 11. Personalization Context

**Quality Markers**:
- Context-aware benefit analysis (not generic praise)
- Specific use case or project reference
- Risk/benefit tradeoff analysis when applicable
- Time-bounded or scope-limited action items

All field-level personalization requirements are defined in Section 4 (Unified Field Quality Contract).

## 12. Input & Path Contract

Input and path rules are defined in `SKILL.md` (single source of truth) to avoid duplicated definitions.

## 13. Evidence Collection Requirements

### Baseline Evidence Collection (every repo):
1. Read README and other essential files (e.g. setup.py, main source files)
2. Inspect repo structure (root + key directories/files)
3. Extract architecture, usage, and target-user signals
4. Collect attention signals (stars/forks/activity/momentum)
5. Identify primary technical stack (languages, frameworks, deployment pattern)

### Deep Dive Triggers:
When README/structure is insufficient OR claims are non-trivial (performance/security/finance-critical):
- Inspect at least 2 key code/module evidence points
- Reflect mechanism, risks, and tradeoffs in 项目分析

## 14. Parallel Analysis Process

### Sub-Agent Spawning:
1. Spawn parallel sub-agents for each repository in Step 2 using Task tool (subagent_type: "general-purpose")
2. Launch ALL repo analysis sub-agents in a SINGLE message with multiple Task tool calls to maximize parallelism
3. This is a workflow semantic requirement and is not enforced by `scripts/validate_report.py`

### Sub-Agent Prompt Requirements:
Sub-agent prompts must reference Section 11 (Personalization) and Section 13 (Evidence Collection) for analysis requirements. Each sub-agent must:
1. Use `mcp__github__get_file_contents` to read README.md and key source files
2. Inspect repo structure to identify technical stack and architecture
3. Extract attention signals from repo metadata
4. Generate analysis following the personalization requirements in Section 11
5. Follow evidence collection guidelines in Section 13

### Aggregation:
After all sub-agents complete:
1. Assemble outputs into final report maintaining original ranking order
2. Synthesize 概述与趋势分析 section based on patterns across all repos
3. Ensure overview 建议行动 references specific repos from current report

### Error Handling:
If a sub-agent fails, retry that specific repo once. If still failing, log error and continue with remaining repos.

## 15. Retry & Failure Policy

### Validation Retry Policy:
1. If validation passes: continue to email send step
2. If validation fails: regenerate and validate again
3. Maximum retries: 2
4. If still failing after retries: stop and do not send email

### Hard Failure Conditions:
Stop and return errors if any of the following occurs:
1. Missing required output files
2. Source item mismatch with Markdown/HTML/manifest
3. Non-sequential ranking
4. Missing required analysis fields
5. Invalid GitHub repository links
6. Output path/date/period mismatch

Never send email when validation fails.
