#!/usr/bin/env bash
# pipeline_prepare.sh —— 机械阶段编排（video-summarizer · 全平台能力模型）
#
# 平台能力位（Cookie 自动导出/弹幕/评论方式）由 scripts/platforms.json 声明，
# 脚本按表驱动；能力位取值是实现枚举（见 platforms.json _meta.note）。
# Cookie 只以工作区 cache/cookies.json 为源；ensure 负责校验、更新和生成运行副本。
#
# 机械阶段产出: archive/YYYY-MM/<platform>/<ID_消毒标题>/
#   raw/{meta.json(追踪), subtitle.srt(追踪), video.*, audio.*}
#   evidence/{audience.json(追踪), danmaku.xml, comments.info.json,
#             chapters.json, frames/*.jpg}(后四类忽略)
# stdout 末行 = 交接 JSON（认知阶段契约，字段见 SKILL.md）
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
META="$SKILL_DIR/scripts/pipeline_meta.py"
BUILD_TERMS="$SKILL_DIR/scripts/build_context_terms.py"
COOKIES="$SKILL_DIR/scripts/ensure_cookies.py"
AUDIENCE="$SKILL_DIR/scripts/audience.py"
FRAMES="$SKILL_DIR/scripts/extract_frames.sh"
ARCHIVE="$SKILL_DIR/scripts/pipeline_archive.py"
REGISTRY="archive/registry.json"
project_root="$PWD"
cookie_retry_done=0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { cat >&2 <<'EOF'
用法（在项目根目录运行）:
  pipeline_prepare.sh init
  pipeline_prepare.sh [quick] <URL> [--force] [--resume] [--sub-pref LANGS] [--quality 480|720|1080]
    quick=文本简报；缺省=标准总结。均归档、刷新动态信息并复用有效稳定素材。
    --force 仅表示用户已确认覆盖相同模式总结，不删除媒体/字幕或另一种总结。
    --resume 恢复尚未完成的同模式任务；未完成任务阻止并发覆盖同一分P。
  pipeline_prepare.sh finish --folder F --mode quick|deep --run-id ID [--part N]
    --agent-model MODEL --harness HARNESS [--subtitle-lang LANG] [--subtitle-source SOURCE]
    校验交接指定的临时 summary_output/evidence_output 后发布，更新两种模式记录。
  pipeline_prepare.sh verify [--folder F] [--mode quick|deep] [--part N]
  pipeline_prepare.sh abort --folder F --run-id ID [--part N]
  pipeline_prepare.sh lookup <URL> [--mode quick|deep]
    lookup 只读；裸多P URL 硬停 exit 2，确认范围后用 ?p=N 逐P处理。

EOF
  exit 1; }
jget() { python3 -c 'import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if v is None else v)' "$1" "$2"; }

# find_project_root: 从「当前 cwd 向上」找含 .git/config 的最近祖先目录
# 失败再 fallback 从 SKILL_DIR 向上找(如调用方 cwd 在用户 home 等无 git 区域时)
# 用途: finish/verify 对 folder 的相对路径兜底——Agent 在任意 cwd 调用时,
# 若 cwd 不是项目根 且 folder 相对项目根存在但相对 cwd 不存在,自动 cd 过去.
# 不动 prepare/quick/lookup:那些分支的 cwd 归一是语义决定(workspace 初始化),
# 退让反而遮盖真正错误.
find_project_root() {
  local d="$PWD"
  while [[ "$d" != "/" ]]; do
    [[ -e "$d/.git" ]] && { printf '%s\n' "$d"; return 0; }
    d=$(dirname "$d")
  done
  d="$SKILL_DIR"
  while [[ "$d" != "/" ]]; do
    [[ -e "$d/.git" ]] && { printf '%s\n' "$d"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}

# normalize_cwd_for_folder: folder 指向的归档必须能以「项目根相对」解析到
# 现状: finish/verify 直接用 $folder 拼 meta/summary/registry 路径,
# 当调用方 cwd != 项目根时会报"meta.json 不存在"假阴性——
# 本函数:有以下三种情况则 cd 到项目根
#   1) cwd 不是项目根 且 folder 相对项目根存在 且 folder 相对 cwd 不存在
# 负面的情况(两个位置都不存在,或只相对 cwd 存在)留给原逻辑报错.
normalize_cwd_for_folder() {
  local folder="${1%/}"
  [[ -z "$folder" ]] && return 0
  local root
  root=$(find_project_root) || return 0   # 找不到项目根(未知环境)不动
  [[ "$PWD" == "$root" ]] && return 0     # 已在项目根
  if [[ -d "$root/$folder/raw" && ! -d "$PWD/$folder/raw" ]]; then
    echo "(cwd 归一化: 切到项目根 $root; folder 以项目根相对解析)" >&2
    cd "$root" || return 1
  fi
  return 0
}

cmd=${1:-}; [[ -n "$cmd" ]] || usage

# ---------- init: 项目初始化（幂等） ----------
if [[ "$cmd" == "init" ]]; then
  mkdir -p archive cache
  python3 - "$PWD/.gitignore" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
START = "# >>> video-summarizer（托管块: init 整块重写；勿手工混入条目）"
END = "# <<< video-summarizer"
# 白名单: 归档内只追踪认知产物与登记簿，新增机械产物默认忽略（fail-closed）
block = [
    START,
    "# 白名单: 归档内只追踪认知产物与登记簿，新增机械产物默认忽略（fail-closed）",
    "archive/**",
    "!archive/**/",
    "!archive/registry.json",
    "!archive/**/raw/meta*.json",
    "!archive/**/raw/subtitle*.srt",
    "!archive/**/summary*.md",
    "!archive/**/brief*.md",
    "!archive/**/evidence/evidence*.md",
    "!archive/**/evidence/audience*.json",
    "# 项目根取材缓存（cookie 会话，绝不入 Git）",
    "cache/",
    END,
]
# 黑名单时代的托管条目与关联注释（迁移时一并清除；用户本地规则保留）
LEGACY = {
    "# video-summarizer（由 pipeline_prepare.sh init 托管；缺失条目自动补回）",
    "cache/", "archive/**/raw/video.*", "archive/**/raw/audio.*",
    "archive/**/evidence/frames/", "archive/**/evidence/danmaku.xml",
    "archive/**/evidence/comments.info.json", "archive/**/evidence/chapters.json",
    "archive/**/*.stale", "archive/**/raw/video_*", "archive/**/raw/audio_*",
    "archive/**/evidence/danmaku_*.xml", "archive/**/evidence/comments_*.info.json",
    "archive/**/evidence/chapters_*.json", "archive/**/raw/asr_run*/",
    "archive/**/raw/context_terms*.txt", "archive/**/raw/.asr_*",
    "archive/**/raw/subtitle_download*.err.log",
    "# asr 转写产物（模式化规则同时覆盖单P无后缀与多P _NN 后缀；磁盘保留供",
    "# verify 溯源/--resume，不入 Git——asr_run 内含 source.wav 大文件）",
    "# 字幕下载失败日志（原始 stderr 留档，磁盘保留供排查，不入 Git）",
}
text = p.read_text() if p.exists() else ""
lines = text.splitlines()
if START in lines:  # 已是托管块: 整块替换，块外用户规则原样保留
    out, inside = [], False
    for l in lines:
        if l == START:
            inside = True; out.extend(block); continue
        if l == END:
            inside = False; continue
        if not inside:
            out.append(l)
    new_text = "\n".join(out).rstrip("\n") + "\n"
else:  # 旧黑名单格式（或无文件）: 清除旧托管条目后前置新托管块
    kept = [l for l in lines if l.strip() not in LEGACY]
    while kept and not kept[0].strip():
        kept.pop(0)
    new_text = "\n".join(block) + ("\n\n" + "\n".join(kept) + "\n" if kept else "\n")
if new_text != text:
    p.write_text(new_text)
    print(".gitignore: 已切换为白名单托管块")
else:
    print(".gitignore: 已就位（白名单托管块）")
PY
  echo "init 完成: archive/ cache/ .gitignore"
  exit 0
fi

# Finish/verify share mode-aware archive metadata and validated publication.
if [[ "$cmd" == finish || "$cmd" == verify || "$cmd" == abort ]]; then
  folder_arg=""
  previous_arg=""
  for argument in "$@"; do
    if [[ "$previous_arg" == --folder ]]; then folder_arg=$argument; fi
    previous_arg=$argument
  done
  [[ -z "$folder_arg" ]] || normalize_cwd_for_folder "$folder_arg"
  if [[ "$cmd" == verify && -z "$folder_arg" && ! -d archive ]]; then
    root=$(find_project_root || true)
    if [[ -n "$root" && -d "$root/archive" ]]; then cd "$root"; fi
  fi
  modern=0
  for argument in "$@"; do [[ "$argument" != --mode ]] || modern=1; done
  if [[ "$cmd" == abort ]]; then modern=1; fi
  if [[ $modern -eq 0 ]]; then
    modern=$(python3 - "$folder_arg" <<'PYMODERN'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]) if sys.argv[1] else Path('archive')
