#!/usr/bin/env bash
# pipeline_prepare.sh —— 机械阶段编排（video-summarizer · 全平台能力模型）
#
# 平台能力位（Cookie 自动导出/弹幕/评论方式）由 scripts/platforms.json 声明，
# 脚本按表驱动；能力位取值是实现枚举（见 platforms.json _meta.note）。
# Cookie 消费顺序见 ensure_cookies.py 头注释——手动放置 cache/_<平台键>.cookies.txt
# （generic 平台也可用 cache/_<host>.cookies.txt）即生效。
#
# 机械阶段产出: archive/YYYY-MM/<platform>/<ID_消毒标题>/
#   raw/{meta.json(追踪), subtitle.srt(追踪), video.*, audio.*}
#   evidence/{audience.json(追踪), danmaku.xml, comments.info.json,
#             chapters.json, frames/*.jpg}(后四类忽略)
# stdout 末行 = 交接 JSON（认知阶段契约，字段见 SKILL.md）
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
META="$SKILL_DIR/scripts/pipeline_meta.py"
COOKIES="$SKILL_DIR/scripts/ensure_cookies.py"
AUDIENCE="$SKILL_DIR/scripts/audience.py"
FRAMES="$SKILL_DIR/scripts/extract_frames.sh"
REGISTRY="archive/registry.json"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { cat >&2 <<'EOF'
用法（在项目根目录运行）:
  pipeline_prepare.sh init
      初始化 archive/ cache/ 与项目 .gitignore（幂等，可重复执行）
  pipeline_prepare.sh <URL> [--force] [--sub-pref "zh-Hans,zh,en"] [--quality 480|720|1080]
      采集+归档。已总结视频（registry 按 平台/ID 查重）打印 SKIP 并退出；
      --force 重采并复用首次归档目录（不产生跨月孤儿目录）；
      机械阶段已完成但认知阶段中断时重跑 → 从 meta.json 重建交接 JSON 幂等续跑；
      --sub-pref 覆盖默认字幕语言偏好 [zh-Hans, zh, zh-Hant, 原语言, en]；
      --quality 下载档位，默认 720（总结只需 1280 宽帧 + 音轨）
  pipeline_prepare.sh finish --folder <F> [--subtitle-lang L] [--subtitle-source S]
      认知阶段完成后回写 registry。字段从 <F>/raw/meta.json 自动装配（要求
      summary.md 与 raw/meta.json 均存在）；whisper 兜底后用 --subtitle-source whisper
      覆盖，终态同步回写 raw/meta.json（meta.json 是字幕来源的唯一事实源）
  pipeline_prepare.sh verify [--folder <F>]
      交付完整性验收（认知阶段收尾必跑，防漏步骤静默出仓）:
      指定 <F> 只验该归档；缺省全仓扫描 archive/ 下所有归档目录。
      检查项: summary.md/evidence/evidence.md/raw/meta.json 存在、registry.json
      可解析且登记了该目录、summary 帧插图引用的帧文件真实存在、
      无 .stale 残留、无非法时间戳（行文/mermaid 节点）。
      全部通过打印 PASS 并 exit 0；有问题逐条列出、末行 FAIL exit 1
  pipeline_prepare.sh lookup <URL>
      只读查询（不触发 Cookie ensure、零写入，快速模式用）:
      已总结打印 HIT <folder>，否则 MISS <平台/ID>
  pipeline_prepare.sh quick <URL> [--tmp <DIR>]
      快速模式取材（项目内零写入）：字幕选优与深度模式同规则；已归档则返回
      registry 命中；无字幕自动 -f bestaudio 备好音频。全部产物（含 cookie
      派生物）落在 --tmp 目录（缺省 mktemp），stdout 末行输出取材 JSON
EOF
  exit 1; }
jget() { python3 -c 'import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if v is None else v)' "$1" "$2"; }

cmd=${1:-}; [[ -n "$cmd" ]] || usage

# ---------- init: 项目初始化（幂等） ----------
if [[ "$cmd" == "init" ]]; then
  mkdir -p archive cache
  python3 - "$PWD/.gitignore" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
