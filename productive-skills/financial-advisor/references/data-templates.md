# Financial Report Data Templates

This document provides structured templates for collecting data from each of the 10 report types in 随手记账本.

---

## Template Usage Guidelines

### Data Collection Methods

1. **Screenshot Method** (Recommended)
   - Take screenshots of each report
   - Claude will extract data from screenshots
   - Most accurate and complete

2. **Manual Input Method**
   - Use templates below to structure data entry
   - Fill in required fields at minimum
   - Claude will validate and work with provided data

3. **Hybrid Method**
   - Screenshots for key reports (Cash Flow, Income/Expense)
   - Manual input for supplementary details
   - Efficient for comprehensive analysis

### Field Notation

- `*` = Required field (analysis will be limited without this)
- `+` = Recommended field (improves analysis quality)
- `[Format]` = Expected data format

---

## 1. Cash Flow Statement (现金流量表)

### Purpose
Essential for liquidity analysis, emergency fund calculation, and overall financial health scoring.

### Template

```markdown
## Cash Flow Statement

**Period:** [YYYY-MM-DD to YYYY-MM-DD] *
**Report Type:** [Daily/Weekly/Monthly/Yearly/Custom] *

### Summary
- Total Income: ¥[Amount] *
- Total Expenses: ¥[Amount] *
- Net Cash Flow: ¥[Income - Expenses] *

### Income Breakdown
| Category | Sub-category | Amount | % of Total |
|----------|--------------|--------|------------|
| [一级分类] | [二级分类] | ¥[Amount] | [%] + |
| ... | ... | ... | ... |

**Top 3 Income Categories:**
1. [Category]: ¥[Amount] ([%])
2. [Category]: ¥[Amount] ([%])
3. [Category]: ¥[Amount] ([%])

### Expense Breakdown
| Category | Sub-category | Amount | % of Total |
|----------|--------------|--------|------------|
| [一级分类] | [二级分类] | ¥[Amount] | [%] + |
| ... | ... | ... | ... |

**Top 3 Expense Categories:**
1. [Category]: ¥[Amount] ([%])
2. [Category]: ¥[Amount] ([%])
3. [Category]: ¥[Amount] ([%])

### Cash Flow Metrics
- Average Daily Income: ¥[Amount] +
- Average Daily Expense: ¥[Amount] +
- Number of Income Transactions: [Count] +
- Number of Expense Transactions: [Count] +
```

### Minimum Viable Data
- Total Income
- Total Expenses
- Period covered

---

## 2. Income/Expense Detail Report (收支明细表)

### Purpose
Transaction-level analysis, pattern detection, anomaly identification.

### Template

```markdown
## Income/Expense Detail Report

**Period:** [YYYY-MM-DD to YYYY-MM-DD] *

### Transaction List
| Date | Type | Category | Sub-category | Amount | Account | Note |
|------|------|----------|--------------|--------|---------|------|
| [YYYY-MM-DD] | [Income/Expense] * | [一级分类] * | [二级分类] + | ¥[Amount] * | [Account Name] + | [Description] + |
| ... | ... | ... | ... | ... | ... | ... |

### Statistics
- Total Transactions: [Count] *
- Income Transactions: [Count] +
- Expense Transactions: [Count] +
- Average Transaction Size: ¥[Amount] +

### Largest Transactions (Top 5)
1. ¥[Amount] - [Category] - [Date] - [Description]
2. ¥[Amount] - [Category] - [Date] - [Description]
3. ¥[Amount] - [Category] - [Date] - [Description]
4. ¥[Amount] - [Category] - [Date] - [Description]
5. ¥[Amount] - [Category] - [Date] - [Description]
```

### Minimum Viable Data
- List of transactions with: Date, Type (Income/Expense), Category, Amount

---

## 3. Trend Chart (趋势图)

### Purpose
Historical pattern analysis, seasonality detection, forecasting.

### Template

```markdown
## Financial Trend Analysis

**Time Range:** [Start Month] to [End Month] *
**Granularity:** [Monthly/Weekly/Daily] *

### Monthly Data
| Month | Income | Expenses | Net Cash Flow | Net Worth | Savings Rate |
|-------|--------|----------|---------------|-----------|--------------|
| [YYYY-MM] * | ¥[Amount] * | ¥[Amount] * | ¥[Amount] | ¥[Amount] + | [%] + |
| ... | ... | ... | ... | ... | ... |

### Trend Observations
- **Income Trend:** [Increasing/Decreasing/Stable/Volatile] +
- **Expense Trend:** [Increasing/Decreasing/Stable/Volatile] +
- **Net Cash Flow Trend:** [Improving/Deteriorating/Stable] +
- **Seasonality:** [Describe patterns, e.g., higher spending in December] +

### Key Statistics
- Average Monthly Income: ¥[Amount]
- Average Monthly Expense: ¥[Amount]
- Average Monthly Net Flow: ¥[Amount]
- Best Month: [Month] (¥[Amount])
- Worst Month: [Month] (¥[Amount])
- Volatility Score: [% Standard Deviation]
```