print(int(any('"schema_version": 2' in p.read_text() for p in root.rglob('meta*.json'))))
PYMODERN
)
  fi
  if [[ $modern -eq 1 ]]; then exec python3 "$ARCHIVE" "$@"; fi
  if [[ "${VS_ARCHIVE_LOCKED:-}" != 1 ]]; then exec python3 "$ARCHIVE" legacy "$0" "$@"; fi
fi
# ---------- finish: 回写 registry（字段从 meta 自动装配，带文件锁） ----------
if [[ "$cmd" == "finish" ]]; then
  shift
  folder="" slang="" ssrc="" part="" agent_model="" harness=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "finish: 参数 $1 缺少取值"
    case $1 in
      --folder) folder=$2 ;;
      --subtitle-lang) slang=$2 ;;
      --subtitle-source) ssrc=$2 ;;
      --part) part=$2 ;;
      --agent-model) agent_model=$2 ;;
      --harness) harness=$2 ;;
      *) die "finish: 未知参数 $1（接口: finish --folder F [--part N] [--subtitle-lang L] [--subtitle-source S] --agent-model M --harness H）" ;;
    esac
    shift 2
  done
  [[ -n "$folder" ]] || die "finish 需要 --folder <归档目录>"
  [[ -n "$agent_model" ]] || die "finish: 需要 --agent-model <model>（Step 2 第 0 步定稿值，将与 summary 顶行一并强校验）"
  [[ -n "$harness" ]] || die "finish: 需要 --harness <harness>（Step 2 第 0 步定稿值，将与 summary 顶行一并强校验）"
  case "$ssrc" in ""|manual|auto|asr|whisper|none) ;; *) die "finish: --subtitle-source 仅支持 manual|auto|asr|whisper|none（实得: ${ssrc}）" ;; esac
  folder=${folder%/}
  # cwd 归一化: folder 以项目根相对解析——Agent 在归档目录下跑 finish 时
  # 以前在 assert $folder/raw/meta.json 处报假阴性,现在自动 cd 到项目根
  normalize_cwd_for_folder "$folder" || die "finish: cwd 归一化失败（无法切到项目根）"
  # meta 定位: 多P课程目录用 --part 定位 raw/meta_NN.json，单P用 raw/meta.json
  meta_rel="raw/meta.json"
  if [[ -n "$part" ]]; then
    [[ "$part" =~ ^[0-9]+$ ]] || die "finish: --part 须为正整数（实得: ${part}）"
    meta_rel="raw/meta_$(printf '%02d' "$part").json"
  elif [[ ! -f "$folder/$meta_rel" ]] && ls "$folder"/raw/meta_*.json >/dev/null 2>&1; then
    die "finish: $folder 是多P课程目录，请用 --part N 指定分P"
  fi
  [[ -f "$folder/$meta_rel" ]] || die "finish 拒绝回写: $folder/$meta_rel 不存在（机械阶段未运行）"
  # summary 门槛按 meta 形态推导（多P: summary_NN.md；单P: summary.md）
  sum_rel=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(("summary_%02d.md" % m["part"]) if m.get("is_multipage") and m.get("part") else "summary.md")' "$folder/$meta_rel")
  [[ -f "$folder/$sum_rel" ]] || die "finish 拒绝回写: $folder/$sum_rel 不存在（先完成认知阶段产出）"

  # 单点写入 meta：字幕终态（可选）+ agent_model/harness（必填，来自 step2 第 0 步定稿）
  python3 - "$folder/$meta_rel" "$slang" "$ssrc" "$agent_model" "$harness" <<'PY'
