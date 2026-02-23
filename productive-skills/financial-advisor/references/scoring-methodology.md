# Financial Health Scoring Methodology

## Overview

This document defines the quantitative scoring system (0-100 points) used to evaluate overall financial health. The score provides an objective assessment across four key dimensions.

### Calibration Rule (Important)

All thresholds in this document are default baseline bands, not fixed universal standards.

Before scoring, calibrate by user context:
- life stage;
- income volatility;
- cost-of-living level;
- dependent/family responsibilities;
- risk tolerance and stated goals.

When calibrating, report:
1. Baseline threshold from this document.
2. Adjusted threshold used in this case.
3. Reason for adjustment.

## Total Score Calculation

**Formula:** `Total Score = Net Asset Health (30) + Debt Management (25) + Cash Flow Stability (25) + Diversification (20)`

### Score Interpretation

| Score Range | Rating | Interpretation |
|-------------|--------|----------------|
| 85-100 | Excellent | Strong financial position, minor optimizations possible |
| 70-84 | Good | Solid foundation with room for improvement |
| 55-69 | Fair | Adequate but requires attention to specific areas |
| 40-54 | Poor | Significant issues requiring immediate action |
| 0-39 | Critical | Dangerous territory, urgent intervention needed |

Interpretation should be presented with confidence level (`high`/`medium`/`low`) based on data completeness and period length.

---

## Component 1: Net Asset Health (30 points)

Evaluates the strength and trajectory of net worth.

### Scoring Criteria

| Metric | Weight | Excellent (Full Points) | Good (75%) | Fair (50%) | Poor (25%) | Critical (0) |
|--------|--------|------------------------|------------|------------|------------|--------------|
| Net Worth Growth Rate | 10 pts | >10% annually | 5-10% | 0-5% | -5-0% | <-5% |
| Net Worth Absolute | 10 pts | >12× monthly expenses | 6-12× | 3-6× | 1-3× | <1× |
| Asset Quality* | 10 pts | >80% liquid/appreciating | 60-80% | 40-60% | 20-40% | <20% |

*Asset Quality: Percentage of assets that are liquid (cash, financial accounts) or appreciating (investments)

### Calculation Method

1. Calculate net worth: `Total Assets - Total Liabilities`
2. Calculate growth rate: `(Current Net Worth - Previous Period) / Previous Period × 100`
3. Calculate months of expenses covered: `Net Worth / Average Monthly Expenses`
4. Assess asset composition quality
5. Apply scoring matrix and sum

---

## Component 2: Debt Management (25 points)

Evaluates debt levels, structure, and management effectiveness.

### Scoring Criteria

| Metric | Weight | Excellent | Good | Fair | Poor | Critical |
|--------|--------|-----------|------|------|------|----------|
| Debt-to-Asset Ratio | 10 pts | <20% | 20-35% | 35-50% | 50-70% | >70% |
| Credit Utilization* | 8 pts | <30% | 30-50% | 50-70% | 70-90% | >90% |
| Debt Service Ratio** | 7 pts | <15% | 15-25% | 25-35% | 35-50% | >50% |

*Credit Utilization: For revolving credit (credit cards, lines of credit)
**Debt Service Ratio: Monthly debt payments / Monthly income

### Calculation Method

1. Calculate debt-to-asset ratio: `Total Liabilities / Total Assets × 100`
2. Calculate credit utilization: `Credit Balances / Credit Limits × 100`
3. Calculate debt service ratio: `Monthly Debt Payments / Monthly Income × 100`
4. Apply scoring matrix and sum

---

## Component 3: Cash Flow Stability (25 points)

Evaluates income stability, expense control, and liquidity management.

### Scoring Criteria

| Metric | Weight | Excellent | Good | Fair | Poor | Critical |
|--------|--------|-----------|------|------|------|----------|
| Emergency Fund* | 10 pts | ≥6 months | 4-6 months | 2-4 months | 1-2 months | <1 month |
| Savings Rate** | 8 pts | >30% | 20-30% | 10-20% | 5-10% | <5% |
| Income Stability*** | 7 pts | Very stable | Mostly stable | Moderate | Variable | Highly unstable |

*Emergency Fund: Months of essential expenses covered by liquid savings
**Savings Rate: (Income - Expenses) / Income × 100
***Income Stability: Based on income source diversification and consistency

### Income Stability Assessment

| Level | Characteristics | Score |
|-------|----------------|-------|
| Very Stable (7 pts) | Multiple income sources, <10% variation month-to-month | 100% |
| Mostly Stable (5-6 pts) | Primary stable source, <20% variation | 75% |
| Moderate (3-4 pts) | Mix of stable/variable, 20-30% variation | 50% |
| Variable (1-2 pts) | Primarily variable income, 30-50% variation | 25% |
| Highly Unstable (0 pts) | Unpredictable income, >50% variation | 0% |

### Calculation Method

1. Calculate emergency fund months: `Liquid Savings / Average Monthly Essential Expenses`
2. Calculate savings rate: `(Monthly Income - Monthly Expenses) / Monthly Income × 100`
3. Assess income stability based on variation and diversification
4. Apply scoring matrix and sum

