---
name: video-summarizer
description: "Summarize, transcribe, or download videos from yt-dlp supported platforms. Both quick text briefs and standard summaries are archived; standard mode also analyzes video frames. Use for video links, 总结视频、快速简报、阅读版、合集/播放列表和多P课程总结. Bilibili supports login subtitles, comments, danmaku, and multi-part courses."
---

# Video Summarizer

`$SKILL_DIR` 是本技能根目录；从用户指定项目根目录执行脚本。机械阶段采集素材，认知阶段生成总结，`finish` 发布并登记，`verify` 验收。

## 模式与覆盖规则

- **快速模式 quick**：完整读取字幕/转写、详情、简介、标签、章节和本次有效的评论/弹幕，生成可独立阅读的简报并归档。不读取图片、关键帧、已有标准总结或其画面观察作为内容来源；不抽帧、不修改已有帧。
- **标准模式 deep**：使用同一套文本素材，增加读帧与按需补帧，按 `reference/summary-prompt.md` 写完整阅读文章。
- 同一视频目录内，`brief.md` 与 `summary.md` 独立存在；多P使用 `brief_NN.md` / `summary_NN.md`。每种模式只保留最新一份，成功后直接覆盖，不建历史副本、快照或按模式复制的素材目录。
- 只有**目标模式**已有产物时需要用户明确确认覆盖，再带 `--force`。另一种模式已有产物不阻止执行。GUI 请求中 `force=true` 已表示本次覆盖确认，不重复询问。未授权时不得自行添加 `--force`。
- `--force` 是覆盖总结的授权，**不强制重新下载稳定素材，也不删除另一种模式的成品**。

## 素材更新范围

| 材料 | 行为 |
|---|---|
| 视频、音频、有效字幕（含本地转写）、转写结果与辅助词表 | 已存在且有效则复用，缺失时补齐；不因详情/标签变化重转写 |
| 视频详情、简介、标签、章节、评论、弹幕、audience | 每次执行重新获取，成功后覆盖；失败保留旧文件并记录失败，不将旧数据冒充本次新取数据 |
| 关键帧 | 仅标准模式可按固定规则与 Agent 本次需要重采、补充、覆盖；快速模式不读不改 |

所有模式共用 `raw/` 和 `evidence/`。动态素材刷新后，另一份总结不自动重写；其输入指纹与生成时间保持不变。输入指纹只能发现来源更新，不能恢复已覆盖的旧素材。相同视频/分P已有未完成任务时不要并发重采：恢复原任务或在用户明确取消后 abort，不能擅自取消别的会话。

## 执行流程