import json, sys
from pathlib import Path
p, slang, ssrc, agent_model, harness = sys.argv[1:6]
m = json.loads(Path(p).read_text())
if slang:
    m["subtitle"]["selected"] = slang
if ssrc:
    m["subtitle"]["source"] = ssrc
m["agent_model"] = agent_model
m["harness"] = harness
Path(p).write_text(json.dumps(m, ensure_ascii=False, indent=2) + "\n")
PY

  mkdir -p archive
  python3 - "$REGISTRY" "$folder" "$folder/$meta_rel" <<'PY'
import fcntl, json, os, shutil, sys
from datetime import datetime, timezone
from pathlib import Path
reg_path, folder, meta_path = sys.argv[1:4]
folder = folder.rstrip("/")  # 容忍调用方带尾斜杠，registry 内路径保持规范
m = json.loads(Path(meta_path).read_text())
part = m.get("part")
is_mp = bool(m.get("is_multipage")) and part
entry = {
    "title": m.get("title"),
    "folder": folder,
    "url": m.get("url"),
    "duration": m.get("duration"),
    "language": m.get("language"),
    "upload_date": m.get("upload_date"),
    "uploader": m.get("uploader"),
    "uploader_id": m.get("uploader_id"),
    "host": m.get("host") or None,
    # 所属列表（合集/播放列表/收藏夹/多P父BV）：采集时入口；单视频入口缺席时
    # 由 season_lookup 能力位反查回填，多P由 multipage_lookup 父BV回退。
    # 按 collection.id 过滤 registry.videos 即可检出同列表/同课程的已总结视频
    "collection": m.get("collection"),
    "part": part,
    "summary_file": (f"summary_{part:02d}.md" if is_mp else "summary.md"),
    "subtitle_lang": m["subtitle"]["selected"],
    "subtitle_source": m["subtitle"]["source"],
    "agent_model": m.get("agent_model"),
    "harness": m.get("harness"),
    "summarized_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
}
reg_path = Path(reg_path)
reg_path.parent.mkdir(parents=True, exist_ok=True)
with open(reg_path, "a+", encoding="utf-8") as f:
    fcntl.flock(f, fcntl.LOCK_EX)  # 并发 finish 不丢更新（读-改-写整文件加锁）
    f.seek(0)
    try:
        reg = json.loads(f.read() or "{}")
    except json.JSONDecodeError:
        backup = f"{reg_path}.corrupt-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(reg_path, backup)
        print(f"警告: registry.json 损坏，已备份到 {backup} 后重建", file=sys.stderr)
        reg = {}
    reg.setdefault("videos", {}).setdefault(m["platform"], {})[m["id"]] = entry
    f.seek(0)
    f.truncate()
    f.write(json.dumps(reg, ensure_ascii=False, indent=2) + "\n")
    f.flush()
    os.fsync(f.fileno())  # 刷盘后再解锁：否则解锁到 close 之间另一进程可读到旧内容
    fcntl.flock(f, fcntl.LOCK_UN)
print(f"registry 已更新: {m['platform']}/{m['id']} → {folder}")
PY
  exit 0
fi

# ---------- verify: 交付完整性验收（认知阶段收尾闸门） ----------
if [[ "$cmd" == "verify" ]]; then
  shift
  vfolder=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "verify: 参数 $1 缺少取值"
    case $1 in
      --folder) vfolder=$2 ;;
      *) die "verify: 未知参数 $1（接口: verify [--folder F]）" ;;
    esac
    shift 2
  done
  # cwd 归一化: 与 finish 同规则——Agent 在归档目录下跑 finish 后立即可
  # 再 verify --folder; 缺省 --folder 时也试将 cwd 切到项目根,否则 scan archive/*/*/*
  # 会以非项目根 cwd 的相对路径 silent fail 直至 PASS 空转
  vfolder=${vfolder%/}
  if [[ -n "$vfolder" ]]; then
    normalize_cwd_for_folder "$vfolder" || true
  else
    # 缺省 --folder:如果没 scan 到任何 archive 项目,切到项目根再试一次
    _root=$(find_project_root) || _root=""
    if [[ -n "$_root" && "$PWD" != "$_root" && -d "$_root/archive" ]]; then
      if ! compgen -G "$PWD/archive/*/*/*" >/dev/null && compgen -G "$_root/archive/*/*/*" >/dev/null; then
        echo "(cwd 归一化: 切到项目根 $_root; verify 扫本仓 archive/)" >&2
        cd "$_root" || true
      fi
    fi
  fi
  python3 - "$REGISTRY" "$vfolder" <<'PY'
import json, re, sys
from pathlib import Path

reg_path, vfolder = sys.argv[1], (sys.argv[2] or "").rstrip("/")
problems = []
info_lines = []

def p(folder, msg):
    problems.append(f"{folder}: {msg}")

# 1. registry 可解析（finish 是否跑过的权威判据）
reg = None
try:
    reg = json.loads(Path(reg_path).read_text()) if Path(reg_path).exists() else None
except json.JSONDecodeError:
    problems.append(f"registry.json 损坏（无法解析）——先修复再验收")

if vfolder:
    folders = [vfolder]
    if not Path(vfolder).is_dir():
        print(f"FAIL\n{vfolder}: 归档目录不存在"); sys.exit(1)
else:
    folders = sorted(str(d) for d in Path("archive").glob("*/*/*") if d.is_dir())

