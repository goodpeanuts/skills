---
name: video-summarizer
description: "Two-phase video summarization pipeline: mechanical stage (script) downloads video/audio/subtitles, fetches Bilibili AI subtitles (cookie-managed, probe-and-pick CC > ai-zh > ai-en), danmaku and comments evidence, extracts key frames; cognitive stage (agent) reads frames, optionally extracts supplementary frames, writes user-facing summary.md and evidence.md. Outputs archived under archive/YYYY-MM/<ID_title>/ with a JSON registry deduplicating already-summarized videos (BV id as key). Git tracks user-facing outputs only (summary.md, evidence.md, audience.json, subtitle.srt, registry); run-time intermediates (transcript, chapters.json, raw danmaku/comments) and media files are gitignored. Actions: summarize, 总结视频, 视频总结, 阅读版, download, transcribe, batch summarize, 批量总结. Platforms: 1800+ yt-dlp sites with Bilibili enhancement. Outputs: MP4, MP3, SRT, summary.md, evidence.md, audience.json."
---

# Video Summarizer

## Overview

两阶段 Pipeline：

1. **机械阶段（脚本，确定性）**：查重 → Cookie 管理 → 下载视频/音频 → 字幕探测选优 → 弹幕/评论采集消化 → 机械抽帧 → 归档建目录
2. **认知阶段（Agent，判断性）**：读关键帧（按需补帧）→ whisper 兜底转写 → 生成 summary.md（纯用户向）+ evidence.md（证据底稿）→ 回写 registry

支持 yt-dlp 全部 1800+ 平台；B 站有增强（AI 字幕/弹幕/评论/合集/收藏夹批量）。

## Trigger Conditions

- 用户提供视频链接并要求总结/下载/转写/提取内容
- "总结这个视频"、"这视频讲了什么"、"批量总结这个合集/收藏夹"
- bilibili.com / youtube.com / x.com / tiktok.com / vimeo.com 等任意 yt-dlp 支持的链接

## Output Structure

所有产出在**项目根目录**下按年月归档（单树布局，Git 只追踪文本）：

```
archive/
├── registry.json                     # 已总结视频登记簿（BV/视频ID 主键）← 追踪
└── 2026-10/
    └── BV14tTj6CEuM_0成本搭建网络小店/
        ├── video.mp4 / audio.mp3          ← gitignore
        ├── subtitle.srt                    ← 追踪（字幕源文本）
        ├── summary.md                     ← 追踪（纯用户向，零证据痕迹）
        ├── evidence.md                    ← 追踪（证据底稿，文本溯源）
        └── evidence/
            ├── audience.json              ← 追踪（弹幕+评论结构化底账）
            ├── chapters.json              ← gitignore（抽帧/模板的运行时中间件）
            ├── danmaku.xml / comments.json ← gitignore（原始数据，--force 可重采）
            └── frames/{auto,agent}/*.jpg   ← gitignore
cache/
└── cookies.json                       ← 登录凭证，gitignore（平台命名空间 JSON）
```

## Workflow

### Step 0: Install Dependencies

```bash
bash "$SKILL_DIR/scripts/install_deps.sh"
```

安装 uv / yt-dlp / ffmpeg；faster-whisper 由 uv 管理。

### Step 1: Mechanical Stage（脚本）

