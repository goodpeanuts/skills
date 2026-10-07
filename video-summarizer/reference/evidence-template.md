# 证据底稿 · {{TITLE}}

> 本文档是 summary.md 的可核验底稿：所有进入总结的辅助证据（画面、弹幕、评论）在此留痕。
> 完整结构化数据见 `evidence/audience.json`；原始文件（danmaku.xml / comments.json / frames/）不入 Git，可用 `--force` 重采。

## 1. 溯源

| 项 | 值 |
|----|----|
| 视频 ID / 平台 | {{ID}} / {{PLATFORM}} |
| 链接 | {{URL}} |
| UP 主 | {{UP_NAME}}（mid={{UP_MID}}） |
| 时长 / 总结时间 | {{DURATION}} / {{TIME}} |
| 字幕来源 | {{SUBTITLE_LANG}}（ai-zh=官方AI / zh-Hans=CC / whisper=本地转写） |
| 登录账号（Cookie 缓存） | {{ACCOUNT}} |
| 抓取方式 | pipeline_prepare.sh 机械阶段 + Agent 认知阶段 |

## 2. 弹幕分析

> 来源: evidence/danmaku.xml（解析结果见 audience.json `danmaku` 字段）

- 总条数 {{N}} · 密度 {{X}} 条/分钟
- **峰值时刻**（10s 窗口 Top3，供补帧与高能标注）:

| 时刻 | 条数 | 代表文本 | 对应内容 |
|------|------|----------|----------|
| m:ss | N | "…" | （该时刻视频在讲什么） |

- **高频文本**: 「文本」×N（含义/对应画面）

## 3. 评论区

> 来源: evidence/comments.json（热评 {{SAMPLED}}/{{TOTAL}} 条 + 最热楼中楼）

- 代表性评论摘录（原文 + 赞数；UP 主回复标注 [UP]）:
  - 「……」（赞 N）— 观众名
    - ↳「……」[UP]（赞 N）
- 归纳：共识 / 质疑 / 争议 / 观众实测补充（各一行，无则省略）

## 4. 关键帧观察

> 机械抽帧: evidence/frames/auto/（章节边界优先+均匀补齐，上限 12）
> Agent 补充帧: evidence/frames/agent/（`--at` 指定时刻，无上限；注明补帧动机）

| 文件 | 时间戳 | 画面观察（可读出的具体信息） | 补帧动机（agent 帧适用） |
|------|--------|------------------------------|--------------------------|
| auto/00-00-20.jpg | 0:20 | …… | — |
| agent/00-02-05.jpg | 2:05 | …… | 弹幕峰值/信息缺口：…… |

## 5. 原始文件清单

| 文件 | Git | 说明 |
|------|-----|------|
| subtitle.srt | 追踪 | 字幕源文本 |
| evidence/audience.json | 追踪 | 弹幕+评论结构化底账 |
| evidence/danmaku.xml | 忽略 | 弹幕原始 XML（重采可得） |
| evidence/comments.json | 忽略 | 评论原始 JSON（重采可得） |
| evidence/frames/*.jpg | 忽略 | 抽帧图片（重采可得） |
| video.mp4 / audio.mp3 | 忽略 | 媒体文件 |