ts = re.compile(r"\d{1,2}:\d{2}(?::\d{2})?")
for folder in folders:
    f = Path(folder)
    # 双形态: 单P目录 = raw/meta.json；多P课程目录 = raw/meta_NN.json 若干
    # （无后缀 = 单视频/课程级；有后缀 = 逐P产物，1-based 对齐 pN）
    raw = f / "raw"
    metas = []
    is_course = False
    if (raw / "meta.json").is_file():
        metas.append((raw / "meta.json", "summary.md", "evidence.md"))
    for mp in sorted(raw.glob("meta_[0-9]*.json")) if raw.is_dir() else []:
        m_ = None
        try:
            m_ = json.loads(mp.read_text())
        except json.JSONDecodeError:
            p(folder, f"{mp.relative_to(f)} 损坏")
        if m_ and m_.get("part"):
            metas.append((mp, f"summary_{m_['part']:02d}.md", f"evidence_{m_['part']:02d}.md"))
            is_course = is_course or bool(m_.get("is_multipage"))
    if not metas:
        p(folder, "raw/meta.json 缺失（机械阶段未完成或被移动）")

    course_total = None
    done_parts = 0
    for meta_path, sum_name, ev_name in metas:
        # 2. 认知/机械产物齐全（多P部分完成合法——只验已采集的P）
        if not (f / sum_name).is_file():
            p(folder, f"{sum_name} 缺失（认知阶段未完成）")
        else:
            done_parts += 1
        if not (f / "evidence" / ev_name).is_file():
            p(folder, f"evidence/{ev_name} 缺失（底稿未写）")
        # 3. registry 登记（缺 = 漏跑 finish）
        if reg is None:
            # 文件缺失/损坏都会走到这（损坏已单独报告）；缺失=整个流程漏了 finish
            p(folder, "registry 不存在（finish 从未执行——查重保护完全失效）")
        else:
            m = None
            try:
                m = json.loads(meta_path.read_text())
            except json.JSONDecodeError:
                p(folder, f"{meta_path.relative_to(f)} 损坏")
            if m:
                entry = (reg.get("videos", {}).get(m.get("platform"), {})
                         .get(m.get("id")))
                if not entry:
                    p(folder, f"registry 未登记 {m.get('platform')}/{m.get('id')}（漏跑 finish）")
                else:
                    if entry.get("folder") != folder:
                        p(folder, f"registry 登记目录不一致（registry: {entry.get('folder')}）")
                    if not (isinstance(entry.get("agent_model"), str) and entry["agent_model"].strip()):
                        p(folder, f"registry 条目缺 agent_model（漏带 finish --agent-model 或历史归档未回补）")
                    if not (isinstance(entry.get("harness"), str) and entry["harness"].strip()):
                        p(folder, f"registry 条目缺 harness（漏带 finish --harness 或历史归档未回补）")
        # 3b. meta agent_model/harness 存在性（finish 必填参数回写处；老归档没这两个字段 → FAIL）
        m_meta = None
        try:
            m_meta = json.loads(meta_path.read_text())
        except Exception:
            pass  # 损坏已在第 3 步报过
        if m_meta:
            am = m_meta.get("agent_model")
            hn = m_meta.get("harness")
            if not (isinstance(am, str) and am.strip()):
                p(folder, f"{meta_path.relative_to(f)} 缺 agent_model 字段（finish 未带 --agent-model 或字段被删）")
            if not (isinstance(hn, str) and hn.strip()):
                p(folder, f"{meta_path.relative_to(f)} 缺 harness 字段（finish 未带 --harness 或字段被删）")
        # 3c. summary 顶行 model/harness 与 meta 一致性 —— 顶行形态固定：
        #     "> {PLATFORM} · {UPLOADER} · 时长 {DURATION} · [原片]({URL}) · 总结于 YYYY-MM-DD · {AGENT_MODEL} · {HARNESS}"
        sum_top_re = re.compile(r"^> .+ · 总结于 (\d{4})-(\d{2})-(\d{2}) · ([^·]+?) · ([^·]+?)\s*$")
        sm_path = f / sum_name
        if m_meta and sm_path.is_file():
            top_line = None
            for line in sm_path.read_text().splitlines():
                if line.lstrip().startswith(">"):
                    top_line = line.rstrip()
                    break
            if top_line is None:
                p(folder, f"{sum_name} 缺元数据行（首行应以 > 开头的引言行）")
            else:
                mm = sum_top_re.match(top_line)
                if not mm:
                    p(folder,
                      f"{sum_name} 顶行不符合 '… · 总结于 YYYY-MM-DD · {{AGENT_MODEL}} · {{HARNESS}}' 形态"
                      f"（实得: {top_line[:80]}…）")
                else:
                    sm_model = mm.group(4).strip()
                    sm_harness = mm.group(5).strip()
                    meta_model = (m_meta.get("agent_model") or "").strip() if isinstance(m_meta.get("agent_model"), str) else ""
                    meta_harness = (m_meta.get("harness") or "").strip() if isinstance(m_meta.get("harness"), str) else ""
                    if meta_model and sm_model != meta_model:
                        p(folder,
                          f"{sum_name} 顶行 AGENT_MODEL '{sm_model}' 与 meta.agent_model '{meta_model}' 不一致")
                    if meta_harness and sm_harness != meta_harness:
                        p(folder,
                          f"{sum_name} 顶行 HARNESS '{sm_harness}' 与 meta.harness '{meta_harness}' 不一致")
        # 4/5/6. summary 帧插图、行文时间戳、mermaid 纪律（逐 summary 文件检查）
        sm = f / sum_name
        if sm.is_file():
            text = sm.read_text()
            for alt, rel in re.findall(r"!\[(.*?)\]\((.*?)\)", text):
                if not (f / rel).is_file():
                    p(folder, f"帧插图断链: {rel}（alt: {alt[:30]}…）")
            for i, line in enumerate(text.splitlines(), 1):
                if not ts.search(line):
                    continue
                s = line.lstrip()
                if s.startswith("### [") or s.startswith("![") or s.startswith(">"):
                    continue
                if "http" in line or "192.168" in line:  # URL 端口误报豁免
                    continue
                p(folder, f"{sum_name}:{i} 行文时间戳（仅允许标题范围/帧图 alt）: {s[:40]}…")
            for m_ in re.finditer(r"```mermaid\n(.*?)```", text, re.S):
                if ts.search(m_.group(1)):
                    p(folder, f"{sum_name} mermaid 节点含时间戳（规则 15 禁止）")
        # 课程完成度信息（course_page_count 由 finalize 从 multipage 探测写入）
        try:
            m = json.loads(meta_path.read_text())
        except Exception:
            m = {}
        if m.get("course_page_count"):
            course_total = max(course_total or 0, m["course_page_count"])
        # 字幕候选与选中矛盾（机械阶段下载静默失败的历史指纹）:
        # 候选里存在能命中字幕偏好的语言、却被记为 selected=none → 警告并提示处置
        sub = m.get("subtitle") or {}
        cands = list((sub.get("candidates") or {}).get("manual") or []) + \
                list((sub.get("candidates") or {}).get("auto") or [])
        if (sub.get("selected") or "none") == "none" and cands:
            prefs = ["zh-Hans", "zh", "zh-Hant", "en"]
            if m.get("language"):
                prefs = prefs[:3] + [m["language"]] + prefs[3:]

            def _pref_hit(c, pf):
                return c == pf or c.startswith(pf + "-") or c == "ai-" + pf or c.startswith("ai-" + pf + "-")

            if any(_pref_hit(c, pf) for c in cands for pf in prefs):
                info_lines.append(
                    f"警告: {folder}: 字幕候选 {cands} 可命中偏好但 selected=none"
                    f"——字幕下载曾失败降级；检查 Cookie 后重跑 prepare 重采字幕")
    # 7. .stale 残留（--force 重采后认知阶段未收尾; 后缀变体一并覆盖）
    for st in list(f.glob("*.stale")) + list((f / "evidence").glob("*.stale")):
        p(folder, f".stale 残留: {st.relative_to(f)}（重采后未完成新认知产物）")
    if course_total and is_course:
        info_lines.append(f"信息: {folder}: 课程 {done_parts}/{course_total} P 已总结"
                          f"（部分完成合法）")

