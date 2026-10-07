#!/usr/bin/env bash
# extract_frames.sh —— 抽帧器（video-summarizer 机械阶段组件）
#
# 用法:
#   extract_frames.sh <video> <outdir> [--max N] [--chapters <chapters.json>]   机械抽帧
#   extract_frames.sh <video> <outdir> --at "12,75.5,130"                       Agent 补充抽帧
#
# 机械抽帧: 章节起点优先 → 不足 max 均匀间隔补齐 → 排序去重后截断
# 输出: HH-MM-SS.jpg（宽度上限 1280，竖屏不放大），同一秒碰撞自动加 -2/-3 序号
# 汇总: 纯文本行 "frames: extracted=N requested=M mode=mechanical|agent"（供日志，非契约）
set -euo pipefail

[[ $# -ge 2 ]] || { echo "用法: $0 <video> <outdir> [--max N] [--chapters f.json] [--at t1,t2]" >&2; exit 1; }
video=$1 outdir=$2; shift 2

max=12 chapters="" at=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --max) max=$2; shift 2 ;;
    --chapters) chapters=$2; shift 2 ;;
    --at) at=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$outdir"
[[ -f "$video" ]] || { echo "ERROR: 视频不存在: $video" >&2; exit 1; }

fmt_name() { python3 -c "s=float('$1'); h=int(s//3600); m=int(s%3600//60); sec=int(s%60); print(f'{h:02d}-{m:02d}-{sec:02d}')"; }

out_path() {
  # 同一秒多帧: 00-01-23.jpg → 00-01-23-2.jpg → 00-01-23-3.jpg
  local stem="$outdir/$(fmt_name "$1")" f="${stem}.jpg" n=1
  while [[ -e "$f" ]]; do n=$((n+1)); f="${stem}-$n.jpg"; done
  printf '%s' "$f"
}

grab() {
  # 宽度封顶 1280、窄于 1280 的（含竖屏）保持原宽，高度自适应偶数对齐
  ffmpeg -y -loglevel error -ss "$1" -i "$video" -frames:v 1 \
    -vf "scale='min(1280,iw)':-2" "$(out_path "$1")" 2>/dev/null
}

# --- Agent 补充抽帧: 指定时刻，无上限 ---
if [[ -n "$at" ]]; then
  IFS=',' read -ra TS <<< "$at"
  n=0
  for t in "${TS[@]}"; do
    [[ -n "$t" ]] || continue
    if grab "$t"; then n=$((n+1)); fi
  done
  echo "frames: extracted=$n requested=${#TS[@]} mode=agent"
  exit 0
fi

# --- 机械抽帧 ---
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
times=()

# 章节起点优先
if [[ -n "$chapters" && -f "$chapters" ]]; then
  while IFS= read -r c; do [[ -n "$c" ]] && times+=("$c"); done < <(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if isinstance(d, list):
    for c in d:
        print(int(c.get("start_time", 0)))
' "$chapters")
fi

# 不足 max 则均匀补齐
count=${#times[@]}
if (( count < max )); then
  need=$(( max - count ))
  step=$(python3 -c "print($dur / ($need + 1))")
  for (( i=1; i<=need; i++ )); do
    times+=("$(python3 -c "print(int($step * $i))")")
  done
fi

# 排序去重 → 截断 → 抽取（单帧失败不中断整体）
sorted_times=$(printf '%s\n' "${times[@]:-0}" | sort -n -u | head -n "$max")
times=()
while IFS= read -r t; do [[ -n "$t" ]] && times+=("$t"); done <<< "$sorted_times"
n=0
for t in "${times[@]}"; do
  if grab "$t"; then n=$((n+1)); fi
done
echo "frames: extracted=$n requested=$max mode=mechanical"
