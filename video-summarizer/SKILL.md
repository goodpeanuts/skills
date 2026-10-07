---
name: video-summarizer
description: "Summarize, download, or transcribe videos from any of 1800+ yt-dlp supported platforms (Bilibili, YouTube, X/Twitter, TikTok, Vimeo...). Two-phase pipeline: a mechanical script stage fetches video/audio/subtitles/comments/danmaku/key-frames into a per-month per-platform archive, then the cognitive stage reads frames and writes a standalone reading-style summary plus an evidence dossier. Use whenever the user shares a video link and asks to summarize/transcribe/download it, 总结视频 / 视频总结 / 这视频讲了什么 / 阅读版 / 批量总结合集·收藏夹·播放列表, or wants a quick in-chat answer about a video. Bilibili gets enhanced capabilities (AI subtitles, danmaku, hot comments, favlist/collection/watchlater batch)."
---

# Video Summarizer

`$SKILL_DIR` 指本 Skill 根目录（加载 Skill 时给出的 base directory）。

## Overview

两阶段 Pipeline，全平台能力模型（平台 = yt-dlp extractor_key 小写归一化）：

1. **机械阶段（脚本，确定性）**：`init` → 单次 `yt-dlp -J` 全量元数据 → registry 按 `平台/ID` 查重 → Cookie 确保（按平台配置表）→ 下载视频+本地抽音频 → 统一字幕探测选优 → 章节/弹幕/评论采集 → 自适应抽帧 → 归档
2. **认知阶段（Agent，判断性）**：读关键帧（按需补帧）→ whisper 兜底转写 → 生成 summary.md（纯用户向）+ evidence.md（证据底稿）→ `finish` 回写 registry

字幕/章节/评论/弹幕/Cookie 各为独立能力位；平台缺某能力时对应产物自然缺席，不报错、不硬凑。

## Quick Mode（快速模式 · 零落档）

用户只要"简单说说/快速总结"、不需要归档时：

1. `tmp=$(mktemp -d)`，yt-dlp 把字幕下到 `$tmp`（无字幕则下音频用 whisper 临时转写到 `$tmp`）
2. 读字幕后**直接在聊天框作答**；约束最小化：不编造、可带时间戳，无需模板
3. **项目内零写入**：不建 archive 目录、不写 registry、无任何被追踪产物；`$tmp` 留给系统清理

## Output Structure

产出在**项目根目录**下按 `年月/平台` 归档（目录名经跨平台消毒：非法字符→`_`、结尾点空格剥离、Windows 保留名规避、40 字符截断、空兜底 `untitled`；实现见 `scripts/pipeline_meta.py`）：

```
archive/
├── registry.json                        ← 追踪（已总结登记簿，嵌套键 平台/ID）
└── 2026-10/
    └── bilibili/                        ← 平台子目录（归一化键）
        └── BV14tTj6CEuM_消毒后标题/
            ├── summary.md               ← 追踪（纯用户向总结，零证据痕迹）
            ├── evidence.md              ← 追踪（人读证据底稿）
            ├── meta.json                ← 追踪（机械阶段元数据+字幕选择溯源）
            ├── raw/
            │   ├── subtitle.srt         ← 追踪
            │   └── video.* / audio.*    ← 忽略（实际文件名记在 meta.json）
            └── evidence/
                ├── audience.json        ← 追踪（评论+弹幕结构化底账）
                ├── danmaku.xml          ← 忽略（bilibili 专属）
                ├── comments.info.json   ← 忽略（评论原始侧账）
                ├── chapters.json        ← 忽略
                └── frames/*.jpg         ← 忽略
cache/                                   ← 整目录忽略（cookies.json 平台命名空间、whisper 模型）
```

registry 条目（平台由键名表达，条目内不重复存 platform/extractor）：

```json
{"videos": {"bilibili": {"BV14tTj6CEuM": {
  "title": "...", "folder": "archive/2026-10/bilibili/BV..._...",
  "url": "...", "duration": 218, "language": "zh", "uploader": "...",
  "subtitle_lang": "ai-zh", "subtitle_source": "manual",
  "summarized_at": "..."}}}}
```

## Workflow

### Step 0: Install Dependencies（首次）

```bash
bash "$SKILL_DIR/scripts/install_deps.sh"
```