### Minimum Viable Data
- 3+ months of Income and Expenses data

---

## 4. Budget vs Actual (预算对比)

### Purpose
Budget adherence analysis, variance investigation, future budgeting recommendations.

### Template

```markdown
## Budget vs Actual Comparison

**Period:** [YYYY-MM or YYYY] *

### Budget Performance Summary
- Total Budgeted Income: ¥[Amount] +
- Actual Income: ¥[Amount] *
- Income Variance: [%] (Over/Under budget)

- Total Budgeted Expenses: ¥[Amount] *
- Actual Expenses: ¥[Amount] *
- Expense Variance: [%] (Over/Under budget)

### Category-Level Comparison
| Category | Budget | Actual | Variance (¥) | Variance (%) | Status |
|----------|--------|--------|--------------|--------------|--------|
| [Category] * | ¥[Amount] * | ¥[Amount] * | ¥[Amount] | [%] | [Over/On/Under] |
| ... | ... | ... | ... | ... | ... |

### Categories Exceeding Budget
1. [Category]: Budgeted ¥[Amount], Spent ¥[Amount] ([%] over)
2. [Category]: Budgeted ¥[Amount], Spent ¥[Amount] ([%] over)
3. [Category]: Budgeted ¥[Amount], Spent ¥[Amount] ([%] over)

### Categories Under Budget
1. [Category]: Budgeted ¥[Amount], Spent ¥[Amount] ([%] under)
2. [Category]: Budgeted ¥[Amount], Spent ¥[Amount] ([%] under)
```

### Minimum Viable Data
- Budgeted amounts (at least expense budgets)
- Actual amounts
- Period covered

---

## 5. Member Report (成员报表)

### Purpose
Family financial contribution analysis, dependency assessment.

### Template

```markdown
## Member Financial Report

**Period:** [YYYY-MM or YYYY] *

### Member Summary
| Member Name | Total Income | Total Expenses | Net Contribution | % of Household |
|-------------|--------------|----------------|------------------|----------------|
| [Name] * | ¥[Amount] * | ¥[Amount] * | ¥[Income - Expenses] | [%] + |
| ... | ... | ... | ... | ... |

### Contribution Analysis
- **Primary Earner:** [Name] ([%] of total income)
- **Largest Spender:** [Name] ([%] of total expenses)
- **Net Contributors:** [List names with positive net]
- **Net Consumers:** [List names with negative net]

### Per-Capita Metrics
- Average Income per Member: ¥[Amount]
- Average Expense per Member: ¥[Amount]
- Income Inequality (Gini coefficient approximation): [Score] +
```

### Minimum Viable Data
- Member names
- Each member's income and/or expenses

---

## 6. Project Report (项目报表)

### Purpose
Project-based cost tracking, profitability analysis.

### Template

```markdown
## Project Financial Report

**Period:** [YYYY-MM-DD to YYYY-MM-DD] *

### Project Summary
| Project Name | Total Income | Total Expenses | Net Profit/Loss | ROI |
|--------------|--------------|----------------|-----------------|-----|
| [Project Name] * | ¥[Amount] * | ¥[Amount] * | ¥[Amount] | [%] + |
| ... | ... | ... | ... | ... |

### Project Details
#### [Project Name]
- **Duration:** [Start Date] to [End Date] +
- **Total Budget:** ¥[Amount] +
- **Actual Cost:** ¥[Amount]
- **Variance:** [%] (Over/Under budget)
- **Profitability:** [Profitable/Loss/Break-even]
- **Category Breakdown:**
  - [Category]: ¥[Amount] ([%])
  - [Category]: ¥[Amount] ([%])

### Top Projects by Profit
1. [Project]: ¥[Amount] profit ([%] ROI)
2. [Project]: ¥[Amount] profit ([%] ROI)

### Projects at Loss
1. [Project]: ¥[Amount] loss
2. [Project]: ¥[Amount] loss
```

