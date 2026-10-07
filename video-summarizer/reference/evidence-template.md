# 证据底稿 · {{TITLE}}

> 本文档是 summary.md 的可核验底稿：所有进入总结的辅助证据（画面、弹幕、评论）在此留痕。
> 完整结构化数据见 `evidence/audience.json`；机械阶段元数据见 `meta.json`；
> 素材（danmaku.xml / comments.info.json / frames/ 等）不入 Git，可用 `--force` 重采（落回原归档目录）。
> 占位符取值来源：本表各项 ← meta.json；观众数据 ← audience.json；章节 ← chapters.json。

## 1. 溯源

| 项 | 值 |
|----|----|
| 平台 / 视频 ID | {{PLATFORM}} / {{ID}} |
| 链接 | {{URL}} |
| 作者 | {{UPLOADER}}（id={{UPLOADER_ID}}） |
| 时长 / 总结时间 | {{DURATION}} / {{TIME}} |
| 字幕来源 | {{SUBTITLE_LANG}}（subtitle_source: manual=人工或CC / auto=自动生成 / whisper=本地转写；以 meta.json 为准） |
| 登录账号（Cookie 缓存） | {{ACCOUNT}}（meta.json `account`，无登录态时为空） |
| 抓取方式 | pipeline_prepare.sh 机械阶段 + Agent 认知阶段 |

## 2. 弹幕分析（bilibili 专属能力位，无弹幕数据时整章省略）

> 来源: evidence/danmaku.xml（解析结果见 evidence/audience.json `danmaku` 字段）

- 总条数 {{N}} · 密度 {{X}} 条/分钟
- **峰值时刻**（10s 窗口不重叠 Top3，供补帧与高能标注）:

| 时刻 | 条数 | 代表文本 | 对应内容 |
|------|------|----------|----------|
| m:ss | N | "…" | （该时刻视频在讲什么） |

- **高频文本**: 「文本」×N（含义/对应画面）

## 3. 评论区（平台支持评论时保留，无数据时整章省略）

> 来源: bilibili 为 v2/reply API 热评，其他平台为 yt-dlp --write-comments；
> 原始侧账 evidence/comments.info.json（不入 Git）

- 代表性评论摘录（原文 + 赞数；作者回复标注 [UP]）:
  - 「……」（赞 N）— 观众名
    - ↳「……」[UP]（赞 N）
- 归纳：共识 / 质疑 / 争议 / 观众实测补充（各一行，无则省略）

## 4. 关键帧观察

> 全部帧统一存放 evidence/frames/*.jpg（下表"补帧动机"列区分来源）
> 机械抽帧 = 章节边界优先+均匀补齐（自适应上限，时长/75s 夹 8..20，实际张数见 meta.json frames.extracted）；
> Agent 补充帧 = `--at` 指定时刻，无上限

| 文件 | 时间戳 | 画面观察（可读出的具体信息） | 补帧动机（agent 帧适用） |
|------|--------|------------------------------|--------------------------|
| 00-00-20.jpg | 0:20 | …… | — |
| 00-02-05.jpg | 2:05 | …… | 弹幕峰值/信息缺口：…… |

## 5. 原始文件清单（本归档实际情况；Git 追踪规则以项目 .gitignore 托管块为单一事实源）

| 文件 | Git | 说明 |
|------|-----|------|
| summary.md / evidence.md / meta.json | 追踪 | 用户交付物 + 溯源底稿 |
| raw/subtitle.srt | 追踪 | 字幕源文本 |
| evidence/audience.json | 追踪 | 弹幕+评论结构化底账 |
| evidence/danmaku.xml | 忽略 | 弹幕原始 XML（bilibili，重采可得） |
| evidence/comments.info.json | 忽略 | 评论原始侧账（重采可得） |
| evidence/chapters.json | 忽略 | 官方章节（含 end_time，重采可得） |
| evidence/frames/*.jpg | 忽略 | 抽帧图片（重采可得） |
| raw/video.* / raw/audio.* | 忽略 | 媒体文件（实际文件名见 meta.json；无音轨时无 audio） |
