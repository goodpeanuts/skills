---
name: video-summarizer
description: "Summarize, download, or transcribe videos from any of 1800+ yt-dlp supported platforms (Bilibili, YouTube, X/Twitter, TikTok, Vimeo...). Two-phase pipeline: a mechanical script stage fetches video/audio/subtitles/comments/danmaku/key-frames into a per-month per-platform archive, then the cognitive stage reads frames and writes a standalone reading-style summary plus an evidence dossier. Use whenever the user shares a video link and asks to summarize/transcribe/download it, 总结视频 / 视频总结 / 这视频讲了什么 / 阅读版 / 批量总结合集·收藏夹·播放列表, or wants a quick in-chat answer about a video. Bilibili gets enhanced capabilities (AI subtitles, danmaku, hot comments, favlist/collection/watchlater batch)."
---

# Video Summarizer

`$SKILL_DIR` 指本 Skill 根目录（加载 Skill 时给出的 base directory）。

## Overview

两阶段 Pipeline，全平台能力模型（平台 = yt-dlp extractor_key 小写归一化；generic 提取器按网页 host 消歧为 `generic_<哈希>`，避免不同网站 id 碰撞）：

1. **机械阶段（脚本，确定性）**：`init` → 单次 `yt-dlp -J` 全量元数据 → registry 按 `平台/ID` 查重 → Cookie 确保（按 `scripts/platforms.json` 平台能力表）→ 下载视频+本地抽音频（audio-only 源直接拉音频）→ 统一字幕探测选优 → 章节/弹幕/评论采集 → 合集归属反查（season_lookup 能力位平台）→ 自适应抽帧（近重复帧剔除） → 归档
2. **认知阶段（Agent，判断性）**：体裁判定（教程/讲座/测评/访谈/资讯/观点/娱乐）→ 读关键帧（按需补帧）→ whisper 兜底转写 → 生成 summary.md（四章节骨架：TL;DR → 脉络总览 → 逐段详解 → 延伸）+ evidence/evidence.md（证据底稿）→ `finish` 回写 registry → `verify` 交付验收。**finish 与 verify 是认知阶段的强制收尾**（交接 JSON 带 `must_run_finish: true`）：漏 finish 会让 registry 查重失效（同视频被重采），verify FAIL 必须回修后才算交付完成

字幕/章节/评论/弹幕/合集反查/Cookie 各为独立能力位；平台缺某能力时对应产物自然缺席，不报错、不硬凑（Cookie 失败也按 `on_failure` 策略降级而非一律终止）。能力位由 `scripts/platforms.json` 声明，**取值是实现枚举**：复用现有实现的新平台 = 加一个数据项；需要新实现（如第二个弹幕平台）= 改对应能力组件 + 加数据项（枚举清单见 platforms.json `_meta.note`）。

## Quick Mode（快速模式 · 项目内零写入）