if problems:
    print("FAIL")
    for x in problems:
        print(f"  ✗ {x}")
    sys.exit(1)
for line in info_lines:
    print(line)
scope = vfolder or "全仓 archive/"
print(f"PASS: {scope} 交付完整性验收通过")
PY
  exit 0
fi


# Serialize material writes across processes; the lock lives in ignored cache/.
if [[ "${VS_PREP_LOCKED:-}" != 1 && "$cmd" != lookup ]]; then
  exec python3 "$ARCHIVE" run "$0" "$@"
fi
# ---------- 公共: Cookie 装配 + 元数据探测 ----------
# 所有配置平台使用同一工作区 JSON；下载器只消费临时副本。
setup_cookie_for_url() {
  cookie_file="" account="" cookie_configured=0
  cookie_args=()
  local plat ensure_out msg
  plat=$(python3 "$META" cookie-platform "$url" 2>/dev/null || true)
  [[ -n "$plat" ]] || return 0
  cookie_configured=1
  if ! ensure_out=$(python3 "$COOKIES" ensure --platform "$plat" --url "$url" \
       --project-root "$project_root" --snapshot "$tmpdir/_cookies.working.txt"); then
    msg=$(python3 -c 'import json,sys
try:
    print(json.loads(sys.argv[1]).get("error", "Cookie 准备失败"))
except Exception:
    print("Cookie 管理器返回异常")' "$ensure_out")
    die "Cookie 准备失败: $msg"
  fi
  account=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("account") or "")' "$ensure_out")
  cookie_file="$tmpdir/_cookies.working.txt"
  [[ -s "$cookie_file" ]] || die "Cookie 运行副本生成失败"
  cookie_args=(--cookies "$cookie_file")
  return 0
}

# 一项最多重试一次；先校验共用缓存，再重探字幕。保留已回填的课程与合集元数据。
retry_subtitle_probe() {
  [[ "$cookie_retry_done" == "0" ]] || return 1
  cookie_retry_done=1
  setup_cookie_for_url
  yt-dlp --ignore-config -J --skip-download --no-playlist --write-subs --write-auto-subs \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$tmpdir/retry.%(ext)s" "$url" \
    > "$tmpdir/subtitle_retry.info.json" 2> "$tmpdir/subtitle_retry.err" \
    || die "字幕重新探测失败，请检查网络后重试"
  python3 "$META" distill "$tmpdir/subtitle_retry.info.json" --out "$tmpdir/subtitle_retry.json" --sub-pref "$sub_pref"
  python3 - "$tmpdir/distilled.json" "$tmpdir/subtitle_retry.json" <<'PYSUB'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); original = json.loads(p.read_text()); fresh = json.loads(Path(sys.argv[2]).read_text())
for key in ("subtitle", "subs_manual", "subs_auto"):
    original[key] = fresh.get(key)
p.write_text(json.dumps(original, ensure_ascii=False))
PYSUB
  sel_lang=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["lang"])' "$tmpdir/distilled.json")
  sel_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["source"])' "$tmpdir/distilled.json")
  return 0
}

# 返回真实 SRT 是否生成；失败原因日志保留在素材目录。
download_selected_subtitle() {
  local base=$1 log=$2 kind flag f
  [[ "$sel_lang" != "none" ]] || return 1
  kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["kind"] or "")' "$tmpdir/distilled.json")
  flag=--write-subs
  [[ "$kind" == "auto" ]] && flag=--write-auto-subs
  yt-dlp --ignore-config --no-playlist --skip-download "$flag" --sub-lang "$sel_lang" --convert-subs srt \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$base" "$url" >"$log" 2>&1 || true
  f=$(ls "$base".*.srt 2>/dev/null | head -1 || true)
  [[ -n "$f" ]] && mv -f "$f" "$base.srt"
  [[ -s "$base.srt" ]]
}

