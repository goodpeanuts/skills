#!/usr/bin/env bash
# pipeline_prepare.sh —— 机械阶段编排（video-summarizer · 全平台能力模型）
#
# 用法（在项目根目录运行）:
#   pipeline_prepare.sh init
#       初始化 archive/ cache/ 与项目 .gitignore（幂等，可重复执行）
#   pipeline_prepare.sh <URL> [--force] [--sub-pref "zh-Hans,zh,en"]
#       采集+归档。已总结视频（registry 按 平台/ID 查重）打印 SKIP 并退出；
#       --sub-pref 覆盖默认字幕语言偏好 [zh-Hans, zh, zh-Hant, 原语言, en]
#   pipeline_prepare.sh finish --platform P --id ID --title T --folder F
#       [--duration D] [--subtitle-lang L] [--subtitle-source S]
#       [--url U] [--uploader NAME] [--language L]
#       认知阶段完成后回写 registry（要求 <folder>/summary.md 已存在）
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
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
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

# ---------- finish: 回写 registry ----------
if [[ "$cmd" == "finish" ]]; then
  shift
  platform="" id="" title="" folder="" dur=0 slang="none" ssrc="none" url="" uploader="" language=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "finish: 参数 $1 缺少取值"
    case $1 in
      --platform) platform=$2 ;;
      --id) id=$2 ;;
      --title) title=$2 ;;
      --folder) folder=$2 ;;
      --duration) dur=$2 ;;
      --subtitle-lang) slang=$2 ;;
      --subtitle-source) ssrc=$2 ;;
      --url) url=$2 ;;
      --uploader) uploader=$2 ;;
      --language) language=$2 ;;
      *) die "finish: 未知参数 $1" ;;
    esac
    shift 2
  done
  [[ -n "$platform" && -n "$id" && -n "$title" && -n "$folder" ]] || die "finish 需要 --platform --id --title --folder"
  [[ -f "$folder/summary.md" ]] || die "finish 拒绝回写: $folder/summary.md 不存在（先完成认知阶段产出）"
  mkdir -p archive
  python3 - "$REGISTRY" "$platform" "$id" "$title" "$folder" "$dur" "$slang" "$ssrc" "$url" "$uploader" "$language" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
reg_path, platform, vid, title, folder, dur, slang, ssrc, url, uploader, language = sys.argv[1:12]
reg = {}
if Path(reg_path).exists():
    try:
        reg = json.loads(Path(reg_path).read_text())
    except json.JSONDecodeError:
        print("警告: registry.json 损坏，重建", file=sys.stderr)
reg.setdefault("videos", {}).setdefault(platform, {})[vid] = {
    "title": title,
    "folder": folder,
    "url": url or None,
    "duration": int(float(dur or 0)),
    "language": language or None,
    "uploader": uploader or None,
    "subtitle_lang": slang,
    "subtitle_source": ssrc,
    "summarized_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
}
Path(reg_path).write_text(json.dumps(reg, ensure_ascii=False, indent=2) + "\n")
print(f"registry 已更新: {platform}/{vid} → {folder}")
PY
  exit 0
fi

# ---------- prepare: 机械阶段 ----------
url=$1; shift || true
force=0 sub_pref=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1; shift ;;
    --sub-pref) sub_pref=$2; shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done

[[ -d .git || -d archive ]] || die "未在项目根目录（无 .git 与 archive/）。首次使用请先运行: pipeline_prepare.sh init"

# Cookie 能力位: URL 命中已配置平台则先确保登录态（-J 才能看到完整字幕清单）
cookie_file=""
case "$url" in
  *bilibili.com*|*b23.tv*)
    python3 "$COOKIES" ensure --platform bilibili --url "$url" 1>&2 \
      || die "Cookie 准备失败（按上方 hint 手动放置后重试）"
    cookie_file="cache/_bilibili.cookies.txt"
    ;;
