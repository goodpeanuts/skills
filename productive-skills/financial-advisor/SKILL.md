---
name: financial-advisor
description: Professional financial analysis for Suishouji bookkeeping users, including health scoring, cash flow, debt/asset structure, transaction patterns, and actionable recommendations from report data.
metadata:
  display_name: financial advisor
---

# Financial Advisor

Financial analysis skill for 随手记账本 (Suishouji) data.

## When To Use

Use this skill when user asks for any of:
- 财务健康评分 / financial health score
- 收支、现金流、资产负债分析
- 交易明细异常、消费结构、预算偏差
- 账户类型分析（现金/金融/虚拟/信用/负债/债权/投资/保险）
- 个性化理财改进建议

## Required Skill Dependency (Chrome DevTools)

Before running any browser action in this skill:
1. Read `../chrome-devtools/SKILL.md`.
2. Follow that skill's browser operation rules first.
3. If rules conflict, apply the stricter rule set.
4. If dependency file cannot be read, stop and report dependency error before continuing.

## Non-Negotiable Browser Protocol (Chrome DevTools MCP)

If website data is required, this protocol is mandatory.

### Execution Constraints (Strict)

1. Max MCP connect attempts: 2 total (initial + 1 recovery).
2. Max navigation retries per target page: 2.
3. Do not run extraction before all checks pass:
   - `../chrome-devtools/SKILL.md` has been read for this task;
   - MCP connected;
   - authenticated report center visible.
4. On any hard failure, return explicit status code in message:
   - `DEPENDENCY_UNAVAILABLE`
   - `MCP_CONNECT_FAILED`
   - `AUTH_REQUIRED`
   - `REPORT_PAGE_UNAVAILABLE`
   - `CLEANUP_FAILED`

### Step 0: Session Ownership

1. Treat browser lifecycle as task-scoped.
2. Record whether this task started a browser instance.
3. Always close any browser instance started by this task during cleanup.

### Step 1: MCP Connect

1. Connect via Chrome DevTools MCP.
2. If connect succeeds, continue.
3. If connect fails, run recovery sequence exactly once:
   - Tell user to close existing browser instances.
   - Start a fresh browser instance.
   - Reconnect MCP.
4. If reconnect still fails, stop immediately with `MCP_CONNECT_FAILED`.

### Step 2: Navigate + Auth Gate

1. Navigate to `https://www.sui.com/report_index.do`.
2. Verify login state before any extraction.
3. If login page / auth redirect / missing report center is detected:
   - Stop immediately.
   - Tell user to log in first.
   - Return `AUTH_REQUIRED`.
   - Do not infer or fabricate missing data.

### Step 3: Deterministic Extraction Order

Extract in this order (stop on fatal errors):
1. Cash Flow Statement (现金流量表)
2. Balance Sheet (资产负债表)
3. Trend Chart (收支趋势图)
4. Optional: Transaction Detail (收支明细表)
5. Optional: Member/Project/Merchant reports

If report entry exists but cannot be opened after retries, stop with `REPORT_PAGE_UNAVAILABLE`.

### Step 4: Mandatory Cleanup (Finally Block Semantics)

Always execute cleanup even if analysis fails:
1. Close opened pages/tabs created by this task.
2. If this task started the browser instance, close it.
3. If cleanup fails, report `CLEANUP_FAILED`.
4. Return completion status with:
   - extraction success/failure;
   - whether cleanup completed;
   - what user must do next if blocked.

## Minimal Data Requirements

- Health score: Cash Flow + Balance Sheet
- Cash flow stability: Cash Flow + Trend (preferred)
- Transaction anomaly: Transaction Detail (preferred)
- Comprehensive report: Tier-1 + any available Tier-2 data

Tier-1 (required for baseline):
- Cash Flow Statement
- Balance Sheet

Tier-2 (quality boost):
- Trend Chart
- Transaction Detail
- Budget/Member/Project/Merchant reports

## Analysis Pipeline

1. Validate data integrity:
   - income subtotal consistency;
   - expense subtotal consistency;
   - assets - liabilities = net worth;
   - period and currency consistency.
2. Select analysis modules based on available data and user request.
3. Score with adaptive baselines (not fixed one-size-fits-all thresholds).
4. Generate prioritized recommendations with confidence level.

## Module Selector (Short Form)

- Module A: Overall Financial Health (0-100)
- Module B: Transaction Pattern and Anomaly
- Module C: Account-Type Deep Dive (8 account types)
- Module D: Asset/Debt/Expense Distribution
- Module E: Cash Flow Stability and Liquidity
- Module F: Consolidated Action Plan

Read detailed formulas/templates only when needed:
- `references/scoring-methodology.md`
- `references/financial-ratios.md`
- `references/account-analysis-guides.md`
- `references/recommendation-database.md`
- `references/data-templates.md`

## Adaptive and Anti-Bias Rules

1. All thresholds are baseline bands, not hard universal truth.
2. Calibrate by user context:
   - life stage;
   - income volatility;
   - cost-of-living level;
   - dependents/family burden;
   - user risk tolerance and goals.
3. Always disclose:
   - baseline threshold;
   - adjusted threshold;
   - adjustment reason.
4. If data is incomplete, reduce confidence and provide scenario ranges.
5. Use neutral language focused on risk and tradeoffs, not moral judgment.

## Output Contract

Structure output in this order:
1. Data coverage and confidence
2. Total score + component scores (if Module A used)
3. Key findings:
   - strengths;
   - risks;
   - anomalies.
4. Top 3 prioritized actions:
   - action;
   - measurable target;
   - timeline.
5. Assumptions and limitations
6. Follow-up checkpoint suggestion (monthly/quarterly)

## Failure Handling

- MCP connect failure after one recovery attempt:
  - stop and return actionable message.
- Not logged in:
  - stop and ask user to log in first.
- Critical data missing:
  - continue only with available modules and clearly mark coverage gaps.
- Any fatal runtime interruption:
  - run cleanup protocol before returning.

## Quick User Prompts

- “请分析我本月财务健康”
- “分析我的现金流稳定性和应急资金”
- “分析本月消费异常和可优化项”
- “给我一个分优先级的理财改进计划”