用户只要"简单说说/快速总结"、不需要归档时：

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" quick "VIDEO_URL" [--tmp <DIR>]
```

stdout 末行是取材 JSON：`registry_hit` 非空 → 直接 Read 该 folder 的 summary.md 作答；否则读 `subtitle_file`（选优规则与深度模式一致）；`needs_whisper=1` → 用 `audio_file` 跑 whisper 临时转写再作答。全部产物（含 Cookie 派生物）落在 `--tmp`（缺省系统临时目录）；项目内已有 cookie 文件时**复制工作副本消费**（yt-dlp 会回写 `--cookies` 目标文件），保证**项目内零写入**、不建 archive、不写 registry。作答约束最小化：不编造、可带时间戳，无需模板。

也可先用 `lookup "VIDEO_URL"`（只读、不触发 Cookie）单独查档：`HIT <folder>` / `MISS <平台/ID>`（registry 条目悬空——目录无 summary.md——按 MISS 处理并告警）。

## Output Structure

产出在**项目根目录**下按 `年月/平台` 归档（目录名经跨平台消毒：非法字符→`_`、结尾点空格剥离、Windows 保留名规避、ID 60 + 标题 40 字符截断、空兜底 `untitled`；实现见 `scripts/pipeline_meta.py`）：

```
archive/
├── registry.json                        ← 追踪（已总结登记簿，嵌套键 平台/ID）
└── 2026-10/
    └── bilibili/                        ← 平台子目录（归一化键）
        └── BV14tTj6CEuM_消毒后标题/
            ├── summary.md               ← 追踪（纯用户向总结，四章节骨架 TL;DR/脉络总览/逐段详解/延伸；零证据痕迹；可含帧插图相对链接）
            ├── raw/
            │   ├── meta.json            ← 追踪（机械阶段元数据+采集终态，finish 回写字幕终态）
            │   ├── subtitle.srt         ← 追踪
            │   └── video.* / audio.*    ← 忽略（实际文件名记在 meta.json；audio-only 源只有 audio）
            └── evidence/
                ├── evidence.md         ← 追踪（人读证据底稿）
                ├── audience.json        ← 追踪（评论+弹幕结构化底账）
                ├── danmaku.xml          ← 忽略（bilibili 专属）
                ├── comments.info.json   ← 忽略（评论原始侧账）
                ├── chapters.json        ← 忽略（含 start_time/end_time/title）
                └── frames/*.jpg         ← 忽略（文件名=HH-MM-SS 时间戳；summary 以相对链接引用，缺失可按时间戳回溯/重采）
cache/                                   ← 整目录忽略（cookies.json 平台命名空间、whisper 模型）
```

registry 条目（平台由键名表达，条目内不重复存 platform/extractor；`finish` 从 meta.json 自动装配）：

```json
{"videos": {"bilibili": {"BV14tTj6CEuM": {
  "title": "...", "folder": "archive/2026-10/bilibili/BV..._...",
  "url": "...", "duration": 218, "language": "zh", "upload_date": "20260703",
  "uploader": "...", "uploader_id": "...", "host": "bilibili.com",
  "collection": {"id": "合集/列表 ID", "title": "合集/播放列表/收藏夹名"},
  "subtitle_lang": "ai-zh", "subtitle_source": "manual",
  "summarized_at": "..."}}}}
```

`collection` = 所属列表（**采集时入口**语义：合集/播放列表/收藏夹入口采集的视频自动带上；同视频从不同列表进入只记首次）。单视频入口为 null 时，声明了 `season_lookup` 能力位的平台（B 站）会**自动反查归属合集回填**（B 站经官方 view API 取 `ugc_season`，入口值优先不被覆盖；反查失败静默缺席不阻塞采集）。要检出同一合集的全部已总结视频：按 `collection.id` 过滤 `registry.videos` 各平台条目。

## Workflow

### Step 0: Install Dependencies（首次）

```bash
bash "$SKILL_DIR/scripts/install_deps.sh"
```

### Step 1: 机械阶段（项目根目录运行）

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" init    # 首次：建 archive/ cache/ + 补齐 .gitignore（幂等）
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL"          # 已总结过会打印 SKIP 并退出
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL" --force  # 强制重采（复用原归档目录，不产生跨月孤儿）
```

机械阶段已完成但认知阶段中断时，直接重跑同一命令即可**续跑**：按归档布局探测既有目录（含跨月），meta.json 归属一致即复用并重建交接 JSON 幂等退出，不重复下载（重采才需要 `--force`）。

`--sub-pref "zh-Hans,en"` 覆盖默认字幕偏好（中文读者默认：`[zh-Hans, zh, zh-Hant, 视频原语言, en]`）；`--quality 480|720|1080` 下载档位，默认 720（总结只需 1280 宽帧+音轨）。

**stdout 末行是交接 JSON**（唯一契约行），字段：

| 字段 | 含义 |
|------|------|
| folder / id / platform / host | 归档目录、视频 ID、平台键（generic 已消歧）、站点 host（展示用） |
| title / url / duration / language / upload_date | 元信息（url 为 canonical webpage_url） |
| uploader / uploader_id / account | 作者名 / 作者 ID / Cookie 登录账号（无则空） |
| collection_id / collection_title | 所属列表（合集/播放列表/收藏夹，采集时入口；单视频入口为空时自动反查归属合集回填，见 `collection` 语义说明；无则空）。同合集检索按 registry `collection.id` 过滤 |
| media_kind | video \| audio（audio-only 源：无视频文件与抽帧） |
| video_file / audio_file | 媒体实际相对路径（**不要假设 video.mp4**；对应文件可能不存在=无视频/无音轨） |
| subtitle_lang / subtitle_source | 选中字幕与来源（manual/auto/whisper/none） |
| needs_whisper | 1 = 无字幕且有音轨，需 whisper 兜底 |
| has_danmaku / has_comments | 弹幕/评论能力位是否产出（audience.json 落盘即 1，可能 0 条） |
| chapters | 官方章节数（0 = 无，时间线自行分段） |

### Step 2: 认知阶段（Agent）

0. **体裁判定**：读元数据+字幕首尾，按 summary-prompt「体裁判定」表定主体裁（教程/讲座/测评/访谈/资讯/观点/娱乐，可叠加次体裁块）——它决定逐段详解的章内结构与 TL;DR 收获清单的弹性。**观看目的**（可选）：用户在对话中给出目的（如"我看完想照着搭一个店"）则填入 `{{PURPOSE}}`（三要素：我是谁+场景+拿总结去做什么），未给出则留空、骨架自足。
1. **读帧**：逐张 Read `evidence/frames/*.jpg`，记录画面事实（界面路径、数据、演示效果——口播没讲的信息），并标记值得嵌入 summary 的帧（记下文件名）。
2. **按需补帧**（无上限）：弹幕峰值时刻（audience.json `danmaku.peaks[].t`）、字幕说"看这个界面"但机械帧未覆盖、信息密集段无视觉佐证时：
   ```bash
   bash "$SKILL_DIR/scripts/extract_frames.sh" "<video_file>" "<folder>/evidence/frames" --at "65,130.5,208"
   ```
   注意 `video_file`/`audio_file` 已是**项目根相对全路径**（folder 已含其中），直接使用、不要再拼 `<folder>/` 前缀。
3. **whisper 兜底**（`needs_whisper: 1` 时；HF 限速改用 `--model-path` 指向本地模型目录，如 ModelScope 下载的 `cache/whisper-models/faster-whisper-small`）：
   ```bash
   uv run "$SKILL_DIR/scripts/parallel_transcribe.py" --input "<audio_file>" \
     --output-dir "<folder>/raw" --model small --language auto
   ```
   输出直落 `raw/subtitle.srt`。
4. **生成 summary.md**：按 `$SKILL_DIR/reference/summary-prompt.md` 填充占位符（FRAMES=读帧观察，每条附帧文件名；AUDIENCE=audience.json 消化版；无评论无弹幕时观众反馈项留空；PURPOSE=用户观看目的或空；`{{PLATFORM}}` 对 generic 平台填 host 可读名而非哈希键）。骨架为固定四章节 **TL;DR → 脉络总览 → 逐段详解 → 延伸**（认知渐进：先目的与收获、再结构、再细节、最后附录），观众信号融入对应位置而非独立章节；脉络总览对知识型/流程型内容**按需绘制 mermaid 结构图**（思维导图/流程图/展示图谱，纪律见提示词严格规则 15）。遵守证据法则：正文零证据痕迹；含实质信息的帧按提示词「严格规则 12 · 关键帧插图」以相对链接嵌入对应位置。
5. **生成 evidence/evidence.md**：按 `$SKILL_DIR/reference/evidence-template.md` 承接全部溯源细节（所有占位符的取值来源：meta.json / audience.json / chapters.json；赞助段与噪音的剜除记录留痕于底稿第 5 节，summary 正文零痕迹）。底稿写在 `evidence/evidence.md`——与它取证的原始侧账同目录。

### Step 3: 回写 registry

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" finish --folder "<folder>" \
  [--subtitle-lang "<lang>"] [--subtitle-source "<manual|auto|whisper>"]
```

finish 从 `<folder>/raw/meta.json` 自动装配全部字段（杜绝手抄漂移），校验 `summary.md` 已存在后带文件锁回写；whisper 兜底场景必须传 `--subtitle-source whisper`，终态会同步回写 raw/meta.json（meta.json 是字幕来源的唯一事实源）。

### Step 4: 交付验收（强制闸门）

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" verify --folder "<folder>"   # 单归档
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" verify                        # 全仓扫描
```

verify 程序化检查交付完整性：summary.md/evidence/evidence.md/raw/meta.json 齐全、registry 已登记该目录、summary 帧插图引用的帧文件真实存在、行文/mermaid 无非法时间戳、无 `.stale` 残留。**输出 FAIL（exit 1）即未达交付标准**，逐条修复后重跑至 PASS。历史教训：曾发生"写完 summary 直接交付、漏跑 finish"导致 registry 缺条目、查重失效——verify 即为此类流程遗漏的程序化兜底。

## Platform Capabilities（platforms.json 声明）

| 能力 | bilibili（已配置） | 未配置平台（默认通用链路） |
|------|----------|----------|
| 字幕 | CC + ai-\*（需登录 Cookie） | 通用 subtitles / automatic_captions |
| 章节 | 通用（含 end_time） | 通用（含 end_time） |
| 评论 | v2/reply API（热评 top30+楼中楼） | yt-dlp `--write-comments` + 全平台 max_comments 限流 |
| 弹幕 | XML | 无（audience.json 中 danmaku=null） |
| 合集反查 | 官方 view API `ugc_season`（单视频入口为空时回填 `collection`） | 无（collection 仅入口语义） |
| Cookie | Chrome 自动导出+校验；失败按 on_failure=degrade 匿名降级 | 免 Cookie；手动放 `cache/_<平台键>.cookies.txt`（generic 平台也可 `cache/_<host>.cookies.txt`，Netscape 格式）即生效 |

Cookie 消费顺序（ensure_cookies.py）：既有文件（含手动放置）校验优先 → cookies.json 命名空间 → 浏览器导出（写临时文件、校验通过才落位，**绝不覆盖用户文件**）。新平台增强 = platforms.json 加数据项（复用现有实现）；新实现类型（verify_type / 弹幕 / 评论 API）= 改对应组件，见 platforms.json `_meta.note` 的实现枚举清单。

## Batch Mode（合集/收藏夹/稍后再看/任意播放列表）

1. **先确保 Cookie**（B 站批量列表需要登录态；`--url` 传任一真实视频页，站点首页会被 yt-dlp 视为 Unsupported URL）：
   ```bash
   python3 "$SKILL_DIR/scripts/ensure_cookies.py" ensure --platform bilibili --url "https://www.bilibili.com/video/<任意BV号>"
   ```
2. 枚举列表（任意 yt-dlp 支持的播放列表 URL 均可；打印完整 URL 以免还需拼接；个别提取器 flat 模式下 `%(url)s` 为 NA 时回退用 `%(id)s` 自行拼 URL）：
   ```bash
   yt-dlp --cookies cache/_bilibili.cookies.txt --flat-playlist --print "%(url)s" \
     'https://space.bilibili.com/<mid>/favlist?fid=<fid>'   # 或 collectiondetail?sid= / watchlater / YouTube playlist
   ```
3. 逐个执行 Step 1–4（SKIP 机制对全平台生效，天然跳过已总结视频；中断可续跑——机械阶段产物在、认知阶段未完成时重跑即恢复；registry 累积进度；每个视频收尾必须 finish + verify）。批量入口（合集/收藏夹/播放列表 URL）采集的视频会带上 `collection` 字段，跑完后按 registry `collection.id` 过滤即得本列表的全部已总结视频（同合集检索；入口语义=采集时首次进入的列表）。
4. 批量降采样：每视频读帧 ≤6 张（插图数天然受此约束）、评论消化 ≤15 条，防止上下文爆炸。
5. **不要逐视频向用户提问**（含超长视频）：默认完整处理，事后汇总告知。

## Git Conventions

- `init` 托管 `.gitignore`（幂等补齐），全部规则 scoped 在 `archive/`、`cache/` 下，无全局通配，不影响宿主项目其他文件；**追踪/忽略的单一事实源是该托管块**
- 追踪白名单：registry.json、summary.md、evidence/evidence.md、raw/meta.json、raw/subtitle.srt、evidence/audience.json；其余忽略（媒体/帧/原始侧账可 `--force` 重采）
- summary.md 可用相对链接引用 `evidence/frames/*.jpg`（帧插图）；帧图片**不入 Git**，断链可定位——回溯链：alt 文本 `m:ss` → 文件名 `HH-MM-SS` 时间戳 → meta.json `url` 原片位置；新机器也可用 ffmpeg 按时间戳单帧重采
- `cache/` 是登录凭证与模型缓存，**绝不入 Git**；evidence/evidence.md 的文本溯源不依赖二进制存在

## Error Handling

- **SKIP**：视频已总结 → 直接引用归档位置；用户要求重跑才加 `--force`（重采落回原归档目录，旧 summary/evidence 底稿改名 `.stale` 防陈旧蒙混）。registry 记录的目录被手动删除 → 告警后按未总结重采，finish 时条目自愈
- **续跑**：机械阶段完成、认知阶段中断 → 重跑同命令自动从 meta.json 恢复，不重复下载
- **无字幕且 whisper 无有效语音**：按 summary-prompt 的「无有效口播时拒绝编造」规则输出失败原因，不编内容
- **无音轨视频**：机械阶段自动降级（audio_file 为空、needs_whisper=0），靠字幕+帧总结；audio-only 源反向同理（无 video_file、无抽帧）
- **Cookie 失败**（无 Chrome/未登录）：按 platforms.json `on_failure` 处理——bilibili 配置为 degrade（告警后匿名继续，字幕/评论/弹幕能力位自然缺席）；手动放置 `cache/_<平台键>.cookies.txt`（或 generic 的 `_<host>` 命名）后重试即被自动校验采用。B 站无登录态通常无字幕可下，此时走 whisper 兜底，不要假装能降级拿 CC
- **HuggingFace 限速**：从 ModelScope 下载模型放 `cache/whisper-models/`，whisper 命令改带 `--model-path cache/whisper-models/faster-whisper-small`
- **视频过长（>1 小时）**：默认完整处理（whisper 自动分片），单视频模式可先告知用户耗时；批量模式一律直接处理
- **B 站风控（HTTP 412/352）**：稍后重试或补充 buvid Cookie
- **目录冲突**：归档目录已存在、registry 未登记、meta.json 归属不一致 → 报错拒跑（meta 一致则自动续跑），人工检查后处理
- **registry 损坏**：读侧（lookup/prepare 查重）告警并视为无记录；写侧（finish）自动备份 `registry.json.corrupt-<时间戳>` 后重建，不静默丢历史

## Notes

1. 产出固定在项目根 `archive/YYYY-MM/`（年月=处理时间，`--force` 重采落回原目录）；registry 在 `archive/registry.json`；上传日期/作者 ID/host/所属列表同时记入 meta.json 与 registry，可按发布时间、作者、站点、合集检索。
2. 仅限个人学习用途；遵守平台条款。
3. 首次 whisper 运行需下载模型（small ≈244MB）；长音频自动静音分片、多核并行转写。
4. 回归测试：`bash scripts/tests/run_unit_tests.sh`（离线单测）与 `bash scripts/tests/run_e2e_local.sh`（本地 generic E2E，需 ffmpeg）；改任何脚本后先跑单测。