# 单次 -J 全量元数据 + 蒸馏 + 读回全局变量。
# --write-subs/--write-auto-subs 触发 yt-dlp 字幕懒加载探测（否则 -J 的
# subtitles/automatic_captions 可能为空）；-o 指向 tmpdir，即使未来 yt-dlp
# 版本在 simulate 语义下写侧文件也不会污染项目目录。
# 设置全局: platform/id/title/dur/language/uploader/uploader_id/upload_date/
#           host/media_kind/canonical_url/extractor_key/safe_dir/sel_lang/sel_source
probe_and_distill() {
  local info_out=$1
  yt-dlp --ignore-config -J --skip-download --no-playlist --write-subs --write-auto-subs \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$tmpdir/probe.%(ext)s" \
    "$url" > "$info_out" 2> "$tmpdir/ytdlp.err" \
    || die "获取元信息失败: $(tail -3 "$tmpdir/ytdlp.err" | tr '\n' ' ')"
  python3 "$META" distill "$info_out" --out "$tmpdir/distilled.json" --sub-pref "$sub_pref"
  [[ "$(jget "$tmpdir/distilled.json" is_playlist)" == "True" ]] \
    && die "输入是播放列表/合集/收藏夹，请用批量模式枚举后逐个处理（见 SKILL.md Batch Mode）"
  platform=$(jget "$tmpdir/distilled.json" platform)
  id=$(jget "$tmpdir/distilled.json" id)
  title=$(jget "$tmpdir/distilled.json" title)
  dur=$(jget "$tmpdir/distilled.json" duration)
  language=$(jget "$tmpdir/distilled.json" language)
  uploader=$(jget "$tmpdir/distilled.json" uploader)
  uploader_id=$(jget "$tmpdir/distilled.json" uploader_id)
  upload_date=$(jget "$tmpdir/distilled.json" upload_date)
  host=$(jget "$tmpdir/distilled.json" host)
  media_kind=$(jget "$tmpdir/distilled.json" media_kind)
  canonical_url=$(jget "$tmpdir/distilled.json" url)
  extractor_key=$(jget "$tmpdir/distilled.json" extractor)
  safe_dir=$(jget "$tmpdir/distilled.json" safe_dir)
  sel_lang=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["lang"])' "$tmpdir/distilled.json")
  sel_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["source"])' "$tmpdir/distilled.json")
}

# registry 命中查询（读侧统一策略: 损坏只告警不写盘，写侧由 finish 备份重建）
registry_folder_of() { # $1=platform $2=id → stdout folder 或空
  python3 - "$REGISTRY" "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
try:
    reg = json.loads(Path(sys.argv[1]).read_text())
except json.JSONDecodeError:
    print("警告: registry.json 损坏，查重保护失效（finish 时会自动备份并重建）", file=sys.stderr)
    sys.exit(0)
except OSError:
    sys.exit(0)
e = reg.get("videos", {}).get(sys.argv[2], {}).get(sys.argv[3])
if e:
    print(e.get("folder") or "")
PY
}

# 多P探测 + collection 三级回填（season_lookup 能力位）。$1=multipage.json 落盘路径。
# 子命令对非 bilibili_ugc 平台/非 BV id 静默缺席（is_multipage=false，不发请求）。
# 裸多P URL 的硬停判定在 multipage_gate（probe 之后必须紧跟调用本函数）。
multipage_lookup_step() { # $1=out.json
  python3 "$META" multipage_lookup "$platform" "$id" \
    --distilled "$tmpdir/distilled.json" --webpage-url "$canonical_url" \
    > "$1" 2>/dev/null || true
}

# 裸多P URL 硬停（exit 2 与一般错误 exit 1 区分——需要用户决策而非程序故障）：
# 不带 ?p= 的多P视频默认只解析到第1P，静默处理会让用户误以为总结了整门课。
# 是否全部/指定P由调用方向用户确认后，用 ?p=N 形式 URL 逐P驱动。
multipage_gate() { # $1=multipage.json
  [[ "$(jget "$1" is_multipage)" == "True" ]] || return 0
  [[ "$(jget "$1" explicit_p)" == "True" ]] && return 0
  {
    echo "ERROR: 多P视频（共 $(jget "$1" page_count)P）——裸 URL 默认只处理第1P，已按策略硬停"
    echo "decision_required=multipage page_count=$(jget "$1" page_count)"
    python3 -c '
import json, sys
for pg in json.load(open(sys.argv[1])).get("pages") or []:
    print("  p%02d %s (%ss)" % (pg["p"], pg["title"], pg["duration"]))' "$1"
    echo "请确认处理范围（全部/指定P），随后用 ?p=N 形式 URL 逐P处理"
  } >&2
  exit 2
}

if [[ "$cmd" == lookup ]]; then
  url=${2:-}; [[ -n "$url" ]] || usage
  mode=${4:-deep}; sub_pref=""
  tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
  cookie_args=()
  probe_and_distill "$tmpdir/info.json"
  multipage_lookup_step "$tmpdir/multipage.json"
  multipage_gate "$tmpdir/multipage.json"
  python3 - "$platform" "$id" "$mode" <<'PYLOOK'
import json,sys
from pathlib import Path
platform,vid,mode=sys.argv[1:]
r=json.loads(Path('archive/registry.json').read_text()) if Path('archive/registry.json').exists() else {}
e=r.get('videos',{}).get(platform,{}).get(vid,{})
a=(e.get('summaries') or {}).get(mode) or (e if mode=='deep' and not e.get('summaries') else {})
f=e.get('folder',''); name=a.get('file') or a.get('summary_file') or 'summary.md'
print('HIT '+f if f and a and (Path(f)/name).is_file() else 'MISS '+platform+'/'+vid)
PYLOOK
  exit 0
