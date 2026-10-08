#!/usr/bin/env bash
# extract_frames.sh —— 抽帧器（video-summarizer 机械阶段组件）
#
# 用法:
#   extract_frames.sh <video> <outdir> [--max N] [--chapters <chapters.json>]   机械抽帧
#   extract_frames.sh <video> <outdir> --at "12,75.5,130"                       Agent 补充抽帧
#   可选: --no-dedup（关闭近重复帧剔除） --dedup-thresh T（阈值 0-255，默认 10）
#
# 机械抽帧: 章节起点优先 → 不足 max 均匀间隔补齐 → 排序去重后截断 → 近重复帧剔除
#   近重复剔除: 16×16 RGB 均值签名，与上一张【保留】帧平均绝对差 < 阈值 → 删除后者；
#   只处理本次机械抽帧产出的帧（目录既有帧与 Agent --at 补帧不参与）。
#   阈值 10 为实测校准值（同场景 4s 间隔差≈27、场景切换差 61+，10 只剔几乎相同的帧）。
# 输出: HH-MM-SS.jpg（宽度上限 1280，竖屏不放大），同一秒碰撞自动加 -2/-3 序号
# 汇总: 纯文本行 "frames: extracted=N requested=M mode=mechanical|agent [dedup_removed=K]"（供日志，非契约）
set -euo pipefail

[[ $# -ge 2 ]] || { echo "用法: $0 <video> <outdir> [--max N] [--chapters f.json] [--at t1,t2] [--no-dedup] [--dedup-thresh T]" >&2; exit 1; }
video=$1 outdir=$2; shift 2

max=12 chapters="" at="" dedup=1 thresh=10
while [[ $# -gt 0 ]]; do
  case $1 in
    --max) [[ $# -ge 2 ]] || { echo "ERROR: --max 缺少取值" >&2; exit 1; }; max=$2; shift 2 ;;
    --chapters) [[ $# -ge 2 ]] || { echo "ERROR: --chapters 缺少取值" >&2; exit 1; }; chapters=$2; shift 2 ;;
    --at) [[ $# -ge 2 ]] || { echo "ERROR: --at 缺少取值" >&2; exit 1; }; at=$2; shift 2 ;;
    --no-dedup) dedup=0; shift ;;
    --dedup-thresh) [[ $# -ge 2 ]] || { echo "ERROR: --dedup-thresh 缺少取值" >&2; exit 1; }; thresh=$2; shift 2 ;;
    *) echo "ERROR: 未知参数: $1" >&2; exit 1 ;;
  esac
done
mkdir -p "$outdir"
[[ -f "$video" ]] || { echo "ERROR: 视频不存在: $video" >&2; exit 1; }

fmt_name() { python3 -c "s=float('$1'); h=int(s//3600); m=int(s%3600//60); sec=int(s%60); print(f'{h:02d}-{m:02d}-{sec:02d}')"; }

out_path() {
  # 同一秒多帧: 00-01-23.jpg → 00-01-23-2.jpg → 00-01-23-3.jpg
  # 注意: local 多赋值语句的实参先整体展开后赋值，引用前值必须分开赋值
  local stem f n
  stem="$outdir/$(fmt_name "$1")"
  f="${stem}.jpg"
  n=1
  while [[ -e "$f" ]]; do n=$((n+1)); f="${stem}-$n.jpg"; done
  printf '%s' "$f"
}

grab() { # $1=时刻 $2=目标文件
  # 宽度封顶 1280、窄于 1280 的（含竖屏）保持原宽，高度自适应偶数对齐；
  # 失败时清掉半写文件（否则残帧会进 dedup 名单与归档）
  ffmpeg -y -loglevel error -ss "$1" -i "$video" -frames:v 1 \
    -vf "scale='min(1280,iw)':-2" "$2" 2>/dev/null || { rm -f "$2"; return 1; }
}

# --- Agent 补充抽帧: 指定时刻，无上限，不去重（补帧自带明确动机） ---
if [[ -n "$at" ]]; then
  IFS=',' read -ra TS <<< "$at"
  n=0
  for t in "${TS[@]}"; do
    [[ -n "$t" ]] || continue
    if [[ ! "$t" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "ERROR: 非法时刻（须为秒数）: $t" >&2
      continue
    fi
    f=$(out_path "$t")
    if grab "$t" "$f"; then n=$((n+1)); fi
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

# 排序去重 → 截断 → 抽取（单帧失败不中断整体；记录本次产出供去重）
sorted_times=$(printf '%s\n' "${times[@]:-0}" | sort -n -u | head -n "$max")
times=()
while IFS= read -r t; do [[ -n "$t" ]] && times+=("$t"); done <<< "$sorted_times"
n=0
made=()
for t in "${times[@]}"; do
  f=$(out_path "$t")
  if grab "$t" "$f"; then made+=("$f"); n=$((n+1)); fi
done

# 近重复帧剔除（仅机械帧；文件名 HH-MM-SS 零填充，字典序=时间序）
dedup_removed=0
if [[ $dedup -eq 1 && ${#made[@]} -gt 1 ]]; then
  dedup_removed=$(python3 - "$thresh" "${made[@]}" <<'PY'
import subprocess, sys
from pathlib import Path
thresh = float(sys.argv[1])
def _tskey(f):
    # 文件名 HH-MM-SS[-N].jpg → (时,分,秒[,后缀号]) 元组：基础帧先于同秒 -2/-3 后缀帧
    stem = f.rsplit("/", 1)[-1].split(".")[0]
    try:
        return tuple(int(p) for p in stem.split("-"))
    except ValueError:
        return (10**9,)
def sig(p):
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(p), "-vf", "scale=16:16",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True).stdout
    return [raw[i:i+3] for i in range(0, len(raw), 3)]
def diff(a, b):
    return sum(abs(x[i] - y[i]) for ra, rb in zip(a, b)
               for x, y in [(ra, rb)] for i in range(3)) / (16 * 16 * 3)
kept, removed = None, 0
for f in sorted(sys.argv[2:], key=_tskey):
    s = sig(f)
    if not s:          # 签名失败（解码异常）：保留该帧，不做判定
        continue
    if kept is not None and diff(kept, s) < thresh:
        Path(f).unlink()
        removed += 1
    else:
        kept = s
print(removed)
PY
) || dedup_removed=0
  (( dedup_removed > 0 )) && echo "近重复帧剔除: removed=$dedup_removed thresh=$thresh" >&2
  n=$(( n - dedup_removed ))
fi
echo "frames: extracted=$n requested=$max mode=mechanical dedup_removed=$dedup_removed"
