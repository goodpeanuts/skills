#!/usr/bin/env bash
# pipeline_prepare.sh —— 机械阶段编排（video-summarizer Pipeline）
#
# 用法（在项目根目录运行）:
#   pipeline_prepare.sh <URL> [--force]          采集+归档；已总结过的视频自动跳过
#   pipeline_prepare.sh finish --id ID --title T --folder F --duration D \
#        [--subtitle-lang L] [--platform P]      认知阶段完成后回写 registry
#
# 机械阶段产出: archive/YYYY-MM/<ID_标题>/{summary.md,evidence.md(认知阶段写),
#   raw/{video.mp4,audio.mp3,subtitle.srt,danmaku.xml,comments.json,chapters.json,
#   audience.json,frames/*.jpg}}；顶层只留两个人读交付物，素材全在 raw/。
# stdout 末行输出 JSON 摘要供 Agent 消费。
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
META="$SKILL_DIR/scripts/fetch_bili_meta.py"
FRAMES="$SKILL_DIR/scripts/extract_frames.sh"
REGISTRY="archive/registry.json"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

cmd=${1:-}; [[ -n "$cmd" ]] || usage

# ---------- finish: 回写 registry ----------
if [[ "$cmd" == "finish" ]]; then
  shift
  id="" title="" folder="" dur=0 slang="none" platform="bilibili"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --id) id=$2 ;; --title) title=$2 ;; --folder) folder=$2 ;;
      --duration) dur=$2 ;; --subtitle-lang) slang=$2 ;; --platform) platform=$2 ;;
    esac; shift 2
  done
  [[ -n "$id" && -n "$folder" ]] || usage
  mkdir -p archive
  python3 - "$REGISTRY" "$id" "$title" "$folder" "$dur" "$slang" "$platform" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
reg_path, vid, title, folder, dur, slang, platform = sys.argv[1:8]
reg = {"videos": {}}
if Path(reg_path).exists():
    try:
        reg = json.loads(Path(reg_path).read_text())
    except json.JSONDecodeError:
        pass
reg.setdefault("videos", {})[vid] = {
    "title": title, "folder": folder, "platform": platform,
    "duration": int(float(dur)), "subtitle_lang": slang,
    "summarized_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
}
Path(reg_path).write_text(json.dumps(reg, ensure_ascii=False, indent=2))
print(f"registry 已更新: {vid} → {folder}")
PY
  exit 0
fi

# ---------- prepare: 机械阶段 ----------
url=$1; shift || true
force=0; [[ "${1:-}" == "--force" ]] && force=1

is_bili=0; [[ "$url" =~ (bilibili\.com|b23\.tv) ]] && is_bili=1
cookie_args=()
vid=""
if (( is_bili )); then
  vid=$(python3 -c "import re,sys; m=re.search(r'(BV[0-9A-Za-z]{10})', sys.argv[1]); print(m.group(1) if m else '')" "$url")
  [[ -n "$vid" ]] || { echo "ERROR: B 站链接但无法解析 BV 号" >&2; exit 1; }
fi

# registry 查重（默认跳过; --force 重跑）
if (( is_bili && ! force )) && [[ -f "$REGISTRY" ]] && \
   python3 -c "import json,sys; sys.exit(0 if '$vid' in json.load(open('$REGISTRY')).get('videos',{}) else 1)" 2>/dev/null; then
  folder=$(python3 -c "import json; print(json.load(open('$REGISTRY'))['videos']['$vid']['folder'])")
  echo "SKIP: ${vid} 已总结过 -> ${folder} (重跑请加 --force)"
  exit 0
fi

# Cookie（B 站专用）
if (( is_bili )); then
  python3 "$META" ensure-cookies --url "$url" | tail -1
  cookie_args=(--cookies cache/_bilibili.cookies.txt)
fi

