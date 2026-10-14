#!/usr/bin/env python3
"""asr_to_srt.py —— asr transcript.json（asr/transcript/v1）→ 句级 SRT

把 goodpeanuts/asr（Qwen/Qwen3-ASR-1.7B + Qwen3-ForcedAligner-0.6B 默认配置）
的词级时间戳按「句末标点 + 停顿阈值」聚合为句级 segments，
写出与官方字幕同构的 SRT，供 video-summarizer 后续流程（逐段详解、只看项、
verify 时间戳检查）无差别消费。

用法:
  python3 asr_to_srt.py <transcript.json> --out <subtitle_NN.srt>

聚合规则:
  - 词按 start 升序处理（未知时间戳的词段跳过——asr 不伪造零秒）
  - 断句: 句末标点（。！？；.!?;）或词间隙 > 0.8s 或句子时长 > 12s 硬切
  - 句子时间 = 首词 start ~ 末词 end（无 end 时取下一词 start 兜底）
  - Latin 词间补空格、CJK 紧贴（merge_tokens）——修复拉丁文本词间粘连
"""

from __future__ import annotations  # PEP 604 联合类型注解兼容 Python 3.8/3.9

import argparse
import json
import re
import sys
from pathlib import Path

# 句末标点（中西）
SENT_END_RE = re.compile(r"[。！？；!?;]$")
# 词间停顿超过此值即断句（口语换气/段落边界）
MAX_GAP = 0.8
# 单句时长上限（硬切防超长行）
MAX_SENT_DURATION = 12.0


def load_segments(transcript: dict):
    """transcript/v1 的 segments（通常词级）→ [(start, end, text)]，无时间的跳过。"""
    out = []
    for seg in transcript.get("segments") or []:
        start, end, text = seg.get("start"), seg.get("end"), (seg.get("text") or "").strip()
        if start is None or not text:
            continue
        out.append((float(start), float(end) if end is not None else None, text))
    out.sort(key=lambda s: s[0])
    return out


def merge_tokens(tokens):
    """拼合 tokens 保留原生空白——Latin 词间可能有空格、CJK 紧贴。

    对任意相邻两个 token,如果后一个不是以空白开头(单引号空格),且前一个是
    Latin 结尾(含 ASCII 字母/数字主字符)且后一个是 Latin 开头,在之间补一个空格。
    CJK 词紧贴不加。

    上游 Qwen3-ForcedAligner 对英文通常给裸词(无前导空格),对中文给整段——
    这个规则让两种输入都得到粗放但可读的合并文本。
    """
    if not tokens:
        return ""
    out = tokens[0]
    for prev, tok in zip(tokens, tokens[1:]):
        if not tok:
            continue
        # 已有原生分隔(前 token 尾或当前 token 头有空白)
        if out.endswith((" ", "\n")) or tok.startswith((" ", "\n")):
            out += tok
            continue
        prev_last = out.rstrip()[-1] if out.rstrip() else ""
        # 拉丁-拉丁(或数字)相邻且两端无空格:补空格
        if (prev_last and re.match(r"[A-Za-z0-9]", prev_last)
                and re.match(r"[A-Za-z0-9]", tok[0])):
            out += " " + tok
        else:
            out += tok
    return out


def aggregate(words):
    """词级 [(start, end, text)] → 句级 [(start, end, text)]。"""
    sentences = []
    cur_start = cur_end = None
    cur_words = []
    for i, (start, end, text) in enumerate(words):
        if cur_start is None:
            cur_start, cur_end, cur_words = start, end, [text]
            continue
        gap = start - (cur_end if cur_end is not None else start)
        hard_cut = (cur_end is not None and cur_end - cur_start > MAX_SENT_DURATION)
        if gap > MAX_GAP or hard_cut or SENT_END_RE.search(cur_words[-1]):
            sentences.append((cur_start, cur_end, merge_tokens(cur_words)))
            cur_start, cur_end, cur_words = start, end, [text]
        else:
            if end is not None:
                cur_end = end if cur_end is None else max(cur_end, end)
            cur_words.append(text)
    if cur_words:
        sentences.append((cur_start, cur_end, merge_tokens(cur_words)))

    # end 缺失兜底: 取下一句 start；末句无 end 则 start + 2s
    fixed = []
    for i, (s, e, t) in enumerate(sentences):
        if e is None or e < s:
            e = sentences[i + 1][0] if i + 1 < len(sentences) else s + 2.0
        fixed.append((s, e, t))
    return fixed


def format_ts(seconds: float) -> str:
    ms = max(0, int(round(seconds * 1000)))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def to_srt(sentences) -> str:
    lines = []
    for i, (start, end, text) in enumerate(sentences, 1):
        lines.append(f"{i}\n{format_ts(start)} --> {format_ts(end)}\n{text}\n")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="asr transcript.json → 句级 SRT")
    ap.add_argument("transcript_json")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    t = json.loads(Path(args.transcript_json).read_text())
    if t.get("schema") not in (None, "asr/transcript/v1"):
        print(f"警告: 未知 schema {t.get('schema')}，仍按 transcript/v1 结构解析", file=sys.stderr)
    # 无词级时间戳时允许 segment 即句子（text-only 产物无时间戳则报错退出）
    words = load_segments(t)
    if not words:
        print("ERROR: transcript 无带时间戳的 segments", file=sys.stderr)
        sys.exit(1)
    sentences = aggregate(words)
    Path(args.out).write_text(to_srt(sentences))
    print(f"SRT: {len(sentences)} 句 → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
