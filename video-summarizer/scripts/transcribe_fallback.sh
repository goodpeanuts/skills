#!/usr/bin/env bash
# transcribe_fallback.sh —— 本地转写单入口（video-summarizer 认知阶段 Step 2.3）
#
# 降级链: asr（本地 Qwen3-ASR，带临时词表识别偏置）> whisper（faster-whisper
# 静音分片并行）。asr 环境未就绪（exit 3）/ 输出冲突（exit 4）/ 产物校验失败
# 一律自动降级 whisper，whisper 路径原样不喂词表（initial_prompt 幻觉风险）。
#
# 用法（认知阶段只调这一条命令，分支逻辑封装在此）:
#   transcribe_fallback.sh <audio_file> <raw_dir> [--suffix _NN] [--terms <词表路径>]
#     <audio_file>  交接 JSON 的 audio_file（项目根相对全路径）
#     <raw_dir>     归档 raw 目录（subtitle 落点；asr 原始产物落 <raw_dir>/asr_run<suffix>/）
#     --suffix _NN  多P形态（subtitle_NN.srt；asr 产物 asr_run_NN/）
#     --terms       临时词表（交接 JSON context_terms；缺席则 asr 不带 --context）
#
# 成功: 打印 "engine: asr|whisper" 并 exit 0（subtitle 已落 <raw_dir>/subtitle<suffix>.srt）
# 失败: exit 1（两条路都不通——按「无有效口播」规则处理，不要编造）
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
TRANSCRIBE="$SKILL_DIR/scripts/parallel_transcribe.py"
ASR2SRT="$SKILL_DIR/scripts/asr_to_srt.py"

[[ $# -ge 2 ]] || { echo "用法: transcribe_fallback.sh <audio_file> <raw_dir> [--suffix _NN] [--terms <f>]" >&2; exit 1; }
audio=$1 raw_dir=$2; shift 2
suffix="" terms=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --suffix) suffix=$2; shift 2 ;;
    --terms) terms=$2; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done
[[ -f "$audio" ]] || { echo "ERROR: 音频不存在: $audio" >&2; exit 1; }
[[ -d "$raw_dir" ]] || { echo "ERROR: raw 目录不存在: $raw_dir" >&2; exit 1; }
srt_out="$raw_dir/subtitle${suffix}.srt"

# ---------- 第一兜底: asr（goodpeanuts/asr CLI）----------
run_asr() {
  command -v asr >/dev/null 2>&1 || { echo "asr 未安装 → 降级 whisper" >&2; return 1; }
  asr doctor --runtime >/dev/null 2>&1 || { echo "asr 运行环境未就绪（doctor 失败）→ 降级 whisper" >&2; return 1; }
  local out_dir="$raw_dir/asr_run${suffix}" ctx_args=()
  [[ -n "$terms" && -f "$terms" ]] && ctx_args+=(--context "$terms")
  local rc=0
  asr transcribe "$audio" --output "$out_dir" --timestamps --language auto \
    ${ctx_args[@]+"${ctx_args[@]}"} > "$raw_dir/.asr_stdout${suffix}.json" 2> "$raw_dir/.asr_stderr${suffix}.log" || rc=$?
  # exit 3=环境未就绪 4=输出冲突（--resume 语义之外的重采不自动续用旧产物）→ 降级
  if [[ $rc -ne 0 ]]; then
    echo "asr 转写失败（exit $rc，详见 $raw_dir/.asr_stderr${suffix}.log）→ 降级 whisper" >&2
    return 1
  fi
  # 产物校验: stdout JSON 契约 + transcript.json 存在
  python3 - "$raw_dir/.asr_stdout${suffix}.json" "$out_dir/transcript.json" <<'PY' || return 1
import json, sys
from pathlib import Path
try:
    r = json.loads(Path(sys.argv[1]).read_text())
except Exception as e:
    print(f"asr stdout JSON 不可解析: {e}", file=sys.stderr); sys.exit(1)
if r.get("schema") != "asr/cli/v1" or r.get("ok") is not True:
    print(f"asr 契约异常: schema={r.get('schema')} ok={r.get('ok')}", file=sys.stderr); sys.exit(1)
tj = Path(sys.argv[2])
if not tj.exists():
    print("asr transcript.json 缺失", file=sys.stderr); sys.exit(1)
PY
  # SRT 转换（词级时间戳 → 句级 segments）
  python3 "$ASR2SRT" "$out_dir/transcript.json" --out "$srt_out" \
    || { echo "asr→SRT 转换失败 → 降级 whisper" >&2; return 1; }
  [[ -s "$srt_out" ]] || { echo "asr SRT 为空（无有效语音？）→ 降级 whisper" >&2; return 1; }
  return 0
}

if run_asr; then
  echo "engine: asr（产物: $raw_dir/asr_run${suffix}/，词表: ${terms:-无}）" >&2
  echo "engine: asr"
  exit 0
fi

# ---------- 第二兜底: whisper（faster-whisper 静音分片并行）----------
echo "转写走 whisper 兜底" >&2
uv run "$TRANSCRIBE" --input "$audio" --output-dir "$raw_dir" --model small --language auto >&2
if [[ -f "$raw_dir/subtitle.srt" && -n "$suffix" && "$raw_dir/subtitle.srt" != "$srt_out" ]]; then
  mv -f "$raw_dir/subtitle.srt" "$srt_out"
fi
[[ -s "$srt_out" ]] || { echo "ERROR: whisper 也未产出字幕（无有效语音？）——按「无有效口播」规则处理" >&2; exit 1; }
echo "engine: whisper" >&2
echo "engine: whisper"
exit 0