# 元信息
info=()
while IFS= read -r line; do info+=("$line"); done < <(yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} --print "%(id)s" --print "%(title)s" --print "%(duration)s" "$url")
[[ ${#info[@]} -eq 3 ]] || { echo "ERROR: 获取视频元信息失败" >&2; exit 1; }
vid_generic=${vid:-${info[0]}}
title=${info[1]}
dur=${info[2]%.*}
[[ "$dur" == "NA" || -z "$dur" ]] && dur=0
[[ "$vid_generic" == "NA" || -z "$vid_generic" ]] && vid_generic="unknown_$RANDOM"

safe=$(python3 -c "import re,sys; print(re.sub(r'[\\\\/:*?\"<>|]', '_', sys.argv[1])[:40].strip())" "$title")
ym=$(date +%Y-%m)
pkg="archive/$ym/${vid_generic}_${safe}"
mkdir -p "$pkg/raw/frames"

# 视频 + 音频
yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} \
  -f "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best" \
  --merge-output-format mp4 -o "$pkg/raw/video.%(ext)s" "$url" >/dev/null
yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} -x --audio-format mp3 -o "$pkg/raw/audio.%(ext)s" "$url" >/dev/null

# 字幕: B 站探测选优 / 其他平台通用链路
subtitle_lang="none"
if (( is_bili )); then
  probe=$(python3 "$META" probe-subs --url "$url")
  echo "字幕探测: $probe" >&2
  subtitle_lang=$(python3 -c "import json,sys; print(json.load(sys.stdin)['best'])" <<<"$probe")
  if [[ "$subtitle_lang" != "none" ]]; then
    yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} --skip-download --write-subs --sub-lang "$subtitle_lang" \
      --convert-subs srt -o "$pkg/raw/subtitle" "$url" >/dev/null
  fi
  # 弹幕（证据原始件）
  yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} --skip-download --write-subs --sub-lang danmaku \
    -o "$pkg/raw/danmaku" "$url" >/dev/null 2>&1 || true
  [[ -f "$pkg/raw/danmaku.danmaku.xml" ]] && mv "$pkg/raw/danmaku.danmaku.xml" "$pkg/raw/danmaku.xml"
else
  yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} --skip-download --write-subs --sub-lang "zh-Hans,zh-Hant,zh,en" \
    --convert-subs srt -o "$pkg/subtitle" "$url" >/dev/null 2>&1 || \
  yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} --skip-download --write-auto-subs --sub-lang "zh,en" \
    --convert-subs srt -o "$pkg/raw/subtitle" "$url" >/dev/null 2>&1 || true
fi
sub_file=$(ls "$pkg"/raw/subtitle.*.srt 2>/dev/null | head -1 || true)
[[ -n "$sub_file" && "$sub_file" != "$pkg/raw/subtitle.srt" ]] && mv "$sub_file" "$pkg/raw/subtitle.srt"

# 章节 + 机械抽帧
yt-dlp ${cookie_args[@]+"${cookie_args[@]}"} --print "%(chapters)j" "$url" > "$pkg/raw/chapters.json" 2>/dev/null || echo "null" > "$pkg/raw/chapters.json"
frames_json=$(bash "$FRAMES" "$pkg/raw/video.mp4" "$pkg/raw/frames" --max 12 --chapters "$pkg/raw/chapters.json")
echo "抽帧: $frames_json" >&2

# 观众反馈（B 站专用）
audience_json='{}'
if (( is_bili )); then
  audience_json=$(python3 "$META" audience --url "$url" \
    --danmaku-xml "$pkg/raw/danmaku.xml" --out-dir "$pkg/raw" --duration "$dur" | tail -1)
  echo "观众反馈: $audience_json" >&2
fi

needs_whisper=0; [[ ! -f "$pkg/raw/subtitle.srt" ]] && needs_whisper=1
platform="other"; (( is_bili )) && platform="bilibili"

# 摘要（stdout 末行, Agent 消费）
echo "{\"folder\": \"$pkg\", \"id\": \"$vid_generic\", \"title\": \"$title\", \"duration\": $dur, \"platform\": \"$platform\", \"subtitle_lang\": \"$subtitle_lang\", \"needs_whisper\": $needs_whisper}"