entries = [
    "# video-summarizer（由 pipeline_prepare.sh init 托管；缺失条目自动补回）",
    "cache/",
    "archive/**/raw/video.*",
    "archive/**/raw/audio.*",
    "archive/**/evidence/frames/",
    "archive/**/evidence/danmaku.xml",
    "archive/**/evidence/comments.info.json",
    "archive/**/evidence/chapters.json",
    "archive/**/*.stale",
]
text = p.read_text() if p.exists() else ""
have = {l.strip() for l in text.splitlines()}
missing = [e for e in entries if e not in have]
if missing:
    sep = "" if (not text or text.endswith("\n")) else "\n"
    p.write_text(text + sep + "\n".join(missing) + "\n")
    print(f".gitignore: 补齐 {len(missing)} 条")
else:
    print(".gitignore: 已就位")
PY
  echo "init 完成: archive/ cache/ .gitignore"
  exit 0
fi

# ---------- finish: 回写 registry（字段从 meta.json 自动装配，带文件锁） ----------
if [[ "$cmd" == "finish" ]]; then
  shift
  folder="" slang="" ssrc=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "finish: 参数 $1 缺少取值"
    case $1 in
      --folder) folder=$2 ;;
      --subtitle-lang) slang=$2 ;;
      --subtitle-source) ssrc=$2 ;;
      *) die "finish: 未知参数 $1（接口: finish --folder F [--subtitle-lang L] [--subtitle-source S]）" ;;
    esac
    shift 2
  done
  [[ -n "$folder" ]] || die "finish 需要 --folder <归档目录>"
  case "$ssrc" in ""|manual|auto|whisper|none) ;; *) die "finish: --subtitle-source 仅支持 manual|auto|whisper|none（实得: $ssrc）" ;; esac
  [[ -f "$folder/summary.md" ]] || die "finish 拒绝回写: $folder/summary.md 不存在（先完成认知阶段产出）"
  [[ -f "$folder/raw/meta.json" ]] || die "finish 拒绝回写: $folder/raw/meta.json 不存在（机械阶段未运行）"

  # 字幕终态覆盖（whisper 兜底后），同步回写 raw/meta.json 保持 meta/registry 一致
  if [[ -n "$slang" || -n "$ssrc" ]]; then
    python3 - "$folder/raw/meta.json" "$slang" "$ssrc" <<'PY'
import json, sys
from pathlib import Path
p, slang, ssrc = sys.argv[1:4]
m = json.loads(Path(p).read_text())
if slang:
    m["subtitle"]["selected"] = slang
if ssrc:
    m["subtitle"]["source"] = ssrc
Path(p).write_text(json.dumps(m, ensure_ascii=False, indent=2) + "\n")
PY
  fi

  mkdir -p archive
  python3 - "$REGISTRY" "$folder" "$folder/raw/meta.json" <<'PY'
import fcntl, json, os, shutil, sys
from datetime import datetime, timezone
from pathlib import Path
reg_path, folder, meta_path = sys.argv[1:4]
folder = folder.rstrip("/")  # 容忍调用方带尾斜杠，registry 内路径保持规范
m = json.loads(Path(meta_path).read_text())
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
    # 所属列表（合集/播放列表/收藏夹）：采集时入口；单视频入口缺席时由
    # season_lookup 能力位反查归属合集回填。按 collection.id 过滤
    # registry.videos 即可检出同列表的已总结视频
    "collection": m.get("collection"),
    "subtitle_lang": m["subtitle"]["selected"],
    "subtitle_source": m["subtitle"]["source"],
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
  python3 - "$REGISTRY" "$vfolder" <<'PY'
import json, re, sys
from pathlib import Path

