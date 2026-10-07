#!/usr/bin/env bash
# pipeline_prepare.sh —— 机械阶段编排（video-summarizer · 全平台能力模型）
#
# 平台能力位（Cookie 自动导出/弹幕/评论方式）由 scripts/platforms.json 声明，
# 脚本按表驱动；能力位取值是实现枚举（见 platforms.json _meta.note）。
# Cookie 消费顺序见 ensure_cookies.py 头注释——手动放置 cache/_<平台键>.cookies.txt
# （generic 平台也可用 cache/_<host>.cookies.txt）即生效。
#
# 机械阶段产出: archive/YYYY-MM/<platform>/<ID_消毒标题>/
#   meta.json(追踪) raw/{subtitle.srt(追踪), video.*, audio.*}
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
      认知阶段完成后回写 registry。字段从 <F>/meta.json 自动装配（要求
      summary.md 与 meta.json 均存在）；whisper 兜底后用 --subtitle-source whisper
      覆盖，终态同步回写 meta.json（meta.json 是字幕来源的唯一事实源）
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
  [[ -f "$folder/summary.md" ]] || die "finish 拒绝回写: $folder/summary.md 不存在（先完成认知阶段产出）"
  [[ -f "$folder/meta.json" ]] || die "finish 拒绝回写: $folder/meta.json 不存在（机械阶段未运行）"

  # 字幕终态覆盖（whisper 兜底后），同步回写 meta.json 保持 meta/registry 一致
  if [[ -n "$slang" || -n "$ssrc" ]]; then
    python3 - "$folder/meta.json" "$slang" "$ssrc" <<'PY'
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
  python3 - "$REGISTRY" "$folder" "$folder/meta.json" <<'PY'
import fcntl, json, shutil, sys
from datetime import datetime, timezone
from pathlib import Path
reg_path, folder, meta_path = sys.argv[1:4]
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
    fcntl.flock(f, fcntl.LOCK_UN)
print(f"registry 已更新: {m['platform']}/{m['id']} → {folder}")
PY
  exit 0
fi

# ---------- 公共: Cookie 装配 + 元数据探测 ----------
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
d = json.loads(sys.argv[1])
print(d.get("error", ""), d.get("hint", ""))' "$ensure_out")
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
  if [[ -n "$hit" ]]; then
    echo "HIT $hit"
  else
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
  subtitle_file="" audio_file="" needs_whisper=0
  if [[ "$sel_lang" != "none" ]]; then
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
  if [[ -z "$subtitle_file" ]]; then
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
      cookie_args=(--cookies "$cookie_file")
      echo "使用手动 Cookie: ${cookie_file}（带登录态重新探测元数据）" >&2
      probe_and_distill "$tmpdir/info2.json"
      break
    fi
  done
fi

# registry 查重（全平台统一键 平台/ID; --force 重跑且复用首次归档目录）
reg_folder=$(registry_folder_of "$platform" "$id")
if [[ -n "$reg_folder" && $force -eq 0 ]]; then
  echo "SKIP: $platform/$id 已总结过 -> $reg_folder (重跑请加 --force)"
  exit 0
fi

# 归档目录: --force 且 registry 记录的目录仍存在 → 复用（跨月重采不产生孤儿目录）；
# 否则按当前年月新建。目录名经消毒（见 pipeline_meta.py sanitize_component）
pkg=""
if [[ -n "$reg_folder" && "$reg_folder" == archive/* && -d "$reg_folder" ]]; then
  pkg="$reg_folder"
else
  pkg="archive/$(date +%Y-%m)/$platform/$safe_dir"
fi
if [[ -d "$pkg" ]]; then
  if [[ $force -eq 0 ]]; then
    # 中断续跑: 机械阶段产物完好且归属一致 → 从 meta.json 重建交接 JSON 幂等退出
    if [[ -f "$pkg/meta.json" ]]; then
      match=$(python3 - "$pkg/meta.json" "$platform" "$id" <<'PY' || true
import json, sys
m = json.load(open(sys.argv[1]))
print("yes" if m.get("platform") == sys.argv[2] and m.get("id") == sys.argv[3] else "no")
PY
)
      if [[ "$match" == "yes" ]]; then
        python3 - "$pkg" "$pkg/meta.json" <<'PY'
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
    "uploader_id": m.get("uploader_id"), "account": m.get("account") or "",
    "video_file": files.get("video", ""), "audio_file": files.get("audio", ""),
    "subtitle_lang": sub.get("selected", "none"),
    "subtitle_source": sub.get("source", "none"),
    "needs_whisper": int(bool(m.get("needs_whisper"))),
    "has_danmaku": int(bool(cap.get("danmaku"))),
    "has_comments": int(bool(cap.get("comments"))),
    "chapters": m.get("chapters_count", 0),
}
print(json.dumps(h, ensure_ascii=False))
PY
        echo "续跑: 机械阶段产物完好，已从中断处恢复（重采请加 --force）" >&2
        exit 0
      fi
    fi
    die "目录冲突: $pkg 已存在但 registry 未登记 $platform/$id — 若目录内容与该视频无关请人工检查；否则加 --force 重采"
  fi
  rm -rf "$pkg/raw" "$pkg/evidence" "$pkg/meta.json"
fi
mkdir -p "$pkg/raw" "$pkg/evidence/frames"

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
      echo "警告: 音频抽取失败（视频可能无音轨）——跳过音频，whisper 转写不可用" >&2
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
danmaku_cap=$(python3 "$META" capability "$platform" danmaku)
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
comments_cap=$(python3 "$META" capability "$platform" comments)
if [[ "$comments_cap" == "bilibili_api" ]]; then
  dxml=""
  (( has_danmaku )) && dxml="$pkg/evidence/danmaku.xml"
  # 传 canonical webpage_url（含 BV 号）而非原始 URL——b23.tv 短链不含 BV 号
  if python3 "$AUDIENCE" bili --url "$canonical_url" --danmaku-xml "$dxml" \
       --out-dir "$pkg/evidence" --duration "$dur" 1>&2; then
    has_comments=1
  fi
else
  # yt-dlp 语义: max_comments 多值须重复键（总数;顶层;回复;每线程回复;深度），逗号串无效
  ea=(--extractor-args "$(printf '%s' "$extractor_key" | tr '[:upper:]' '[:lower:]'):max_comments=60;max_comments=15;max_comments=5;max_comments=10")
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

# meta.json + 交接 JSON（stdout 唯一一行）
python3 "$META" finalize "$tmpdir/distilled.json" \
  --folder "$pkg" \
  --video-file "${video_file#./}" --audio-file "${audio_file#./}" \
  --subtitle-lang "$sel_lang" --subtitle-source "$sel_source" \
  --needs-whisper "$needs_whisper" --has-danmaku "$has_danmaku" \
  --has-comments "$has_comments" --frames-max "$frames_max" \
  --frames-extracted "$frames_extracted" \
  --uploader-id "$uploader_id" --upload-date "$upload_date" --account "$account"