**在项目根目录运行**：

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL"        # 已总结过会打印 SKIP 并退出
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL" --force # 强制重采
```

脚本完成：registry 查重、Cookie 确保（`cache/cookies.json`，缺失/失效自动从 Chrome 导出）、视频/音频下载、B 站字幕探测选优（CC zh-Hans/zh > ai-zh > ai-en；其他平台通用字幕→自动字幕）、弹幕 XML、评论热评 30+楼中楼、官方章节、机械抽帧（章节边界优先+均匀补齐，≤12 帧）。

**stdout 末行是 JSON 摘要**（folder/id/title/duration/platform/subtitle_lang/needs_whisper），据此进入认知阶段。

### Step 2: Cognitive Stage（Agent）

按摘要 JSON 依次：

1. **读帧**：逐张查看 `evidence/frames/auto/*.jpg`（Read 图片），把画面事实记录下来（界面路径、数据、演示效果——口播没讲的信息）。
2. **按需补帧**（无上限）：弹幕峰值时刻（audience.json `danmaku.peaks[].t`）、字幕提到"看这个界面"但机械帧未覆盖、信息密集段无视觉佐证时：
   ```bash
   bash "$SKILL_DIR/scripts/extract_frames.sh" "<folder>/video.mp4" "<folder>/evidence/frames/agent" --at "65,130.5,208"
   ```
3. **whisper 兜底**（`needs_whisper: 1` 时）：
   ```bash
   uv run "$SKILL_DIR/scripts/parallel_transcribe.py" --input "<folder>/audio.mp3" \
     --output-dir "<folder>" --model small --language auto
   mv <folder>/subtitle.vtt <folder>/subtitle.srt 2>/dev/null || true
   ```
4. **生成 summary.md**：按 `$SKILL_DIR/reference/summary-prompt.md` 填充占位符（TITLE/PLATFORM/URL/DURATION/LANGUAGE/DOWNLOAD_TIME/CHAPTERS/TRANSCRIPT/FRAMES=你的读帧观察/AUDIENCE=audience.json 消化版）。遵守证据法则：正文零证据痕迹。
5. **生成 evidence.md**：按 `$SKILL_DIR/reference/evidence-template.md`，承接全部溯源细节（含 [UP] 标注、峰值表、帧观察表、原始文件清单）。

### Step 3: Finish（回写 registry）

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" finish \
  --id "<id>" --title "<title>" --folder "<folder>" --duration <dur> \
  --subtitle-lang "<subtitle_lang>" --platform "<platform>"
```

### Batch Mode（B 站合集/收藏夹/稍后再看）

1. 枚举列表：
   ```bash
   yt-dlp --cookies cache/_bilibili.cookies.txt --flat-playlist --print "%(id)s" \
     'https://space.bilibili.com/<mid>/favlist?fid=<fid>'        # 或 collectiondetail?sid= / watchlater
   ```
2. 逐个执行 Step 1–3（Step 1 的 SKIP 机制天然跳过已总结视频）。
3. 批量时降采样：每视频读帧 ≤6 张、评论消化 ≤15 条，防止上下文爆炸；registry 累积进度，中断可续跑。

## Platform-Specific Notes

- **Bilibili**：字幕 ai-zh/ai-en/ai-ja（AI 生成，需登录 Cookie）；danmaku 是 XML 弹幕；评论区经 v2/reply API（热评排序）。Cookie 存 `cache/cookies.json`（`bilibili` 命名空间，Netscape 派生文件给 yt-dlp），**该文件是登录凭证，绝不入 Git**。
- **其他平台**：通用字幕链路（--write-subs → auto-subs → whisper）；无弹幕/评论环节，`audience.json` 不生成，观众反馈洞察章自然缺席。

## Git Conventions

目录职责铁律：**功能性脚本与约束全部在 Skill 内**（本目录）；**认证/缓存/凭据全部在项目级临时目录 `cache/`**；**总结产物全部入 Git 追踪**。Skill 本体经 Skill Manager 管理（真实存储 `~/.agents/skills/video-summarizer`，`~/.zcode/skills/` 下为软链接）。

`.gitignore` 必须包含（首次运行前确保就位）：

```
# 媒体与二进制
*.mp4
*.mp3
*.jpg
*.png
*.m4a
# 凭证与缓存（cache/ 含 cookies、whisper 模型等临时态）
cache/
/cookies.txt
.venv/
# 运行时原料与原始证据（消化版 audience.json/evidence.md 保留追踪）
archive/**/evidence/danmaku.xml
archive/**/evidence/comments.json
archive/**/evidence/chapters.json
# 本地研究/测试目录
downloads/
research/
login_qr.png
.DS_Store
__pycache__/
```

原则：**Git 只追踪文本**；evidence.md 的文本溯源（ID/时间戳/出处）不依赖二进制存在，媒体可随时 `--force` 重采。

## Error Handling

- **SKIP 提示**：视频已总结 → 直接引用归档位置，除非用户要求重跑（--force）。
- **无字幕且 whisper 无有效语音**：按提示词规则 8 拒绝编造，输出失败原因。
- **Cookie 导出失败**（无 Chrome/未登录）：提示用户登录或改扫码；降级为无登录（仍可拿 CC 字幕）。
- **HuggingFace 限速**（whisper 模型下载失败）：从 ModelScope 手动下载模型放到 `cache/whisper-models/`，改用本地模型转写：
  ```bash
  uv run "$SKILL_DIR/scripts/transcribe_local.py" <audio.mp3> <folder> [cache/whisper-models/faster-whisper-small]
  ```
- **视频过长（>1 小时）**：询问用户是否只处理部分；whisper 分片转写自动处理。
- **风控（HTTP 412/352）**：稍后重试或补充 buvid Cookie。

## Notes

1. 产出目录固定在项目根 `archive/YYYY-MM/`，registry 在 `archive/registry.json`。
2. 仅限个人学习用途；遵守平台条款。
3. 首次 whisper 运行需下载模型（small ≈244MB）。
4. 长音频（>60s）自动静音分片、多核并行转写。