首次缺依赖时运行 `bash "$SKILL_DIR/scripts/install_deps.sh"`。两种模式均初始化：

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" init
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" quick "VIDEO_URL"       # 快速
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" "VIDEO_URL"             # 标准
# 仅当已确认覆盖相同模式时添加 --force
```

支持 `--sub-pref "zh-Hans,en"`、`--quality 480|720|1080`（缺省720）。字幕优先级与两种模式无关：中文简繁 → 原语言 → 英文，人工/CC优先于自动字幕。音频源不下载视频、不抽帧。

裸多P URL 会 exit 2，输出 `decision_required=multipage` 和分P清单。只询问一次范围，确认后逐项使用 `?p=N`；GUI 已给明确所选URL时不再询问，不扩大为其他P或整个合集。链接身份为平台/ID（B站多P为 `BV号_pN`），与合集入口无关。

### 机械阶段交接

stdout **末行 JSON** 是唯一契约，不要猜文件名或自行拼接 folder 前缀：

- `folder / id / platform / host / url / title / duration / uploader`：归档身份和元信息；canonical URL 保留分P。
- `mode / run_id / part / is_multipage / summary_file`：本次模式、任务标识、分P和正式产物名。
- `summary_output / evidence_output`：本次临时成品的绝对路径，**写入这里**，不要提前覆盖正式总结或共享底稿。
- `video_file / audio_file / subtitle_file / context_terms`：实际素材路径；项目根相对路径已含 folder，勿重复拼接。
- `subtitle_lang / subtitle_source / needs_whisper / subtitle_download_failed`：字幕终态与转写需求。
- `has_comments / has_danmaku`：本次成功获取的观众数据；为0时不把目录里旧文件当作本次新材料。多P评论在课程级 `audience.json`，本P弹幕在 `audience_NN.json`。
- `chapters / collection_id / collection_title / must_run_finish`：章节、合集归属及强制收尾提醒。

`raw/meta.json`（多P `meta_NN.json`）保存动态详情、素材采集状态/时间、两份总结各自的模型/Harness/生成时间/输入指纹。快速更新时保留视频、帧及标准总结记录。复用素材不改原获取时间。

### 认知阶段

1. 定稿当前实际 `agent_model` 和宿主 `harness`，全次使用同一份值；不能判断时询问一次，不能填 unknown。GUI 提供 Harness 时采用它，模型取实际会话模型。
2. `needs_whisper=1` 时先检查本次转写授权。已获授权无需再问；未获授权先在当前会话询问。使用唯一入口：
   ```bash
   bash "$SKILL_DIR/scripts/transcribe_fallback.sh" "<audio_file>" "<folder>/raw" \
     [--suffix "_NN"] [--terms "<context_terms>"]
   ```
   asr优先、whisper兜底，以输出 engine 决定 finish 的字幕来源参数。已有有效字幕时不执行转写，不重建辅助材料。
3. 完整读取字幕和有效文本资料。评论只是辅助观点，不冒充视频事实；无字幕且转写无有效内容时停止内容总结，报告原因，不能靠标题/简介/评论编造。
4. **quick** 读取 [reference/quick-prompt.md](reference/quick-prompt.md)，不读帧或标准总结。**deep** 读取 [reference/summary-prompt.md](reference/summary-prompt.md) 与 [reference/writing-style.md](reference/writing-style.md)，判体裁、读帧并按需要补帧：
   ```bash
   bash "$SKILL_DIR/scripts/extract_frames.sh" "<video_file>" "<folder>/evidence/frames[/pNN]" --at "65,130.5,208"
   ```
5. 将本次正文写到 **`summary_output`**。顶行模型署名统一为：
   ```
   > {PLATFORM} · {UPLOADER} · 时长 {DURATION} · [原片]({URL}) · 总结于 {YYYY-MM-DD} · {AGENT_MODEL} · {HARNESS}
   ```
6. 按 [reference/evidence-template.md](reference/evidence-template.md) 将**本模式**证据底稿写到 **`evidence_output`**；quick省略画面观察，deep包含帧观察与补帧动机。不复制另一模式的底稿，不写管理标记。`finish` 把候选底稿合并到同一个正式 `evidence/evidence[_NN].md`，仅替换当前模式区块，保留另一模式区块。

### 发布与验收（两种模式都必须）

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" finish --folder "<folder>" \
  --mode "<quick|deep>" --run-id "<run_id>" [--part N] \
  --agent-model "<model>" --harness "<harness>" \
  [--subtitle-lang "<lang>"] [--subtitle-source "<manual|auto|asr|whisper>"]
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" verify --folder "<folder>" --mode "<quick|deep>" [--part N]
```

finish检查任务归属、候选成品/底稿、元数据顶行和帧引用，再发布正文、按模式合并底稿、回写meta与registry。不保存历史副本。转写后按实际 engine 带 `--subtitle-source asr|whisper`，字幕语言填实际语言或und。不得把旧正式总结作为候选交付。

verify FAIL 必须修复再验收；只验本次所选模式/分P，不因另一模式来源更新就重新生成它。批量逐项finish+verify，一项失败记录原因后继续其他项，最后汇报成功/未完成列表。

