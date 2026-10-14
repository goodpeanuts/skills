#!/usr/bin/env python3
"""build_context_terms.py —— 机械阶段临时词表生成（video-summarizer）

从 distilled.json 的标题/简介/tags/up主/合集名/章节标题中**规则抽取**专有名词
与关键术语，写入 <pkg>/raw/context_terms.txt，供 asr transcribe --context 做
识别偏置（biasing）。纯规则、不调 LLM——机械阶段保持确定性、离线可测。

用法:
  python3 build_context_terms.py <distilled.json> --out <raw/context_terms.txt>

抽取规则（按信噪比排序的来源优先级: title > tags > description > chapters >
uploader > collection）:
  - CJK: 按标点/空白分段后取 2-8 字词块（过滤纯常见虚词块）
  - 拉丁: 全大写缩写（≥2 字母）、驼峰拆分、字母+数字混排（RTX 5090 / GPT-4）
  - 过滤: 纯数字、单字母、URL、长度 >24 的块
去重大小写不敏感；每来源一组、组内按出现序；上限 150 行（防过度偏置）。
"""

from __future__ import annotations  # PEP 604 联合类型注解兼容 Python 3.8/3.9

import argparse
import json
import re
import sys
from pathlib import Path

# 每行一项，总上限——asr --context 硬限 24KB，150 条词表远低于该值；
# 设上限的真正原因是过度偏置会伤害通用识别
MAX_TERMS = 150
# 单项长度上限（超长块多为句子而非术语）
MAX_TERM_LEN = 24

# CJK 分段边界：标点（中西）与空白
CJK_SPLIT_RE = re.compile(r"[\s，。、；：？！,.;:?!·|/\\()\[\]{}「」『』“”\"'…—\-–~《》]+")
# 纯 CJK/混排词块: 以 CJK 或拉丁开头，含 CJK、拉丁、数字
TERM_RE = re.compile(r"^[A-Za-z0-9\u4e00-\u9fff\u3040-\u30ff]+$")
# 全大写拉丁缩写（RTX, LLM, API; 排除纯数字）
ACRONYM_RE = re.compile(r"^[A-Z]{2,}[0-9]*$")
# 字母数字混排（GPT-4 之外的紧密形式: 5090, M4, A16 — 字母开头带数字）
ALNUM_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*[0-9][A-Za-z0-9]*|[A-Z]{2,}[0-9]*")
# 驼峰拆分点
CAMEL_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
# 常见虚词/代词块（CJK 2 字块高噪音，直接排除）
CJK_STOP = {"这个", "那个", "我们", "他们", "什么", "怎么", "可以", "大家", "一个",
             "一起", "还是", "但是", "然后", "所以", "因为", "如果", "就是", "觉得",
             "现在", "今天", "视频", "简介", "链接", "投稿", "转发", "关注", "分享"}


def _latin_candidates(block: str):
    """拉丁/混排块的候选产出：整块（若像缩写或混排）、驼峰拆分、字母数字混排子词。"""
    block = block.strip("._-")
    if not block or len(block) > MAX_TERM_LEN:
        return
    if ACRONYM_RE.match(block):
        yield block
        return
    # 字母数字混排子词（RTX5090 / M4Max / A16）
    for m in ALNUM_TOKEN_RE.finditer(block):
        t = m.group(0)
        if 2 <= len(t) <= MAX_TERM_LEN:
            yield t
    # 驼峰拆分后仍是「首字母大写」的候选（ClaudeCode → Claude, Code 不收）
    parts = CAMEL_RE.split(block)
    if len(parts) > 1:
        for p in parts:
            if len(p) >= 3 and p[0].isupper() and p.isalpha():
                yield p