---

## Component 4: Diversification (20 points)

Evaluates asset allocation, income sources, and risk distribution.

### Scoring Criteria

| Metric | Weight | Excellent | Good | Fair | Poor | Critical |
|--------|--------|-----------|------|------|------|----------|
| Asset Allocation* | 8 pts | Diversified across 4+ categories | 3 categories | 2 categories | 1-2, heavily concentrated | Single asset |
| Income Source Diversity** | 7 pts | 3+ sources | 2 sources | 1 primary + side | Single source | Unstable single |
| Expense Distribution*** | 5 pts | Balanced, no >30% category | Top category 30-40% | Top category 40-50% | Top category 50-60% | >60% in one category |

*Asset Allocation Categories: Cash, Financial, Investment, Virtual, Real Estate, Insurance
**Income Sources: Salary, freelance, investment returns, business income, etc.
***Expense Distribution: Based on primary expense categories

### Asset Concentration Risk

Calculate Herfindahl-Hirschman Index (HHI) for asset distribution:
- HHI < 2500 = Well diversified (8 pts)
- HHI 2500-4000 = Moderately concentrated (6 pts)
- HHI 4000-6000 = Concentrated (4 pts)
- HHI 6000-8000 = Highly concentrated (2 pts)
- HHI > 8000 = Dangerous concentration (0 pts)

---

## Red Line Thresholds

Automatic warnings triggered when ANY of these conditions are met:

### Critical Red Lines
- Net worth declining >10% over 3 months
- Debt-to-asset ratio >80%
- Emergency fund <0.5 months
- Negative cash flow for 3+ consecutive months
- Credit utilization >95%
- Single asset category >90% of portfolio

### Warning Red Lines
- Net worth declining 5-10%
- Debt-to-asset ratio 70-80%
- Emergency fund <1 month
- Negative cash flow for 2 months
- Credit utilization 85-95%
- Top expense category >60%

### Response Protocol

When red lines are triggered:
1. **Stabilize**: Propose immediate cash flow protection actions
2. **Alert**: Highlight in red in the report with ⚠️ symbol
3. **Prioritize**: Move to top of recommendation list
4. **Action**: Provide specific intervention steps with feasibility notes

---

## Example Calculation

### Scenario
- Net Worth: ¥150,000
- Previous Net Worth: ¥135,000
- Monthly Expenses: ¥8,000
- Total Assets: ¥180,000
- Total Liabilities: ¥30,000
- Credit Balances: ¥8,000
- Credit Limits: ¥20,000
- Monthly Debt Payments: ¥1,200
- Monthly Income: ¥12,000
- Liquid Savings: ¥40,000
- Assets: Cash 30%, Financial 25%, Investment 35%, Virtual 10%
- Income Sources: Salary (primary) + Investment returns
- Top Expense Category: 35%

### Component Scores

**Net Asset Health (30/30)**
- Growth Rate: (150k-135k)/135k = 11.1% → 10 pts
- Net Worth Coverage: 150k/8k = 18.75 months → 10 pts
- Asset Quality: 90% liquid/appreciating → 10/10 pts (Excellent level)
- **Subtotal: 30/30**

**Debt Management (20/25)**
- Debt-to-Asset: 30k/180k = 16.7% → 10/10 pts
- Credit Utilization: 8k/20k = 40% → 6/8 pts (Good level)
- Debt Service: 1.2k/12k = 10% → 7/7 pts
- **Subtotal: 20/25**

**Cash Flow Stability (21/25)**
- Emergency Fund: 40k/8k = 5 months → 10/10 pts
- Savings Rate: (12k-8k)/12k = 33.3% → 8/8 pts
- Income Stability: Mostly stable → 5/7 pts
- **Subtotal: 21/25**

**Diversification (18/20)**
- Asset Allocation: 4 categories, HHI = 2700 → 6/8 pts
- Income Diversity: 2 sources → 7/7 pts
- Expense Distribution: Top 35% → 5/5 pts
- **Subtotal: 18/20**

### Total Score
**30 + 20 + 21 + 18 = 89/100 → Excellent**

---

## Best Practices

### Data Quality Requirements
- Use at least 3 months of data for meaningful trends
- Include ALL accounts for accurate net worth
- Separate essential vs. discretionary expenses for emergency fund calculation
- Use average income when variable

### Adjustment Factors
- **Young professionals** (<30): Reduce emergency fund requirement to 3-6 months (from 6 months)
- **High-cost cities**: Increase expense coverage ratios by 20%
- **Variable income**: Increase emergency fund requirement by 50%
- **Retirees**: Focus more on asset quality and less on growth rate

### Reporting Standards
- Always report component sub-scores for transparency
- Highlight which metrics pulled score down
- Provide specific targets for improvement
- Include confidence level based on data quality

---

## References

- Financial Planning Association standards
- Consumer Financial Protection Bureau guidelines
- Modern Portfolio Theory (MPT) for diversification metrics