### Minimum Viable Data
- Project names
- Income and/or expenses per project

---

## 7. Merchant Report (商家报表)

### Purpose
Spending pattern by vendor, loyalty assessment, negotiation opportunities.

### Template

```markdown
## Merchant Spending Report

**Period:** [YYYY-MM or YYYY] *

### Top Merchants
| Merchant Name | Category | Total Spent | # Transactions | Avg Transaction | % of Total |
|---------------|----------|-------------|----------------|-----------------|------------|
| [Name] * | [Category] + | ¥[Amount] * | [Count] + | ¥[Amount] + | [%] + |
| ... | ... | ... | ... | ... | ... |

### Spending Concentration
- **Top 3 Merchants:** [%] of total spending
- **Top 5 Merchants:** [%] of total spending
- **Top 10 Merchants:** [%] of total spending

### Category Distribution by Merchant
- [Merchant]: [Categories and %]
- [Merchant]: [Categories and %]

### Frequent Merchants
- Most transactions: [Merchant] ([Count] visits)
- Highest average: [Merchant] (¥[Amount] per visit)
```

### Minimum Viable Data
- Merchant names
- Amount spent per merchant

---

## 8. Balance Sheet (资产负债表)

### Purpose
Net worth calculation, asset allocation analysis, debt structure evaluation.

### Template

```markdown
## Balance Sheet

**As of Date:** [YYYY-MM-DD] *

### Assets

#### Cash Accounts (现金账户)
| Account Name | Balance | Currency | Notes |
|--------------|---------|----------|-------|
| [Name] * | ¥[Amount] * | CNY | + |

**Cash Subtotal: ¥[Amount]**

#### Financial Accounts (金融账户)
| Account Name | Institution | Balance | Interest Rate | Notes |
|--------------|-------------|---------|---------------|-------|
| [Name] * | [Bank/Platform] + | ¥[Amount] * | [%] + | + |

**Financial Subtotal: ¥[Amount]**

#### Virtual Accounts (虚拟账户)
| Platform | Balance | Convertibility | Expiration |
|----------|---------|----------------|------------|
| [Platform] * | ¥[Amount] * | [Easy/Medium/Hard] + | [Date] + |

**Virtual Subtotal: ¥[Amount]**

#### Credit Accounts (信用账户) - Available Credit
| Card/Line | Credit Limit | Current Balance | Available Credit | Interest Rate |
|-----------|--------------|-----------------|------------------|---------------|
| [Name] * | ¥[Amount] * | ¥[Amount] * | ¥[Limit - Balance] | [%] + |

**Available Credit: ¥[Amount]**

#### Claims (债权账户)
| Borrower/Source | Amount Owed | Due Date | Collectibility |
|-----------------|-------------|----------|----------------|
| [Name] * | ¥[Amount] * | [Date] + | [High/Medium/Low] + |

**Claims Subtotal: ¥[Amount]**

#### Investments (投资账户)
| Investment Type | Current Value | Cost Basis | Unrealized Gain/Loss | % of Portfolio |
|-----------------|---------------|------------|---------------------|----------------|
| [Type] * | ¥[Amount] * | ¥[Amount] + | ¥[Amount] + | [%] + |

**Investments Subtotal: ¥[Amount]**

#### Insurance (保险账户) - Cash Value Only
| Policy | Cash Value | Surrender Value |
|--------|------------|-----------------|
| [Name] | ¥[Amount] | ¥[Amount] |

**Insurance Cash Value: ¥[Amount]**

---

### Liabilities

#### Debt Accounts (负债账户)
| Debt Type | Lender | Total Balance | Monthly Payment | Interest Rate | Remaining Term |
|-----------|--------|---------------|-----------------|---------------|----------------|
| [Type] * | [Lender] + | ¥[Amount] * | ¥[Amount] + | [%] + | [Months] + |

**Debt Subtotal: ¥[Amount]**

#### Credit Card Balances (Used portion)
| Card | Balance | Interest Rate | Minimum Payment |
|------|---------|---------------|-----------------|
| [Name] * | ¥[Amount] * | [%] + | ¥[Amount] + |

**Credit Card Debt: ¥[Amount]**

---

### Summary

**Total Assets:** ¥[Sum of all asset categories] *
**Total Liabilities:** ¥[Sum of all debt categories] *
**Net Worth:** ¥[Total Assets - Total Liabilities] *

**Debt-to-Asset Ratio:** [%] *
**Asset Allocation:**
- Cash: [%]
- Financial: [%]
- Virtual: [%]
- Investments: [%]
- Claims: [%]
- Other: [%]
```