reg_path, vfolder = sys.argv[1], (sys.argv[2] or "").rstrip("/")
problems = []

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
    # 2. 认知/机械产物齐全
    for rel, what in [("summary.md", "summary.md 缺失（认知阶段未完成）"),
                      ("evidence/evidence.md", "evidence/evidence.md 缺失（底稿未写）"),
                      ("raw/meta.json", "raw/meta.json 缺失（机械阶段未完成或被移动）")]:
        if not (f / rel).is_file():
            p(folder, what)
    # 3. registry 登记（缺 = 漏跑 finish）
    if reg is None:
        # 文件缺失/损坏都会走到这（损坏已单独报告）；缺失=整个流程漏了 finish
        p(folder, "registry 不存在（finish 从未执行——查重保护完全失效）")
    else:
        m = None
        if (f / "raw/meta.json").is_file():
            try:
                m = json.loads((f / "raw/meta.json").read_text())
            except json.JSONDecodeError:
                p(folder, "raw/meta.json 损坏")
        if m:
            entry = (reg.get("videos", {}).get(m.get("platform"), {})
                     .get(m.get("id")))
            if not entry:
                p(folder, "registry 未登记（漏跑 finish）")
            elif entry.get("folder") != folder:
                p(folder, f"registry 登记目录不一致（registry: {entry.get('folder')}）")
    # 4. summary 帧插图引用真实存在（断链回溯链保障）
    sm = f / "summary.md"
    if sm.is_file():
        text = sm.read_text()
        for alt, rel in re.findall(r"!\[(.*?)\]\((.*?)\)", text):
            if not (f / rel).is_file():
                p(folder, f"帧插图断链: {rel}（alt: {alt[:30]}…）")
        # 5. 行文时间戳纪律: m:ss 只允许出现在小节标题/帧图 alt/元数据行
        for i, line in enumerate(text.splitlines(), 1):
            if not ts.search(line):
                continue
            s = line.lstrip()
            if s.startswith("### [") or s.startswith("![") or s.startswith(">"):
                continue
            if "http" in line or "192.168" in line:  # URL 端口误报豁免
                continue
            p(folder, f"summary.md:{i} 行文时间戳（仅允许标题范围/帧图 alt）: {s[:40]}…")
        # 6. mermaid 节点禁时间戳
        for m_ in re.finditer(r"```mermaid\n(.*?)```", text, re.S):
            if ts.search(m_.group(1)):
                p(folder, "mermaid 节点含时间戳（规则 15 禁止）")
    # 7. .stale 残留（--force 重采后认知阶段未收尾; summary 在目录根、evidence.md 在 evidence/）
    for st in list(f.glob("*.stale")) + list((f / "evidence").glob("*.stale")):
        p(folder, f".stale 残留: {st.relative_to(f)}（重采后未完成新认知产物）")

if problems:
    print("FAIL")
    for x in problems:
        print(f"  ✗ {x}")
    sys.exit(1)
scope = vfolder or "全仓 archive/"
print(f"PASS: {scope} 交付完整性验收通过")
PY
  exit 0
fi

# ---------- 公共: Cookie 装配 + 元数据探测 ----------
# 把 $cookie_file 复制为 $tmpdir 下的工作副本并更新 $cookie_file 指向副本
cookie_copy() {
  [[ -z "$cookie_file" ]] && return 0
  local copy="${tmpdir:-/tmp}/_cookies.working.txt"
  if cp -f "$cookie_file" "$copy" 2>/dev/null; then
    cookie_file=$copy
  fi
  return 0
}
# 设置全局: cookie_file / cookie_args / account / cookie_configured
# $1 可选 cache-dir（缺省 cache=项目内；quick 传 $tmp 保证项目零写入，
#    且此模式下项目 cache/ 里的既有文件只读复用、不触发写盘的 ensure）
setup_cookie_for_url() {
  local cachedir=${1:-cache}
  cookie_file="" account="" cookie_configured=0
  local plat ensure_out onfail msg
  plat=$(python3 "$META" cookie-platform "$url" 2>/dev/null || true)
  if [[ -n "$plat" ]]; then
    cookie_configured=1
    # quick 等零写入场景: 项目 cache 已有该平台 cookie 文件 → 只读复用
    if [[ "$cachedir" != "cache" && -f "cache/_${plat}.cookies.txt" ]]; then
      cookie_file="cache/_${plat}.cookies.txt"
    elif ! ensure_out=$(python3 "$COOKIES" ensure --platform "$plat" --url "$url" \
                        --cache-dir "$cachedir"); then
      msg=$(python3 -c 'import json,sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("error", ""), d.get("hint", ""))
except Exception:
    print(sys.argv[1][-300:] if sys.argv[1] else "未知错误")' "$ensure_out" 2>/dev/null || true)
      onfail=$(python3 "$META" cookie-on-failure "$url" 2>/dev/null || true)
      if [[ "$onfail" == "degrade" ]]; then
        echo "警告: Cookie 准备失败，按 platforms.json on_failure=degrade 匿名继续（字幕/评论/弹幕能力位可能缺席）: $msg" >&2
      else
        die "Cookie 准备失败: $msg"
      fi
    else
      account=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("account") or "")' "$ensure_out")
      [[ -f "$cachedir/_${plat}.cookies.txt" ]] && cookie_file="$cachedir/_${plat}.cookies.txt"
    fi
  fi
  cookie_args=()
  if [[ -n "$cookie_file" && -f "$cookie_file" ]]; then
    # yt-dlp 退出时会回写 --cookies 目标文件：项目内 cookie 文件（含用户手动
    # 放置）一律复制工作副本再消费，原文件永不被改动
    cookie_copy
    cookie_args=(--cookies "$cookie_file")
  fi
  return 0
}