esac
cookie_args=()
[[ -n "$cookie_file" && -f "$cookie_file" ]] && cookie_args=(--cookies "$cookie_file")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# 1) 单次全量元数据（字幕清单/章节一并到手；--write-subs 触发 yt-dlp 懒加载的
#    字幕探测——否则 -J 的 subtitles 恒为空字典。-J 的 simulate 语义不会写盘）
yt-dlp -J --skip-download --no-playlist --write-subs ${cookie_args[@]+"${cookie_args[@]}"} \
  "$url" > "$tmpdir/info.json" 2> "$tmpdir/ytdlp.err" \
  || die "获取元信息失败: $(tail -3 "$tmpdir/ytdlp.err" | tr '\n' ' ')"

# 2) 蒸馏: 平台归一化/能力位/字幕选优/目录名消毒
python3 "$META" distill "$tmpdir/info.json" --out "$tmpdir/distilled.json" --sub-pref "$sub_pref"
[[ "$(jget "$tmpdir/distilled.json" is_playlist)" == "True" ]] \
  && die "输入是播放列表/合集/收藏夹，请用批量模式枚举后逐个处理（见 SKILL.md Batch Mode）"

platform=$(jget "$tmpdir/distilled.json" platform)
id=$(jget "$tmpdir/distilled.json" id)
title=$(jget "$tmpdir/distilled.json" title)
dur=$(jget "$tmpdir/distilled.json" duration)
language=$(jget "$tmpdir/distilled.json" language)
uploader=$(jget "$tmpdir/distilled.json" uploader)
uploader_id=$(jget "$tmpdir/distilled.json" uploader_id)
safe_dir=$(jget "$tmpdir/distilled.json" safe_dir)
sel_lang=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["lang"])' "$tmpdir/distilled.json")
sel_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["source"])' "$tmpdir/distilled.json")
sel_kind=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["subtitle"]["kind"])' "$tmpdir/distilled.json")

# 3) registry 查重（全平台统一键 平台/ID; --force 重跑）
if (( ! force )); then
  skip=$(python3 - "$REGISTRY" "$platform" "$id" <<'PY' || true
import json, sys
from pathlib import Path
p, platform, vid = sys.argv[1:4]
try:
    reg = json.loads(Path(p).read_text())
except Exception:
    sys.exit(0)
e = reg.get("videos", {}).get(platform, {}).get(vid)
if e:
    print(f"SKIP: {platform}/{vid} 已总结过 -> {e['folder']} (重跑请加 --force)")
PY
)
  if [[ -n "$skip" ]]; then echo "$skip"; exit 0; fi
fi

# 4) 归档目录（平台子目录 + 消毒目录名）
#    目录已存在时清理机械阶段自有产物（防旧 subtitle.srt 等残留被误当有效），
#    summary.md/evidence.md 归认知阶段覆写，保留到那时
ym=$(date +%Y-%m)
pkg="archive/$ym/$platform/$safe_dir"
if [[ -d "$pkg" ]]; then
  if (( ! force )); then
    if ! python3 - "$REGISTRY" "$platform" "$id" <<'PY'
import json, sys
from pathlib import Path
try:
    reg = json.loads(Path(sys.argv[1]).read_text())
except Exception:
    sys.exit(1)
entry = reg.get("videos", {}).get(sys.argv[2], {}).get(sys.argv[3])
sys.exit(0 if entry else 1)
PY
    then
      die "目录冲突: $pkg 已存在但 registry 未登记 $platform/$id — 请人工检查后处理"
    fi
  fi
  rm -rf "$pkg/raw" "$pkg/evidence" "$pkg/meta.json"
fi
mkdir -p "$pkg/raw" "$pkg/evidence/frames"

# 5) 视频 + 本地抽音频（一次网络下载）
yt-dlp --no-playlist ${cookie_args[@]+"${cookie_args[@]}"} \
  -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" \
  --merge-output-format mp4 -o "$pkg/raw/video.%(ext)s" "$url" \
  >/dev/null 2> "$tmpdir/dl.err" || die "视频下载失败: $(tail -3 "$tmpdir/dl.err" | tr '\n' ' ')"
video_file=$(ls "$pkg"/raw/video.* 2>/dev/null | head -1 || true)
[[ -n "$video_file" ]] || die "下载完成但未找到视频文件（raw/video.*）"