机械阶段已准备、认知阶段中断：用**同模式命令加 `--resume`**取得原交接（相同模式已有成品时仍需相同覆盖授权）。取消未完成任务：

```bash
bash "$SKILL_DIR/scripts/pipeline_prepare.sh" abort --folder "<folder>" --run-id "<run_id>" [--part N]
```

abort清除临时成品并标记取消，已有正式总结保留。生成失败时不要删除已有总结；报告未完成步骤，保留可复用素材。不要在没有用户取消指令时 abort 其他会话。

## 归档与兼容

```text
archive/YYYY-MM/<platform>/<ID_标题>/
  brief.md                       快速简报（多P brief_NN.md）
  summary.md                     标准总结（多P summary_NN.md）
  raw/meta.json                  共享元数据（多P meta_NN.json）
  raw/subtitle.srt                共享字幕（多P subtitle_NN.srt）
  raw/video.* / audio.*           稳定媒体，忽略Git
  evidence/evidence.md           两模式当前证据分区，共用一文件（多P evidence_NN.md）
  evidence/audience.json         评论/弹幕结构化底账；多P课程级评论
  evidence/audience_NN.json      多P逐P弹幕
  evidence/chapters*.json / danmaku*.xml / comments*.info.json
  evidence/frames[/pNN]/*.jpg    仅标准模式读写
```

不按模式复制素材，不建历史目录。跨月、标题变化均按meta平台/ID查找原目录。多P共用课程目录，每P分别拥有两种模式记录；只操作用户所选P，共享课程评论本次刷新。`archive/registry.json` 保留平台/ID键，在条目 `summaries.quick/deep` 登记两份产物；旧顶层字段兼容地指向标准总结，只有快速时指向简报。历史无模式记录按标准产物识别，不伪造历史模型或时间。

`init` 幂等维护Git白名单：registry、brief/summary、meta、字幕、evidence底稿、audience；媒体、帧、转写中间物与cache忽略。Cookie凭据绝不入Git。帧插图路径相对正式总结，缺图时按时间戳补采。

## 平台、Cookie 与本地转写

平台能力由 `scripts/platforms.json` 声明，未配置平台走通用yt-dlp字幕/章节/评论；B站使用CC/AI字幕、热评API、XML弹幕和多P/合集反查。缺能力不编造数据。

预检和两种总结模式以工作区 `cache/cookies.json` 为唯一凭据源；校验有效即复用，缺失、损坏或确认失效才从Chrome更新。下载器只使用临时Netscape副本；旧Netscape不导入、不兜底。网络错误明确报错并保留缓存，不能伪装无字幕或触发Chrome重导出。B站412/352应稍后重试或补充buvid。

本地转写始终调用 `transcribe_fallback.sh`：asr CLI在PATH、doctor健康且模型就绪时使用Qwen3-ASR及ForcedAligner；否则自动降faster-whisper。asr部署以私有仓库 `https://github.com/goodpeanuts/asr` README为准，本技能只消费、不复制部署流程。whisper模型遇HF限速可用本地ModelScope模型路径。

批量列表先按平台需要ensure Cookie，再用yt-dlp `--flat-playlist --print '%(url)s'` 枚举，逐项走完整模式流程。已授权范围内不逐视频询问；仅已有目标模式而未授权覆盖时停下确认。批量标准读帧≤6张、消化评论≤15条；单视频>1小时可告知耗时，但仍完整处理。

YouTube timedtext 429应接受冷却或在授权范围内转写，不反复重试、换Cookie或注入curl_cffi/impersonation绕过。CDN偶发403可重取新签名URL；bot墙由yt-dlp内部运行时处理。

## 回归验证

```bash
bash scripts/tests/run_unit_tests.sh
bash scripts/tests/run_e2e_local.sh
```

离线测试覆盖素材复用、动态刷新、模式共存、覆盖授权、失败不破坏旧产物、多P、Cookie与元数据契约。E2E需ffmpeg和yt-dlp，仅访问本地服务。