# 单次 -J 全量元数据 + 蒸馏 + 读回全局变量。
# --write-subs/--write-auto-subs 触发 yt-dlp 字幕懒加载探测（否则 -J 的
# subtitles/automatic_captions 可能为空）；-o 指向 tmpdir，即使未来 yt-dlp
# 版本在 simulate 语义下写侧文件也不会污染项目目录。
# 设置全局: platform/id/title/dur/language/uploader/uploader_id/upload_date/
#           host/media_kind/canonical_url/extractor_key/safe_dir/sel_lang/sel_source
probe_and_distill() {
  local info_out=$1
  yt-dlp -J --skip-download --no-playlist --write-subs --write-auto-subs \
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

# ---------- lookup: 只读查重（快速模式/批量前置查询，零写入、不触发 ensure） ----------
if [[ "$cmd" == "lookup" ]]; then
  [[ $# -ge 2 ]] || usage
  url=$2
  sub_pref=""
  tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
  probe_and_distill "$tmpdir/info.json"
  hit=$(registry_folder_of "$platform" "$id")
  if [[ -n "$hit" && -f "$hit/summary.md" ]]; then
    echo "HIT $hit"
  else
    [[ -n "$hit" ]] && echo "警告: registry 条目悬空（$hit 无 summary.md），按未总结处理" >&2
    echo "MISS $platform/$id"
  fi
  exit 0
fi

# ---------- quick: 快速模式取材（项目内零写入） ----------
if [[ "$cmd" == "quick" ]]; then
  [[ $# -ge 2 ]] || usage
  url=$2; shift 2
  outdir=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "quick: 参数 $1 缺少取值"
    case $1 in
      --tmp) outdir=$2; shift 2 ;;
      *) die "quick: 未知参数 $1" ;;
    esac
  done
  [[ -n "$outdir" ]] || outdir=$(mktemp -d /tmp/video-summarizer-quick-XXXX)
  mkdir -p "$outdir"
  tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT   # 探测草稿区（$outdir 保留给调用方）
  sub_pref=""
  setup_cookie_for_url "$outdir"
  probe_and_distill "$tmpdir/info.json"
  hit=$(registry_folder_of "$platform" "$id")
  if [[ -n "$hit" && ! -f "$hit/summary.md" ]]; then
    echo "警告: registry 条目悬空（$hit 无 summary.md），按未总结取材" >&2
    hit=""
  fi
  subtitle_file="" audio_file="" needs_whisper=0
  if [[ -n "$hit" ]]; then
    # 已归档: 免取材（读既有 summary.md 即可），零下载
    sel_lang=archived; sel_source=archived
  elif [[ "$sel_lang" != "none" ]]; then
    sub_flag=--write-subs
    sel_kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["kind"] or "")' "$tmpdir/distilled.json")
    [[ "$sel_kind" == "auto" ]] && sub_flag=--write-auto-subs
    yt-dlp --no-playlist --skip-download $sub_flag --sub-lang "$sel_lang" --convert-subs srt \
      ${cookie_args[@]+"${cookie_args[@]}"} -o "$outdir/subtitle" "$url" >/dev/null 2>&1 || true
    sub_file=$(ls "$outdir"/subtitle.*.srt 2>/dev/null | head -1 || true)
    if [[ -n "$sub_file" && "$sub_file" != "$outdir/subtitle.srt" ]]; then
      mv -f "$sub_file" "$outdir/subtitle.srt"
    fi
    [[ -f "$outdir/subtitle.srt" ]] && subtitle_file="$outdir/subtitle.srt"
  fi
  if [[ -z "$subtitle_file" && -z "$hit" ]]; then
    sel_lang=none; sel_source=none; needs_whisper=1
    yt-dlp --no-playlist -f "bestaudio/best" ${cookie_args[@]+"${cookie_args[@]}"} \
      -o "$outdir/audio.%(ext)s" "$url" >/dev/null 2>&1 || true
    audio_file=$(ls "$outdir"/audio.* 2>/dev/null | head -1 || true)
    [[ -n "$audio_file" ]] || die "快速模式: 字幕与音频均不可得（网络/Cookie 问题，见 stderr）"
  fi
  python3 - "$outdir" "$hit" "$subtitle_file" "$audio_file" "$needs_whisper" \
    "$sel_lang" "$sel_source" "$id" "$platform" "$host" "$title" "$dur" <<'PY'
import json, sys
(outdir, hit, sub, audio, nw, slang, ssrc,
 vid, plat, host, title, dur) = sys.argv[1:13]
print(json.dumps({
    "mode": "quick", "tmp": outdir,
    "registry_hit": hit or "",
    "id": vid, "platform": plat, "host": host,
    "title": title, "duration": int(float(dur or 0)),
    "subtitle_file": sub, "audio_file": audio,
    "subtitle_lang": slang, "subtitle_source": ssrc,
    "needs_whisper": int(nw),
}, ensure_ascii=False))
PY
  exit 0
fi

# ---------- prepare: 机械阶段 ----------
url=$1; shift
force=0 sub_pref="" quality=720
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 || "$1" == "--force" ]] || die "未知或缺少取值的参数: $1"
  case $1 in
    --force) force=1; shift ;;
    --sub-pref) sub_pref=$2; shift 2 ;;
    --quality) quality=$2; shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done