ffmpeg -y -loglevel error -i "$video_file" -vn -c:a libmp3lame -q:a 4 "$pkg/raw/audio.mp3" 2> "$tmpdir/ffaudio.err" \
  || ffmpeg -y -loglevel error -i "$video_file" -vn -c:a aac -b:a 128k "$pkg/raw/audio.m4a" 2>> "$tmpdir/ffaudio.err" \
  || die "音频抽取失败（视频可能无音轨）: $(tail -2 "$tmpdir/ffaudio.err" | tr '\n' ' ')"
audio_file=$(ls "$pkg"/raw/audio.* 2>/dev/null | head -1 || true)

# 6) 字幕: 按蒸馏结果下载选中语言（manual/ai 走 write-subs，auto 走 write-auto-subs）
if [[ "$sel_lang" != "none" && "$sel_kind" != "None" ]]; then
  sub_flag=--write-subs; [[ "$sel_kind" == "auto" ]] && sub_flag=--write-auto-subs
  yt-dlp --no-playlist --skip-download $sub_flag --sub-lang "$sel_lang" --convert-subs srt \
    -o "$pkg/raw/subtitle" "$url" >/dev/null 2>&1 || true
  sub_file=$(ls "$pkg"/raw/subtitle.*.srt 2>/dev/null | head -1 || true)
  [[ -n "$sub_file" && "$sub_file" != "$pkg/raw/subtitle.srt" ]] && mv -f "$sub_file" "$pkg/raw/subtitle.srt"
fi
needs_whisper=0
if [[ ! -f "$pkg/raw/subtitle.srt" ]]; then
  needs_whisper=1; sel_lang=none; sel_source=none
fi

# 7) 章节（全平台通用，取自 -J）
python3 - "$tmpdir/distilled.json" "$pkg/evidence/chapters.json" <<'PY'
import json, sys
chapters = json.load(open(sys.argv[1])).get("chapters") or []
json.dump(chapters, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY

# 8) 弹幕能力位（bilibili 专属）
has_danmaku=0
if [[ "$platform" == "bilibili" ]]; then
  yt-dlp --no-playlist --skip-download --write-subs --sub-lang danmaku \
    -o "$pkg/evidence/danmaku" "$url" >/dev/null 2>&1 || true
  [[ -f "$pkg/evidence/danmaku.danmaku.xml" ]] && mv -f "$pkg/evidence/danmaku.danmaku.xml" "$pkg/evidence/danmaku.xml"
  [[ -f "$pkg/evidence/danmaku.xml" ]] && has_danmaku=1
fi

# 9) 评论能力位（bilibili 走 API；其余平台走 yt-dlp --write-comments 原生支持）
has_comments=0
if [[ "$platform" == "bilibili" ]]; then
  dxml=""
  (( has_danmaku )) && dxml="$pkg/evidence/danmaku.xml"
  if python3 "$AUDIENCE" bili --url "$url" --danmaku-xml "$dxml" \
       --out-dir "$pkg/evidence" --duration "$dur" 1>&2; then
    has_comments=1
  fi
else
  ea=()
  [[ "$platform" == "youtube" ]] && ea=(--extractor-args "youtube:max_comments=60,15,5,10")
  yt-dlp --no-playlist --skip-download --write-comments --write-info-json ${ea[@]+"${ea[@]}"} \
    -o "$pkg/evidence/comments" "$url" >/dev/null 2>&1 || true
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

# 10) 机械抽帧（自适应上限: 时长/75s，夹在 8..20；失败非致命，认知阶段可无帧工作）
frames_max=$(( dur > 1500 ? 20 : (dur < 600 ? 8 : dur / 75) ))
bash "$FRAMES" "$video_file" "$pkg/evidence/frames" \
  --max "$frames_max" --chapters "$pkg/evidence/chapters.json" 1>&2 \
  || echo "警告: 机械抽帧失败（继续，认知阶段将无机械帧可用）" >&2

# 11) meta.json + 交接 JSON（stdout 唯一一行）
python3 "$META" finalize "$tmpdir/distilled.json" \
  --folder "$pkg" \
  --video-file "${video_file#./}" --audio-file "${audio_file#./}" \
  --subtitle-lang "$sel_lang" --subtitle-source "$sel_source" \
  --needs-whisper "$needs_whisper" --has-danmaku "$has_danmaku" \
  --has-comments "$has_comments" --frames-max "$frames_max"
