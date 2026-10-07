#!/usr/bin/env python3
"""pipeline_meta.py —— 机械阶段元数据引擎（video-summarizer · 全平台能力模型）

子命令:
  distill <info.json> --out <distilled.json> [--sub-pref "zh-Hans,en"]
      蒸馏 yt-dlp -J 全量元数据：平台归一化、字幕候选与选优、章节、目录名消毒
  finalize <distilled.json> --folder <pkg> --video-file V --audio-file A
      --subtitle-lang L --subtitle-source S --needs-whisper 0|1
      --has-danmaku 0|1 --has-comments 0|1 --frames-max N
      写 <pkg>/meta.json，并向 stdout 打印唯一一行交接 JSON（认知阶段契约）
  sanitize <name>
      文件名消毒（单测/调试用）

字幕选择策略: 偏好 [zh-Hans, zh, zh-Hant, <视频原语言>, en]（--sub-pref 整体覆盖），
候选分三级 manual（人工/CC）> ai-*（平台 AI 字幕）> auto（自动生成），
ai-X 与 X 等价匹配（ai-zh ≈ zh）。subtitle_source 枚举: manual | auto | whisper | none。
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# Windows/NTFS 非法字符 + 控制字符，统一映射为 _
ILLEGAL_RE = re.compile(r"[\x00-\x1f<>:\"/\\|?*]")
# Windows 保留设备名（不计扩展名、大小写不敏感）
RESERVED_RE = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$", re.IGNORECASE)
DEFAULT_PREF = ["zh-Hans", "zh", "zh-Hant", "en"]
# 弹幕/直播聊天是字幕字典里的伪语言，不参与选优
SUB_LANG_SKIP = {"danmaku", "live_chat"}


def sanitize_component(name: str, max_len: int = 40) -> str:
    """跨平台文件名消毒（以最严格的 Windows/NTFS 规则为基线）：
    非法字符→'_'（占位符）、空白折叠为单空格、占位 _ 吸收两侧空白充当词连接符
    （'AC / DC'→'AC_DC'）、首尾占位与空白剥离、结尾点剥离、保留设备名前缀 '_'、
    截断至 max_len（unicode 计 1，截断后再剥结尾点）、
    空结果兜底 'untitled'；unicode 合法字符（中日文/emoji）原样保留。"""
    s = ILLEGAL_RE.sub("_", name or "")
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"_+", "_", s)
    s = re.sub(r"\s*_\s*", "_", s)
    s = re.sub(r"_+", "_", s)
    s = s.strip("_ ").rstrip(".")
    s = s[:max_len].rstrip(".")
    if not s.strip("_ ."):
        return "untitled"
    if RESERVED_RE.match(s):
        s = "_" + s
    return s


def lang_matches(candidate: str, pref: str) -> bool:
    if candidate == pref or candidate.startswith(pref + "-"):
        return True
    if candidate == "ai-" + pref or candidate.startswith("ai-" + pref + "-"):
        return True
    return False


def select_subtitle(info: dict, pref_override: str) -> dict:
    manual = [l for l in (info.get("subtitles") or {}) if l not in SUB_LANG_SKIP]
    auto = [l for l in (info.get("automatic_captions") or {}) if l not in SUB_LANG_SKIP]

    if pref_override:
        prefs = [p.strip() for p in pref_override.split(",") if p.strip()]
    else:
        prefs = list(DEFAULT_PREF)
        lang = info.get("language")
        if lang:
            prefs = prefs[:3] + [lang] + prefs[3:]  # 原语言插在 zh 系之后、en 之前
        seen, deduped = set(), []
        for p in prefs:
            if p not in seen:
                seen.add(p)
                deduped.append(p)
        prefs = deduped

    tiers = [
        ("manual", "subs", [l for l in manual if not l.startswith("ai-")]),
        ("manual", "subs", [l for l in manual if l.startswith("ai-")]),
        ("auto", "auto", auto),
    ]
    for pref in prefs:
        for source, kind, langs in tiers:
            for l in langs:
                if lang_matches(l, pref):
                    return {"lang": l, "source": source, "kind": kind}
    return {"lang": "none", "source": "none", "kind": None}


def cmd_distill(info_path: str, out_path: str, sub_pref: str):
    info = json.loads(Path(info_path).read_text())

    if info.get("_type") == "playlist" or "entries" in info:
        Path(out_path).write_text(json.dumps({"is_playlist": True}, ensure_ascii=False))
        return

    vid = str(info.get("id") or "unknown")
    title = info.get("title") or ""
    sel = select_subtitle(info, sub_pref)
    distilled = {
        "is_playlist": False,
        "platform": (info.get("extractor_key") or "generic").lower(),
        "extractor": info.get("extractor_key") or "",
        "id": vid,
        "title": title,
        "url": info.get("webpage_url") or "",
        "duration": int(info.get("duration") or 0),
        "language": info.get("language"),
        "uploader": info.get("uploader") or info.get("channel") or info.get("uploader_id") or "",
        "uploader_id": info.get("uploader_id") or info.get("channel_id"),
        "chapters": [
            {"start_time": c.get("start_time", 0), "title": c.get("title", "")}
            for c in (info.get("chapters") or [])
        ],
        "subs_manual": [l for l in (info.get("subtitles") or {}) if l not in SUB_LANG_SKIP],
        "subs_auto": [l for l in (info.get("automatic_captions") or {}) if l not in SUB_LANG_SKIP],
        "subtitle": sel,
        "safe_dir": f"{sanitize_component(vid, 60)}_{sanitize_component(title)}",
    }
    Path(out_path).write_text(json.dumps(distilled, ensure_ascii=False, indent=2) + "\n")


def cmd_finalize(distilled_path: str, folder: str, video_file: str, audio_file: str,
                 subtitle_lang: str, subtitle_source: str, needs_whisper: int,
                 has_danmaku: int, has_comments: int, frames_max: int):
    d = json.loads(Path(distilled_path).read_text())
    meta = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "extractor": d["extractor"],
        "platform": d["platform"],
        "id": d["id"],
        "url": d["url"],
        "title": d["title"],
        "duration": d["duration"],
        "language": d["language"],
        "uploader": d["uploader"],
        "subtitle": {
            "selected": subtitle_lang,
            "source": subtitle_source,
            "candidates": {"manual": d["subs_manual"], "auto": d["subs_auto"]},
        },
        "chapters_count": len(d["chapters"]),
        "files": {"video": video_file, "audio": audio_file},
        "frames": {"max": frames_max},
    }
    Path(folder, "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")

    summary = {
        "folder": folder,
        "id": d["id"],
        "platform": d["platform"],
        "title": d["title"],
        "url": d["url"],
        "duration": d["duration"],
        "language": d["language"],
        "uploader": d["uploader"],
        "video_file": video_file,
        "audio_file": audio_file,
        "subtitle_lang": subtitle_lang,
        "subtitle_source": subtitle_source,
        "needs_whisper": needs_whisper,
        "has_danmaku": has_danmaku,
        "has_comments": has_comments,
        "chapters": len(d["chapters"]),
    }
    print(json.dumps(summary, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="机械阶段元数据引擎")
    cmd = parser.add_subparsers(dest="cmd", required=True)

    p1 = cmd.add_parser("distill", help="蒸馏 yt-dlp -J 元数据")
    p1.add_argument("info_json")
    p1.add_argument("--out", required=True)
    p1.add_argument("--sub-pref", default="")

    p2 = cmd.add_parser("finalize", help="写 meta.json 并输出交接 JSON")
    p2.add_argument("distilled_json")
    p2.add_argument("--folder", required=True)
    p2.add_argument("--video-file", required=True)
    p2.add_argument("--audio-file", default="")
    p2.add_argument("--subtitle-lang", default="none")
    p2.add_argument("--subtitle-source", default="none")
    p2.add_argument("--needs-whisper", type=int, default=0)
    p2.add_argument("--has-danmaku", type=int, default=0)
    p2.add_argument("--has-comments", type=int, default=0)
    p2.add_argument("--frames-max", type=int, default=0)

    p3 = cmd.add_parser("sanitize", help="文件名消毒（单测/调试）")
    p3.add_argument("name")

    args = parser.parse_args()
    if args.cmd == "distill":
        cmd_distill(args.info_json, args.out, args.sub_pref)
    elif args.cmd == "finalize":
        cmd_finalize(args.distilled_json, args.folder, args.video_file, args.audio_file,
                     args.subtitle_lang, args.subtitle_source, args.needs_whisper,
                     args.has_danmaku, args.has_comments, args.frames_max)
    else:
        print(sanitize_component(args.name))


if __name__ == "__main__":
    main()