case "$quality" in 480|720|1080) ;; *) die "--quality 仅支持 480|720|1080" ;; esac

[[ -d .git || -d archive ]] || die "未在项目根目录（无 .git 与 archive/）。首次使用请先运行: pipeline_prepare.sh init"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

setup_cookie_for_url
probe_and_distill "$tmpdir/info.json"

# 手动 Cookie 兜底（仅未配置平台——配置平台已由 ensure 按消费顺序处理）:
# 平台键或 host 命名的文件存在即采用，并带登录态重探一次元数据
if [[ -z "$cookie_file" && "$cookie_configured" != "1" ]]; then
  for cand in "cache/_${platform}.cookies.txt" "cache/_${host}.cookies.txt"; do
    if [[ -f "$cand" ]]; then
      cookie_file=$cand
      echo "使用手动 Cookie: ${cookie_file}（带登录态重新探测元数据）" >&2
      cookie_copy
      cookie_args=(--cookies "$cookie_file")
      probe_and_distill "$tmpdir/info2.json"
      break
    fi
  done
fi

# registry 查重（全平台统一键 平台/ID; --force 重跑且复用首次归档目录）
reg_folder=$(registry_folder_of "$platform" "$id")
if [[ -n "$reg_folder" && $force -eq 0 ]]; then
  if [[ ! -d "$reg_folder" ]]; then
    # 悬空条目（归档目录被手动删除）：告警后按未总结处理，重采落新目录并自愈
    echo "警告: registry 记录的归档目录不存在: $reg_folder —— 按未总结重新采集（registry 条目将在 finish 时自愈）" >&2
  else
    echo "SKIP: $platform/$id 已总结过 -> $reg_folder (重跑请加 --force)"
    exit 0
  fi
fi