fi
# Both modes share the same archive and stable material paths.
mode=deep
if [[ "$cmd" == "quick" ]]; then mode=quick; shift; fi
url=${1:-}; [[ -n "$url" ]] || usage; shift
force=0 resume=0 sub_pref="" quality=720
while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1; shift ;;
    --resume) resume=1; shift ;;
    --sub-pref|--quality) [[ $# -ge 2 ]] || die "参数缺少取值: $1"; key=$1; value=$2; shift 2
      if [[ "$key" == "--sub-pref" ]]; then sub_pref=$value; else quality=$value; fi ;;
    *) die "未知参数 $1" ;;
  esac
done
case "$quality" in 480|720|1080) ;; *) die "--quality 仅支持 480|720|1080" ;; esac
bash "$0" init >&2
tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
setup_cookie_for_url
probe_and_distill "$tmpdir/info.json"
multipage_lookup_step "$tmpdir/multipage.json"
multipage_gate "$tmpdir/multipage.json"
plan_args=(plan --distilled "$tmpdir/distilled.json" --multipage "$tmpdir/multipage.json" --mode "$mode")
[[ $force -eq 0 ]] || plan_args+=(--force)
[[ $resume -eq 0 ]] || plan_args+=(--resume)
python3 "$ARCHIVE" "${plan_args[@]}" > "$tmpdir/plan.json"
# --resume returns the exact existing handoff without refreshing material during generation.
if [[ -n "$(jget "$tmpdir/plan.json" summary_output)" ]]; then cat "$tmpdir/plan.json"; exit 0; fi
pkg=$(jget "$tmpdir/plan.json" folder)
sfx=$(jget "$tmpdir/plan.json" suffix)
part=$(jget "$tmpdir/plan.json" part)
frames_sub=$(jget "$tmpdir/plan.json" frames_sub)
mkdir -p "$pkg/raw" "$pkg/evidence"
# A nonempty existing stable file is never replaced. SRT additionally needs a valid cue.
find_stable() {
  python3 - "$pkg/raw" "$1" <<'PY'
import sys
from pathlib import Path
for p in sorted(Path(sys.argv[1]).glob(sys.argv[2]+'.*')):
    if p.is_file() and p.stat().st_size and p.suffix not in ('.part', '.ytdl', '.log', '.json'):
        print(p); break
PY
}
video_file=$(find_stable "video${sfx}"); audio_file=$(find_stable "audio${sfx}")
video_new=0 audio_new=0 sub_new=0 terms_new=0
if [[ "$mode" == deep && "$media_kind" != audio && -z "$video_file" ]]; then
  yt-dlp --ignore-config --no-playlist ${cookie_args[@]+"${cookie_args[@]}"} \
    -f "bestvideo[height<=${quality}]+bestaudio/best[height<=${quality}]/best" --merge-output-format mp4 \
    -o "$tmpdir/video.%(ext)s" "$url" > /dev/null 2> "$tmpdir/media.err" || die "视频下载失败"
  vf=$(ls "$tmpdir"/video.* 2>/dev/null | head -1 || true); [[ -s "$vf" ]] || die "视频下载结果为空"
  video_file="$pkg/raw/video${sfx}.${vf##*.}"; mv "$vf" "$video_file"; video_new=1
fi
subtitle_path="$pkg/raw/subtitle${sfx}.srt"
valid_sub=$(python3 - "$subtitle_path" <<'PY'
import re,sys
from pathlib import Path
p=Path(sys.argv[1]); print(int(p.is_file() and bool(re.search(r'\d{2}:\d{2}:\d{2}[,.]\d+\s*-->',p.read_text(errors='replace')))))
PY
)
sel_error=""
if [[ "$valid_sub" == 1 ]]; then
  sel_lang=$(python3 - "$tmpdir/plan.json" <<'PY'
import json,sys
print((json.load(open(sys.argv[1]))['previous'].get('subtitle') or {}).get('selected') or 'und')
PY
)
  sel_source=$(python3 - "$tmpdir/plan.json" <<'PY'
import json,sys
print((json.load(open(sys.argv[1]))['previous'].get('subtitle') or {}).get('source') or 'manual')
PY
)
else
  if [[ "$sel_lang" == none ]]; then retry_subtitle_probe; fi
  if [[ "$sel_lang" != none ]]; then
    if ! download_selected_subtitle "$tmpdir/subtitle" "$tmpdir/subtitle_download.err.log"; then
      if [[ "$cookie_retry_done" == 0 ]]; then
        retry_subtitle_probe
        download_selected_subtitle "$tmpdir/subtitle" "$tmpdir/subtitle_download.err.log" || sel_error="字幕获取失败（已重试）"
      else sel_error="字幕获取失败（已重试）"; fi
    fi
    if [[ -s "$tmpdir/subtitle.srt" ]]; then mv "$tmpdir/subtitle.srt" "$subtitle_path"; sub_new=1; valid_sub=1; fi
  fi
  if [[ "$valid_sub" != 1 ]]; then sel_lang=none; sel_source=none; fi
fi
needs_whisper=0 context_terms_file=""
if [[ -z "$audio_file" && ( "$mode" == deep || "$valid_sub" != 1 ) ]]; then
  if [[ -n "$video_file" && "$mode" == deep ]]; then
    ffmpeg -y -loglevel error -i "$video_file" -vn -c:a libmp3lame -q:a 4 "$tmpdir/audio.mp3" 2> "$tmpdir/audio.err" || true
  else
    yt-dlp --ignore-config --no-playlist -f 'bestaudio/best' ${cookie_args[@]+"${cookie_args[@]}"} \
      -o "$tmpdir/audio.%(ext)s" "$url" > /dev/null 2> "$tmpdir/audio.err" || true
  fi
  af=$(ls "$tmpdir"/audio.mp3 "$tmpdir"/audio.m4a "$tmpdir"/audio.webm "$tmpdir"/audio.mp4 "$tmpdir"/audio.opus "$tmpdir"/audio.ogg 2>/dev/null | head -1 || true)
  if [[ -s "$af" ]]; then audio_file="$pkg/raw/audio${sfx}.${af##*.}"; mv "$af" "$audio_file"; audio_new=1; fi
fi
if [[ "$valid_sub" != 1 && -n "$audio_file" ]]; then
  needs_whisper=1
  context_terms_file="$pkg/raw/context_terms${sfx}.txt"
  if [[ ! -s "$context_terms_file" ]]; then
    if python3 "$BUILD_TERMS" "$tmpdir/distilled.json" --out "$tmpdir/context_terms.txt" 2>/dev/null; then
      mv "$tmpdir/context_terms.txt" "$context_terms_file"; terms_new=1
    else context_terms_file=""; fi
  fi
fi
if [[ "$mode" == quick && "$valid_sub" != 1 && -z "$audio_file" ]]; then
  die "快速模式: 无有效字幕或音频，不能仅凭简介与评论总结"