### Minimum Viable Data
- Total assets by major category (Cash, Financial, Investments)
- Total debt/liabilities
- Date of balance sheet

---

## 9. Category Hierarchy Reference (分类体系)

### Income Categories (收入分类)

| Level 1 | Level 2 Examples |
|---------|------------------|
| 职业收入 (Employment) | 工资, 奖金, 兼职 |
| 投资收益 (Investment) | 股息, 利息, 资本利得 |
| 经营收入 (Business) | 销售收入, 服务收入 |
| 转移收入 (Transfer) | 礼金, 红包, 报销 |
| 其他收入 (Other) | 退款, 中奖, 卖二手 |

### Expense Categories (支出分类)

| Level 1 | Level 2 Examples |
|---------|------------------|
| 餐饮 (Food & Dining) | 早餐, 午餐, 晚餐, 零食, 外卖 |
| 购物 (Shopping) | 服装, 日用品, 电子产品 |
| 交通 (Transportation) | 公共交通, 打车, 私家车 |
| 居住 (Housing) | 房租, 水电煤, 物业费 |
| 医疗 (Healthcare) | 药品, 门诊, 住院 |
| 娱乐 (Entertainment) | 电影, 游戏, 旅游 |
| 教育 (Education) | 学费, 书籍, 培训 |
| 社交 (Social) | 聚餐, 礼物, 红包 |
| 金融 (Finance) | 手续费, 利息, 保险 |
| 其他 (Other) | 杂项 |

---

## 10. Account Type Reference (账户类型)

| Type | Chinese | Typical Use | Liquidity |
|------|---------|-------------|-----------|
| Cash | 现金账户 | Physical currency | Highest |
| Financial | 金融账户 | Bank accounts, wallets | High |
| Virtual | 虚拟账户 | Gift cards, platform credits | Medium |
| Credit | 信用账户 | Credit cards, credit lines | Variable |
| Debt | 负债账户 | Loans, mortgages | N/A (liability) |
| Claims | 债权账户 | Money owed to you | Low |
| Investment | 投资账户 | Stocks, funds, real estate | Variable |
| Insurance | 保险账户 | Insurance policies with cash value | Low |

---

## Data Validation Checklist

Before submitting data for analysis, verify:

### For Cash Flow Analysis
- [ ] Income total matches sum of income categories
- [ ] Expense total matches sum of expense categories
- [ ] Period is clearly specified
- [ ] Currency is consistent (or exchange rates provided)

### For Balance Sheet
- [ ] All accounts listed with current balances
- [ ] Assets = sum of asset categories
- [ ] Liabilities = sum of liability categories
- [ ] Net worth = Assets - Liabilities
- [ ] Date is specified

### For Trend Analysis
- [ ] At least 3 months of data provided
- [ ] Consistent time intervals (monthly recommended)
- [ ] No missing months (or noted)

### For Budget Analysis
- [ ] Budget amounts specified for categories being compared
- [ ] Actual amounts for same period
- [ ] Period alignment (budget vs actual for same timeframe)

---

## Example: Minimal vs Comprehensive Data

### Minimal Viable Cash Flow (Quick Analysis)
```markdown
**Period:** 2024-02-01 to 2024-02-28
**Total Income:** ¥12,000
**Total Expenses:** ¥8,500
**Net Cash Flow:** ¥3,500
```

### Comprehensive Cash Flow (Full Analysis)
```markdown
**Period:** 2024-02-01 to 2024-02-28

**Total Income:** ¥12,000
  - Salary: ¥10,000 (83%)
  - Investment Returns: ¥1,500 (13%)
  - Other: ¥500 (4%)

**Total Expenses:** ¥8,500
  - Food & Dining: ¥2,500 (29%)
  - Shopping: ¥2,000 (24%)
  - Housing: ¥1,500 (18%)
  - Transportation: ¥800 (9%)
  - Entertainment: ¥600 (7%)
  - Healthcare: ¥400 (5%)
  - Other: ¥700 (8%)

**Net Cash Flow:** ¥3,500

**Daily Averages:**
- Average Daily Income: ¥428.57
- Average Daily Expense: ¥303.57
- Average Daily Net Flow: ¥125.00

**Transaction Counts:**
- Income: 3 transactions
- Expenses: 45 transactions
```

**Recommendation:** Start with minimal for quick insights, add detail for deeper analysis.