# 归档目录解析顺序:
#   1) registry 记录的目录仍存在 → 复用（跨月 --force 重采不产生孤儿）
#   2) 按归档布局探测既有目录（跨月中断续跑: finish 未执行、registry 无指针，
#      但上月目录还在）→ meta.json 归属一致即复用，进入下方续跑分支
#   3) 都没有 → 按当前年月新建
# 目录名经消毒（见 pipeline_meta.py sanitize_component）
pkg=""
if [[ -n "$reg_folder" && "$reg_folder" == archive/* && -d "$reg_folder" ]]; then
  pkg="$reg_folder"
else
  pkg=$(python3 - "$platform" "$id" "$safe_dir" <<'PY'
import json, sys
from pathlib import Path
platform, vid, safe_dir = sys.argv[1:4]
# 目录名字面量比较（safe_dir 可能含 [] 等 glob 特殊字符，不能直接进 glob 模式）
cands = sorted(c for c in Path("archive").glob(f"*/{platform}/*") if c.name == safe_dir)
for c in cands:  # 唯一归属一致的既有目录 → 跨月续跑复用
    try:
        m = json.loads((c / "raw" / "meta.json").read_text())
    except Exception:
        continue
    if m.get("platform") == platform and m.get("id") == vid:
        print(c)
        break
PY
)
  [[ -n "$pkg" ]] && echo "发现既有归档目录（跨月续跑）: $pkg" >&2
  pkg="${pkg:-archive/$(date +%Y-%m)/$platform/$safe_dir}"
fi
if [[ -d "$pkg" ]]; then
  if [[ $force -eq 0 ]]; then
    # 中断续跑: 机械阶段产物完好且归属一致 → 从 raw/meta.json 重建交接 JSON 幂等退出
    if [[ -f "$pkg/raw/meta.json" ]]; then
      match=$(python3 - "$pkg/raw/meta.json" "$platform" "$id" <<'PY' || true
import json, sys
m = json.load(open(sys.argv[1]))
print("yes" if m.get("platform") == sys.argv[2] and m.get("id") == sys.argv[3] else "no")
PY
)
      if [[ "$match" == "yes" ]]; then
        # 注意顺序: 提示行先输出，重建 JSON 最后打印——Python stdout 走管道是
        # 块缓冲（进程退出才刷出），若 echo 在其后，2>&1 合并捕获时契约行会
        # 被提示行挤掉末位
        echo "续跑: 机械阶段产物完好，已从中断处恢复（重采请加 --force）" >&2
        python3 - "$pkg" "$pkg/raw/meta.json" <<'PY'
import json, sys
from pathlib import Path
pkg, meta_path = sys.argv[1:3]
m = json.loads(Path(meta_path).read_text())
cap = m.get("capabilities") or {}
files = m.get("files") or {}
sub = m.get("subtitle") or {}
h = {
    "folder": pkg, "id": m["id"], "platform": m["platform"],
    "host": m.get("host", ""), "media_kind": m.get("media_kind", "video"),
    "title": m.get("title"), "url": m.get("url"),
    "duration": m.get("duration") or 0, "language": m.get("language"),
    "upload_date": m.get("upload_date"), "uploader": m.get("uploader"),
    "uploader_id": m.get("uploader_id"),
    "collection_id": (m.get("collection") or {}).get("id", ""),
    "collection_title": (m.get("collection") or {}).get("title", ""),
    "account": m.get("account") or "",
    "video_file": files.get("video", ""), "audio_file": files.get("audio", ""),
    "subtitle_lang": sub.get("selected", "none"),
    "subtitle_source": sub.get("source", "none"),
    "needs_whisper": int(bool(m.get("needs_whisper"))),
    "has_danmaku": int(bool(cap.get("danmaku"))),
    "has_comments": int(bool(cap.get("comments"))),
    "chapters": m.get("chapters_count", 0),
    "must_run_finish": True,
}
print(json.dumps(h, ensure_ascii=False))
PY
        exit 0
      fi
    fi
    die "目录冲突: $pkg 已存在但 registry 未登记 $platform/$id — 若目录内容与该视频无关请人工检查；否则加 --force 重采"
  fi
  # 旧认知产物改名保留（防 finish 的 summary.md 门槛被上一轮陈旧产物蒙混；
  # .stale 不入 Git 追踪白名单，属可弃残留）。必须在 rm -rf 之前执行——
  # evidence/ 整目录会被清理；底稿改名到目录根（evidence.md.stale），
  # 否则改名产物随目录清理被误删。旧布局遗留的顶层 evidence.md 一并留痕
  # （与 evidence/evidence.md 同目标名，mv -f 后者覆盖）
  for f in summary.md evidence.md evidence/evidence.md; do
    [[ -f "$pkg/$f" ]] && mv -f "$pkg/$f" "$pkg/$(basename "$f").stale"
  done
  # 旧布局兼容：evidence.md 曾位于目录根、meta.json 曾位于目录根
  # （已改名留痕的 .stale 不在清理名单内，存活）
  rm -rf "$pkg/raw" "$pkg/evidence" "$pkg/meta.json"
fi
mkdir -p "$pkg/raw" "$pkg/evidence/frames"

# 合集归属反查（platforms.json season_lookup 能力位）：单视频 URL 采集时
# yt-dlp -J 无 playlist 字段（入口语义缺席），B 站经官方 view API 反查
# ugc_season 回填 distilled 的 collection。子命令内部入口优先、全部缺席路径
# 静默退 0（能力位自然缺席，不阻塞采集）；续跑分支不经过此处，meta.json 为准
python3 "$META" collection_lookup "$platform" "$id" \
  --distilled "$tmpdir/distilled.json" 1>&2 || true

# 媒体下载: audio-only 站点（播客等）直接拉音频，跳过视频与抽帧
video_file="" audio_file=""
if [[ "$media_kind" == "audio" ]]; then
  echo "纯音频源（audio-only）——跳过视频下载与抽帧" >&2
  yt-dlp --no-playlist ${cookie_args[@]+"${cookie_args[@]}"} -f "bestaudio/best" \
    -o "$pkg/raw/audio.%(ext)s" "$url" >/dev/null 2> "$tmpdir/dl.err" \
    || die "音频下载失败: $(tail -3 "$tmpdir/dl.err" | tr '\n' ' ')"
  audio_file=$(ls "$pkg"/raw/audio.* 2>/dev/null | head -1 || true)
  [[ -n "$audio_file" ]] || die "下载完成但未找到音频文件（raw/audio.*）"
else
  yt-dlp --no-playlist ${cookie_args[@]+"${cookie_args[@]}"} \
    -f "bestvideo[height<=${quality}]+bestaudio/best[height<=${quality}]/best" \
    --merge-output-format mp4 -o "$pkg/raw/video.%(ext)s" "$url" \
    >/dev/null 2> "$tmpdir/dl.err" || die "视频下载失败: $(tail -3 "$tmpdir/dl.err" | tr '\n' ' ')"
  video_file=$(ls "$pkg"/raw/video.* 2>/dev/null | head -1 || true)
  [[ -n "$video_file" ]] || die "下载完成但未找到视频文件（raw/video.*）"

  if ! ffmpeg -y -loglevel error -i "$video_file" -vn -c:a libmp3lame -q:a 4 "$pkg/raw/audio.mp3" 2> "$tmpdir/ffaudio.err"; then
    # 无音轨是合法输入（纯字幕卡/无声演示）：降级继续，不用 whisper、靠字幕+帧总结
    if ! ffmpeg -y -loglevel error -i "$video_file" -vn -c:a aac -b:a 128k "$pkg/raw/audio.m4a" 2>> "$tmpdir/ffaudio.err"; then
      echo "警告: 音频抽取失败（视频无音轨，或 ffmpeg 未安装）——跳过音频，whisper 转写不可用" >&2
    fi
  fi
  audio_file=$(ls "$pkg"/raw/audio.* 2>/dev/null | head -1 || true)
fi

# 字幕: 按蒸馏结果下载选中语言（manual/ai 走 write-subs，auto 走 write-auto-subs；
# B 站字幕需登录态，必须带 cookie）
if [[ "$sel_lang" != "none" ]]; then
  sub_flag=--write-subs
  sel_kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["kind"] or "")' "$tmpdir/distilled.json")
  [[ "$sel_kind" == "auto" ]] && sub_flag=--write-auto-subs
  yt-dlp --no-playlist --skip-download $sub_flag --sub-lang "$sel_lang" --convert-subs srt \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$pkg/raw/subtitle" "$url" >/dev/null 2>&1 || true
  sub_file=$(ls "$pkg"/raw/subtitle.*.srt 2>/dev/null | head -1 || true)
  [[ -n "$sub_file" && "$sub_file" != "$pkg/raw/subtitle.srt" ]] && mv -f "$sub_file" "$pkg/raw/subtitle.srt"
fi
needs_whisper=0
if [[ ! -f "$pkg/raw/subtitle.srt" ]]; then
  sel_lang=none; sel_source=none
  if [[ -n "$audio_file" ]]; then
    needs_whisper=1
  else
    echo "警告: 无字幕且无音轨——无法获得口播文本，认知阶段按「无有效口播」规则处理" >&2
  fi
fi

# 章节（全平台通用，取自 -J；含 start_time/end_time/title）
python3 - "$tmpdir/distilled.json" "$pkg/evidence/chapters.json" <<'PY'
import json, sys
chapters = json.load(open(sys.argv[1])).get("chapters") or []
json.dump(chapters, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY

# 弹幕能力位（platforms.json 声明 danmaku=bilibili_xml 的平台）
has_danmaku=0
danmaku_cap=$(python3 "$META" capability "$platform" danmaku 2>/dev/null || true)
if [[ "$danmaku_cap" == "bilibili_xml" ]]; then
  yt-dlp --no-playlist --skip-download --write-subs --sub-lang danmaku \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$pkg/evidence/danmaku" "$url" >/dev/null 2>&1 || true
  [[ -f "$pkg/evidence/danmaku.danmaku.xml" ]] && mv -f "$pkg/evidence/danmaku.danmaku.xml" "$pkg/evidence/danmaku.xml"
  [[ -f "$pkg/evidence/danmaku.xml" ]] && has_danmaku=1
fi

# 评论能力位（platforms.json 声明 comments=bilibili_api 走自研 API，其余走
# yt-dlp --write-comments 原生支持；max_comments 对所有原生评论平台生效，
# extractor-args 命名空间用真实 extractor 键小写）
has_comments=0
comments_cap=$(python3 "$META" capability "$platform" comments 2>/dev/null || true)
if [[ "$comments_cap" == "bilibili_api" ]]; then
  dxml=""
  (( has_danmaku )) && dxml="$pkg/evidence/danmaku.xml"
  # 传 canonical webpage_url（含 BV 号）而非原始 URL——b23.tv 短链不含 BV 号
  if python3 "$AUDIENCE" bili --url "$canonical_url" --danmaku-xml "$dxml" \
       --out-dir "$pkg/evidence" --duration "$dur" 1>&2; then
    has_comments=1
  fi
else
  # yt-dlp 语义: max_comments 多值必须逗号四元组（总数,顶层,回复,每线程回复）
  # 实证（yt-dlp 2026.08.19 options 解析器）: 分号重复键只保留最后一个值 ['10']，
  # 逗号语法才得到 ['60','15','5','10']
  ea=(--extractor-args "$(printf '%s' "$extractor_key" | tr '[:upper:]' '[:lower:]'):max_comments=60,15,5,10")
  yt-dlp --no-playlist --skip-download --write-comments --write-info-json "${ea[@]}" \
    ${cookie_args[@]+"${cookie_args[@]}"} -o "$pkg/evidence/comments" "$url" >/dev/null 2>&1 || true
  if [[ -f "$pkg/evidence/comments.info.json" ]]; then
    uargs=()
    [[ -n "$uploader" ]] && uargs+=(--uploader "$uploader")
    [[ -n "$uploader_id" ]] && uargs+=(--uploader-id "$uploader_id")
    if python3 "$AUDIENCE" generic --info-json "$pkg/evidence/comments.info.json" \
         --out-dir "$pkg/evidence" --duration "$dur" "${uargs[@]+${uargs[@]}}" 1>&2; then
      has_comments=1
    fi
  fi
fi

# 机械抽帧（自适应上限: 时长/75s，夹在 8..20；无视频（audio-only）跳过；
# 失败非致命，认知阶段可无帧工作）
frames_max=0 frames_out="" frames_extracted=0
if [[ -n "$video_file" ]]; then
  frames_max=$(( dur > 1500 ? 20 : (dur < 600 ? 8 : dur / 75) ))
  frames_out=$(bash "$FRAMES" "$video_file" "$pkg/evidence/frames" \
    --max "$frames_max" --chapters "$pkg/evidence/chapters.json") \
    || echo "警告: 机械抽帧失败（继续，认知阶段将无机械帧可用）" >&2
  frames_extracted=$(printf '%s\n' "$frames_out" | sed -n 's/^frames: extracted=\([0-9]*\).*/\1/p')
  frames_extracted=${frames_extracted:-0}
fi

# 认知阶段收尾提醒（stderr 不污染交接 JSON 契约行; 必须在 finalize 之前
# echo——Python stdout 走管道是块缓冲，提醒行放后面会在 2>&1 合并捕获时
# 挤掉末位契约行；跳过 finish 会导致 registry 查重失效与 verify FAIL）:
echo "提醒: 认知阶段产出 summary/evidence 后，必须执行 finish 回写 registry，再执行 verify 验收（本 JSON 的 must_run_finish=true）" >&2
# meta.json + 交接 JSON（stdout 唯一一行）
python3 "$META" finalize "$tmpdir/distilled.json" \
  --folder "$pkg" \
  --video-file "${video_file#./}" --audio-file "${audio_file#./}" \
  --subtitle-lang "$sel_lang" --subtitle-source "$sel_source" \
  --needs-whisper "$needs_whisper" --has-danmaku "$has_danmaku" \
  --has-comments "$has_comments" --frames-max "$frames_max" \
  --frames-extracted "$frames_extracted" \
  --uploader-id "$uploader_id" --upload-date "$upload_date" --account "$account"