def extract_terms(text: str):
    """单条文本 → 有序候选词列表（不去重）。先按 CJK/拉丁/数字切分为连续段，
    再分别挖掘：纯 CJK 段 = 词块候选；纯拉丁段 = 缩写/驼峰/混排深挖。"""
    out = []
    # URL/邮箱整体剔除（它们的分段产物是纯噪音）
    text = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", " ", text or "")
    text = re.sub(r"https?://\S+|www\.\S+", " ", text)
    # 跨空格合并「拉丁词+数字」二元组（RTX 5090 / M4 Max）：用不被 CJK_SPLIT
    # 切分的 word joiner（U+2060）保护跨空格形态，产出时替换回空格
    WJ = "⁠"
    # 结尾不带 \b：CJK 与数字之间 Python re 不判词边界（\w 含 CJK），
    # "RTX 5090首" 会因 \b 拒配；数字后跟字母数字截止即可
    text = re.sub(r"\b([A-Z][A-Za-z]*)\s+(\d[A-Za-z0-9]*)", r"\g<1>" + WJ + r"\g<2>", text)
    for block in CJK_SPLIT_RE.split(text):
        block = block.replace(WJ, " ").strip()
        block = block.strip()
        if not block or len(block) > MAX_TERM_LEN:
            continue
        # 切成 CJK 段与拉丁数字段（"5090首发评测" → ["5090", "首发评测"];
        # "Code实战搭建LangChain应用" → ["Code", "实战搭建", "LangChain", "应用"]）
        segs = re.findall(r"[\u4e00-\u9fff\u3040-\u30ff]+|[A-Za-z0-9]+", block)
        latin_buf = []
        for seg in segs:
            if re.match(r"[A-Za-z0-9]", seg):  # 拉丁/数字段
                latin_buf.append(seg)
                continue
            # CJK 段边界：flush 拉丁缓冲后处理 CJK 块
            latin_buf = _flush_latin(latin_buf, out)
            if len(seg) >= 2 and seg not in CJK_STOP:
                out.append(seg)
        _flush_latin(latin_buf, out)
    return out


def _flush_latin(buf: list, out: list):
    """拉丁段缓冲 → 候选词。相邻拉丁+数字段可拼回紧密混排（RTX+5090→RTX 5090），
    但**跳过跨空格的拼合**——切分前块内空格已把 "Claude Code" 分成两个 block，
    各自产出 Claude、Code（高频通用词靠来源优先级与去重自然排序，不硬编码词表）。"""
    if not buf:
        return buf
    joined = "".join(buf)
    if len(joined) <= MAX_TERM_LEN and re.search(r"[A-Za-z]", joined):
        if len(buf) >= 2 and ACRONYM_RE.match(buf[0]) and re.fullmatch(r"[0-9]+", joined[len(buf[0]):]):
            out.append(f"{buf[0]} {joined[len(buf[0]):]}")  # RTX 5090
        elif ACRONYM_RE.match(joined) or (len(joined) <= 10 and not re.search(r"[0-9]", joined)):
            out.append(joined)  # LangChain / APIKey / LLM
        else:
            out.extend(_latin_candidates(joined))
    elif len(joined) > MAX_TERM_LEN:
        out.extend(_latin_candidates(buf[0]))
    return []


def build_terms(distilled: dict) -> list:
    """distilled.json → 词表（有序去重、截断）。来源优先级即插入顺序。"""
    d = distilled
    sources = [
        d.get("title") or "",
        " ".join(str(t) for t in (d.get("tags") or [])),
        d.get("description") or "",
        " ".join(c.get("title", "") for c in (d.get("chapters") or [])),
        d.get("uploader") or "",
        (d.get("collection") or {}).get("title", ""),
    ]
    seen, terms = set(), []
    for src in sources:
        for t in extract_terms(src):
            key = t.lower()
            if key not in seen:
                seen.add(key)
                terms.append(t)
                if len(terms) >= MAX_TERMS:
                    return terms
    return terms


def main():
    ap = argparse.ArgumentParser(description="机械阶段临时词表生成")
    ap.add_argument("distilled_json")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    d = json.loads(Path(args.distilled_json).read_text())
    if d.get("is_playlist"):
        Path(args.out).write_text("")
        return
    terms = build_terms(d)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("".join(t + "\n" for t in terms))
    print(f"context terms: {len(terms)} 项 → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