### Step 1: 机械阶段（项目根目录运行）

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" init    # 首次：建 archive/ cache/ + 补齐 .gitignore（幂等）
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL"          # 已总结过会打印 SKIP 并退出
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL" --force  # 强制重采
```

`--sub-pref "zh-Hans,en"` 可覆盖默认字幕偏好 `[zh-Hans, zh, zh-Hant, 视频原语言, en]`。

**stdout 末行是交接 JSON**（唯一契约行），字段：

| 字段 | 含义 |
|------|------|
| folder / id / platform | 归档目录、视频 ID、平台键 |
| title / url / duration / language / uploader | 元信息 |
| video_file / audio_file | 媒体实际相对路径（**不要假设 video.mp4**） |
| subtitle_lang / subtitle_source | 选中字幕与来源（manual/auto/whisper/none） |
| needs_whisper | 1 = 无字幕，需 whisper 兜底 |
| has_danmaku / has_comments | 弹幕/评论能力位是否产出 |
| chapters | 官方章节数（0 = 无，时间线自行分段） |

### Step 2: 认知阶段（Agent）

1. **读帧**：逐张 Read `evidence/frames/*.jpg`，记录画面事实（界面路径、数据、演示效果——口播没讲的信息）。
2. **按需补帧**（无上限）：弹幕峰值时刻（audience.json `danmaku.peaks[].t`）、字幕说"看这个界面"但机械帧未覆盖、信息密集段无视觉佐证时：
   ```bash
   bash "$SKILL_DIR/scripts/extract_frames.sh" "<folder>/<video_file>" "<folder>/evidence/frames" --at "65,130.5,208"
   ```
3. **whisper 兜底**（`needs_whisper: 1` 时；HF 限速改用 `--model-path` 指向本地模型目录，如 ModelScope 下载的 `cache/whisper-models/faster-whisper-small`）：
   ```bash
   uv run "$SKILL_DIR/scripts/parallel_transcribe.py" --input "<folder>/<audio_file>" \
     --output-dir "<folder>/raw" --model small --language auto
   ```
   输出直落 `raw/subtitle.srt`。
4. **生成 summary.md**：按 `$SKILL_DIR/reference/summary-prompt.md` 填充占位符（FRAMES=读帧观察；AUDIENCE=audience.json 消化版；无评论无弹幕时观众反馈项留空）。遵守证据法则：正文零证据痕迹。
5. **生成 evidence.md**：按 `$SKILL_DIR/reference/evidence-template.md` 承接全部溯源细节。

### Step 3: 回写 registry

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" finish \
  --platform "<platform>" --id "<id>" --title "<title>" --folder "<folder>" \
  --duration <dur> --subtitle-lang "<最终字幕语言>" --subtitle-source "<manual|auto|whisper>" \
  --url "<url>" --uploader "<uploader>" --language "<language>"
```

finish 会校验 `<folder>/summary.md` 存在，未完成认知阶段拒写。

## Platform Capabilities

| 能力 | bilibili | 其他平台 |
|------|----------|----------|
| 字幕 | CC + ai-\*（需登录 Cookie） | 通用 subtitles / automatic_captions |
| 章节 | 通用 | 通用 |
| 评论 | v2/reply API（热评 top30+楼中楼） | yt-dlp `--write-comments`（YouTube 等原生支持） |
| 弹幕 | XML | 无（audience.json 中 danmaku=null） |
| Cookie | Chrome 自动导出+校验 | 默认免 Cookie；手动放 `cache/_<platform>.cookies.txt` 即生效 |

## Batch Mode（合集/收藏夹/稍后再看/任意播放列表）

1. **先确保 Cookie**（B 站批量列表需要登录态）：
   ```bash
   python3 "$SKILL_DIR/scripts/ensure_cookies.py" ensure --platform bilibili --url "https://www.bilibili.com/"
   ```
2. 枚举列表（任意 yt-dlp 支持的播放列表 URL 均可）：
   ```bash
   yt-dlp --cookies cache/_bilibili.cookies.txt --flat-playlist --print "%(id)s" \
     'https://space.bilibili.com/<mid>/favlist?fid=<fid>'   # 或 collectiondetail?sid= / watchlater / YouTube playlist
   ```
3. 逐个执行 Step 1–3（SKIP 机制对全平台生效，天然跳过已总结视频；registry 累积进度，中断可续跑）。
4. 批量降采样：每视频读帧 ≤6 张、评论消化 ≤15 条，防止上下文爆炸。
5. **不要逐视频向用户提问**（含超长视频）：默认完整处理，事后汇总告知。

## Git Conventions

- `init` 托管 `.gitignore`（幂等补齐），全部模式 scoped 在 `archive/`、`cache/` 下，无全局通配，不影响宿主项目其他文件
- 追踪白名单：registry.json、summary.md、evidence.md、meta.json、raw/subtitle.srt、evidence/audience.json；其余忽略
- `cache/` 是登录凭证与模型缓存，**绝不入 Git**；evidence.md 的文本溯源不依赖二进制存在，媒体可随时 `--force` 重采

## Error Handling

- **SKIP**：视频已总结 → 直接引用归档位置；用户要求重跑才加 `--force`
- **无字幕且 whisper 无有效语音**：按 summary-prompt 的「无有效口播时拒绝编造」规则输出失败原因，不编内容
- **Cookie 失败**（无 Chrome/未登录）：脚本报错并给手动放置指引（`cache/_<platform>.cookies.txt`，Netscape 格式）。B 站无登录态通常无字幕可下，不要假装能降级拿 CC
- **HuggingFace 限速**：从 ModelScope 下载模型放 `cache/whisper-models/`，whisper 命令改带 `--model-path cache/whisper-models/faster-whisper-small`
- **视频过长（>1 小时）**：默认完整处理（whisper 自动分片），单视频模式可先告知用户耗时；批量模式一律直接处理
- **B 站风控（HTTP 412/352）**：稍后重试或补充 buvid Cookie
- **目录冲突**：归档目录已存在但 registry 未登记该 ID → 脚本报错拒跑，人工检查后处理

## Notes

1. 产出固定在项目根 `archive/YYYY-MM/`（年月=处理时间），registry 在 `archive/registry.json`。
2. 仅限个人学习用途；遵守平台条款。
3. 首次 whisper 运行需下载模型（small ≈244MB）；长音频自动静音分片、多核并行转写。
