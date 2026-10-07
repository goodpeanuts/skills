#!/usr/bin/env bash
# extract_frames.sh —— 抽帧器（video-summarizer Pipeline 机械阶段组件）
#
# 用法:
#   extract_frames.sh <video> <outdir> [--max N] [--chapters <chapters.json>]   机械抽帧（默认上限 12）
#   extract_frames.sh <video> <outdir> --at "12,75.5,130"                       Agent 补充抽帧（无上限）
#
# 机械抽帧策略: 章节边界优先 → 不足 --max 则均匀间隔补齐 → 排序去重后截断
# 输出命名: HH-MM-SS.jpg（宽 1280，控制上下文开销）
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
grab() { ffmpeg -y -loglevel error -ss "$1" -i "$video" -frames:v 1 -vf "scale=1280:-2" "$outdir/$(fmt_name "$1").jpg"; }

# --- Agent 补充抽帧: 指定时刻, 无上限 ---
if [[ -n "$at" ]]; then
  IFS=',' read -ra TS <<< "$at"
  for t in "${TS[@]}"; do [[ -n "$t" ]] && grab "$t"; done
  echo "{\"extracted\": ${#TS[@]}, \"outdir\": \"$outdir\", \"mode\": \"agent\"}"
  exit 0
fi

# --- 机械抽帧 ---
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
times=()

# 章节起点
if [[ -n "$chapters" && -f "$chapters" ]]; then
  times=()
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

# 均匀补齐
count=${#times[@]}
if (( count < max )); then
  need=$(( max - count ))
  step=$(python3 -c "print($dur / ($need + 1))")
  for (( i=1; i<=need; i++ )); do
    times+=("$(python3 -c "print(int($step * $i))")")
  done
fi

# 排序去重 → 截断 → 抽取
sorted_times=$(printf '%s\n' "${times[@]:-0}" | sort -n -u | head -n "$max")
times=()
while IFS= read -r t; do [[ -n "$t" ]] && times+=("$t"); done <<< "$sorted_times"
n=0
for t in "${times[@]}"; do grab "$t" && n=$((n+1)); done
echo "{\"extracted\": $n, \"outdir\": \"$outdir\", \"mode\": \"mechanical\", \"cap\": $max}"