fi
# Dynamic sidecars are fetched into a temporary directory, then copied only on success.
mkdir "$tmpdir/dynamic"
python3 - "$tmpdir/distilled.json" "$pkg/evidence/chapters${sfx}.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[2]).write_text(json.dumps(json.load(open(sys.argv[1])).get('chapters') or [],ensure_ascii=False,indent=2)+'\n')
PY
has_danmaku=0 has_comments=0
if [[ "$(python3 "$META" capability "$platform" danmaku)" == bilibili_xml ]]; then
  yt-dlp --ignore-config --no-playlist --skip-download --write-subs --sub-lang danmaku \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$tmpdir/dynamic/danmaku${sfx}" "$url" > /dev/null 2>&1 || true
  if [[ -s "$tmpdir/dynamic/danmaku${sfx}.danmaku.xml" ]]; then
    mv "$tmpdir/dynamic/danmaku${sfx}.danmaku.xml" "$tmpdir/dynamic/danmaku${sfx}.xml"
    cp "$tmpdir/dynamic/danmaku${sfx}.xml" "$pkg/evidence/danmaku${sfx}.xml"; has_danmaku=1
  fi
fi
comments_cap=$(python3 "$META" capability "$platform" comments)
if [[ "$comments_cap" == bilibili_api ]]; then
  aargs=(); dxml=""
  [[ $has_danmaku -eq 0 ]] || dxml="$tmpdir/dynamic/danmaku${sfx}.xml"
  if [[ -n "$part" ]]; then
    course_id=$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("course") or {}).get("id") or "")' "$tmpdir/multipage.json")
    aargs+=(--part "$part" --base-bvid "$course_id" --course-title "$title")
  fi
  # Empty staging directory guarantees a fresh course comment request on every execution.
  python3 "$AUDIENCE" bili --project-root "$project_root" --url "$canonical_url" --danmaku-xml "$dxml" \
    --out-dir "$tmpdir/dynamic" --duration "$dur" ${aargs[@]+"${aargs[@]}"} > "$tmpdir/audience.result" 2> "$tmpdir/audience.err" || true
else
  ea=(--extractor-args "$(printf '%s' "$extractor_key" | tr '[:upper:]' '[:lower:]'):max_comments=60,15,5,10")
  yt-dlp --ignore-config --no-playlist --skip-download --write-comments --write-info-json "${ea[@]}" \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$tmpdir/dynamic/comments${sfx}" "$url" >/dev/null 2>&1 || true
  if [[ -s "$tmpdir/dynamic/comments${sfx}.info.json" ]]; then
    python3 "$AUDIENCE" generic --info-json "$tmpdir/dynamic/comments${sfx}.info.json" \
      --out-dir "$tmpdir/dynamic" --duration "$dur" --uploader "$uploader" --uploader-id "$uploader_id" > /dev/null 2>&1 || true
  fi
fi
if [[ -s "$tmpdir/dynamic/audience.json" ]]; then has_comments=1; fi
for fresh in "$tmpdir/dynamic"/*; do
  [[ -f "$fresh" ]] || continue
  cp "$fresh" "$pkg/evidence/$(basename "$fresh")"
done
frames_max=0 frames_extracted=0 frame_status=not_requested
if [[ "$mode" == deep && -n "$video_file" ]]; then
  frames_max=$(( dur > 1500 ? 20 : (dur < 600 ? 8 : dur / 75) ))
  # Existing frame names referenced by the current standard summary remain reachable on failure.
  mkdir -p "$pkg/evidence/frames${frames_sub}"
  if bash "$FRAMES" "$video_file" "$tmpdir/frames" --max "$frames_max" \
       --chapters "$pkg/evidence/chapters${sfx}.json" > "$tmpdir/frames.log"; then
    for frame in "$tmpdir/frames"/*.jpg; do
      [[ ! -f "$frame" ]] || cp "$frame" "$pkg/evidence/frames${frames_sub}/$(basename "$frame")"
    done
    frame_status=ok
  else frame_status=failed; fi
  frames_extracted=$(find "$pkg/evidence/frames${frames_sub}" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')
fi
python3 - "$tmpdir/runtime.json" "$video_file" "$audio_file" "$sel_lang" "$sel_source" "$needs_whisper" \
  "$has_comments" "$has_danmaku" "$frames_max" "$frames_extracted" "$mode" "$video_new" "$audio_new" "$sub_new" \
  "$context_terms_file" "$sel_error" "$frame_status" "$account" "$tmpdir/multipage.json" "$pkg" "$sfx" <<'PY'
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent) if '__file__' in globals() else '.')
(out,video,audio,lang,source,nw,hc,hd,fmax,fcount,mode,vnew,anew,snew,terms,error,fs,account,mp,folder,suffix)=sys.argv[1:]
t=json.load(open(mp))
state={'details':{'status':'ok','refreshed':True},'chapters':{'status':'ok','refreshed':True},
       'comments':{'status':'ok' if int(hc) else 'failed','refreshed':bool(int(hc))},
       'danmaku':{'status':'ok' if int(hd) else 'unavailable','refreshed':bool(int(hd))},
       'subtitle':{'status':'ok' if lang!='none' else 'missing','refreshed':bool(int(snew))}}
if video:state['video']={'status':'ok','refreshed':bool(int(vnew))}
if audio:state['audio']={'status':'ok','refreshed':bool(int(anew))}
if mode=='deep':state['frames']={'status':fs,'refreshed':fs=='ok'}
value={'files':{'video':video,'audio':audio},'subtitle':{'selected':lang,'source':source},
       'needs_whisper':bool(int(nw)),'capabilities':{'comments':bool(int(hc)),'danmaku':bool(int(hd))},
       'frames':{'max':int(fmax),'extracted':int(fcount)},'material_state':state,
       'context_terms':terms,'subtitle_error':error,'account':account,'course_page_count':t.get('page_count')}
Path(out).write_text(json.dumps(value,ensure_ascii=False))
PY
final_args=(prepare-meta --distilled "$tmpdir/distilled.json" --plan "$tmpdir/plan.json" --runtime "$tmpdir/runtime.json")
[[ $force -eq 0 ]] || final_args+=(--force)
python3 "$ARCHIVE" "${final_args[@]}"
