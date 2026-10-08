#!/usr/bin/env python3
"""pipeline_meta.py —— 机械阶段元数据引擎（video-summarizer · 全平台能力模型）

子命令:
  distill <info.json> --out <distilled.json> [--sub-pref "zh-Hans,en"]
      蒸馏 yt-dlp -J 全量元数据：平台归一化（generic 消歧）、字幕候选与选优、
      章节（含 end_time）、所属列表 collection（采集时入口）、目录名消毒
  finalize <distilled.json> --folder <pkg> --video-file V --audio-file A
      --subtitle-lang L --subtitle-source S --needs-whisper 0|1
      --has-danmaku 0|1 --has-comments 0|1 --frames-max N --frames-extracted N
      [--uploader-id ID] [--upload-date D] [--account NAME]
      写 <pkg>/raw/meta.json，并向 stdout 打印唯一一行交接 JSON（认知阶段契约）
  cookie-platform <URL>
      查 platforms.json：URL 的 **host** 命中某平台 cookie.url_patterns 则打印平台键
  cookie-on-failure <URL>
      打印命中平台的 cookie.on_failure 策略（die|degrade，缺省 die）
  capability <platform> <key>
      查 platforms.json：打印平台能力位取值（danmaku/comments 等），未配置打印空
  collection_lookup <platform> <video_id> [--distilled <file>] [--payload-file <f>]
      合集归属反查（platforms.json season_lookup 能力位）：单视频 URL 采集时
      yt-dlp -J 无 playlist 字段（入口语义缺席），B 站经官方 view API 反查
      ugc_season 回填 distilled 的 collection。内部入口优先（已有值不覆盖）、
      全部缺席路径静默退 0（能力位自然缺席）；--payload-file 为离线注入口（单测）
  sanitize <name>
      文件名消毒（单测/调试用）

字幕选择策略: 偏好 [zh-Hans, zh, zh-Hant, <视频原语言>, en]（--sub-pref 整体覆盖）。
注意这是「中文读者」默认偏好而非中立策略；候选分三级 manual（人工/CC）> ai-*
（平台 AI 字幕）> auto（自动生成），ai-X 与 X 等价匹配（ai-zh ≈ zh）。
subtitle_source 枚举: manual | auto | whisper | none。

平台键规则: extractor_key 小写归一化；generic 提取器（yt-dlp 不专门支持的网站共用）
消歧为 generic_< webpage_url host 的 sha1 前 8 位>，避免不同网站 id 碰撞导致
registry 误判 SKIP / 归档目录互撞。cookie 文件名与 registry 键均使用该平台键。
"""

from __future__ import annotations  # PEP 604 联合类型注解兼容 Python 3.8/3.9

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from fnmatch import fnmatch
from pathlib import Path
from urllib.parse import urlencode, urlparse

# Windows/NTFS 非法字符 + 控制字符，统一映射为 _
ILLEGAL_RE = re.compile(r"[\x00-\x1f<>:\"/\\|?*]")
# Windows 保留设备名（不计扩展名、大小写不敏感）
RESERVED_RE = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$", re.IGNORECASE)
DEFAULT_PREF = ["zh-Hans", "zh", "zh-Hant", "en"]
# 弹幕/直播聊天是字幕字典里的伪语言，不参与选优
SUB_LANG_SKIP = {"danmaku", "live_chat"}
CONFIG_PATH = Path(__file__).parent / "platforms.json"


def load_platforms() -> dict:
    """读 platforms.json 平台能力表（去掉 _meta 键）。表缺失时按空表处理：
    所有平台走默认通用链路（免 Cookie、native 评论、无弹幕）。"""
    if not CONFIG_PATH.exists():
        return {}
    try:
        cfg = json.loads(CONFIG_PATH.read_text())
    except json.JSONDecodeError as e:
        # 损坏时按空表降级（全部能力位走通用链路），但必须让用户知道能力在蒸发
        print(f"警告: {CONFIG_PATH.name} 损坏（{e}）——平台能力位全部退化为通用链路，请修复配置",
              file=sys.stderr)
        return {}
    cfg.pop("_meta", None)
    return cfg


def normalize_platform(extractor_key: str, webpage_url: str) -> str:
    """平台键归一化。generic 提取器按网页 host 消歧（hostname 已小写、剥离
    端口与 www. 前缀——Cookie 是域作用域，端口不应参与键值）。"""
    plat = (extractor_key or "generic").lower()
    if plat == "generic":
        return f"generic_{hashlib.sha1(extract_host(webpage_url).encode()).hexdigest()[:8]}"
    return plat


def extract_host(webpage_url: str) -> str:
    host = (urlparse(webpage_url or "").hostname or "unknown")
    host = host.lower()
    if host.startswith("www."):
        host = host[4:]
    return host


def detect_media_kind(info: dict) -> str:
    """判断输入是视频还是纯音频（播客等 audio-only 站点）：video|audio。"""
    vc = info.get("vcodec")
    if vc:
        return "audio" if vc == "none" else "video"
    vcs = [f.get("vcodec") for f in (info.get("formats") or [])]
    if vcs and all(v == "none" for v in vcs):
        return "audio"
    return "video"


def extract_collection(info: dict, vid: str) -> dict | None:
    """所属列表（采集时入口）：取 -J 的 playlist_id/playlist_title——合集、
    播放列表、收藏夹入口都会带上（配合 --no-playlist，字段保留入口上下文）。
    playlist_id 与视频 ID 相同（如 B 站多 P：其"列表"就是该视频自身）不算所属列表，
    返回 None。默认 SKIP 语义下同视频只记首次采集的入口；--force 重采后
    finish 覆盖为最新入口。单视频 URL 入口缺席时，season_lookup 能力位平台
    会反查归属合集回填 collection（见 collection_lookup）——入口值优先，不被覆盖。"""
    pid = info.get("playlist_id")
    if not pid or str(pid) == str(vid):
        return None
    return {"id": str(pid), "title": info.get("playlist_title") or str(pid)}


def parse_ugc_season(payload: dict) -> dict | None:
    """B 站 view API 响应 → 归属合集 collection。纯函数（离线可测）：
    响应非 ok（code!=0）、data.ugc_season 缺席（视频未加入合集）→ None。"""
    if not isinstance(payload, dict) or payload.get("code") != 0:
        return None
    season = ((payload.get("data") or {}).get("ugc_season")) or None
    if not isinstance(season, dict) or not season.get("id"):
        return None
    return {"id": str(season["id"]), "title": season.get("title") or str(season["id"])}


def _config_ua() -> str:
    """读 platforms.json _meta.ua（load_platforms 会丢弃 _meta，这里单独读），
    表缺失时退回通用 Chrome UA。"""
    try:
        cfg = json.loads(CONFIG_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return "Mozilla/5.0"
    return ((cfg.get("_meta") or {}).get("ua")) or "Mozilla/5.0"


def fetch_season_collection(vid: str, timeout: float = 10):
    """拉取并解析 B 站归属合集。返回 (collection, err)：err 非空 = 网络/HTTP
    失败；err 空 collection 为 None = 视频不属于合集。"""
    from urllib.request import Request, urlopen
    api = "https://api.bilibili.com/x/web-interface/view?" + urlencode({"bvid": vid})
    try:
        req = Request(api, headers={"User-Agent": _config_ua(),
                                    "Referer": "https://www.bilibili.com/"})
        with urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:  # 网络/风控/超时一律降级，不阻塞机械阶段
        return None, str(e)
    return parse_ugc_season(payload), ""


def cmd_collection_lookup(platform: str, vid: str, distilled_path: str,
                          payload_file: str, timeout: float):
    """合集归属反查回填（season_lookup 能力位）。缺席路径全部静默退 0：
    平台未声明该能力 / id 非 B 站 bvid / 入口 collection 已有值（入口优先，
    不发请求不覆盖）/ API 失败或无合集（stderr 告警）。成功 → 原子 merge 进
    distilled.json。--payload-file 注入 API 响应（离线单测路径，跳过网络）。"""
    if (load_platforms().get(platform) or {}).get("season_lookup") != "bilibili_ugc":
        return
    if not vid.startswith("BV"):  # view API 仅认 bvid（au/ep/ss 等其他 id 静默跳过）
        return
    if distilled_path:
        d = json.loads(Path(distilled_path).read_text())
        if d.get("collection"):  # 采集时入口优先：有值即归属已定，不覆盖
            return
    if payload_file:
        coll = parse_ugc_season(json.loads(Path(payload_file).read_text()))
    else:
        coll, err = fetch_season_collection(vid, timeout)
        if err:
            print(f"警告: 合集反查失败（collection 保持缺席）: {err}", file=sys.stderr)
            return
    if not coll:
        return
    if distilled_path:
        dp = Path(distilled_path)
        d["collection"] = coll
        tmp = dp.parent / (dp.name + ".tmp")
        tmp.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
        tmp.replace(dp)
    print(f"合集反查: {coll['title']} ({coll['id']}) → collection", file=sys.stderr)


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
    url = info.get("webpage_url") or ""
    sel = select_subtitle(info, sub_pref)
    distilled = {
        "is_playlist": False,
        "platform": normalize_platform(info.get("extractor_key"), url),
        "extractor": info.get("extractor_key") or "",
        "host": extract_host(url),
        "media_kind": detect_media_kind(info),
        "id": vid,
        "title": title,
        "url": url,
        "duration": int(info.get("duration") or 0),
        "language": info.get("language"),
        "upload_date": info.get("upload_date"),
        "uploader": info.get("uploader") or info.get("channel") or info.get("uploader_id") or "",
        "uploader_id": info.get("uploader_id") or info.get("channel_id"),
        "collection": extract_collection(info, vid),
        "chapters": [
            {"start_time": c.get("start_time", 0), "end_time": c.get("end_time"),
             "title": c.get("title", "")}
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
                 has_danmaku: int, has_comments: int, frames_max: int,
                 frames_extracted: int, uploader_id: str, upload_date: str,
                 account: str):
    d = json.loads(Path(distilled_path).read_text())
    meta = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "extractor": d["extractor"],
        "platform": d["platform"],
        "host": d.get("host", ""),
        "media_kind": d.get("media_kind", "video"),
        "id": d["id"],
        "url": d["url"],
        "title": d["title"],
        "duration": d["duration"],
        "language": d["language"],
        "upload_date": d.get("upload_date"),
        "uploader": d["uploader"],
        "uploader_id": d.get("uploader_id"),
        # 所属列表：采集时入口（合集/播放列表/收藏夹）；单视频入口缺席时由
        # season_lookup 能力位反查归属合集回填（B 站 ugc_season）
        "collection": d.get("collection"),
        # 认知阶段若 whisper 兜底，finish 会回写终态到这里（meta.json 为字幕来源唯一事实源）
        "subtitle": {
            "selected": subtitle_lang,
            "source": subtitle_source,
            "candidates": {"manual": d["subs_manual"], "auto": d["subs_auto"]},
        },
        "chapters_count": len(d["chapters"]),
        "files": {"video": video_file, "audio": audio_file},
        "frames": {"max": frames_max, "extracted": frames_extracted},
        # 机械阶段终态（会话结束后判断归档采集完整度的依据）
        "needs_whisper": bool(needs_whisper),
        "capabilities": {"danmaku": bool(has_danmaku), "comments": bool(has_comments)},
        "account": account or None,
    }
    # meta.json 落 raw/（与字幕/媒体同层）；finalize 自建 raw 目录，单测/手工调用无需预建
    meta_path = Path(folder, "raw", "meta.json")
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")

    summary = {
        "folder": folder,
        "id": d["id"],
        "platform": d["platform"],
        "host": d.get("host", ""),
        "media_kind": d.get("media_kind", "video"),
        "title": d["title"],
        "url": d["url"],
        "duration": d["duration"],
        "language": d["language"],
        "upload_date": d.get("upload_date"),
        "uploader": d["uploader"],
        "uploader_id": d.get("uploader_id"),
        "collection_id": (d.get("collection") or {}).get("id", ""),
        "collection_title": (d.get("collection") or {}).get("title", ""),
        "account": account or "",
        "video_file": video_file,
        "audio_file": audio_file,
        "subtitle_lang": subtitle_lang,
        "subtitle_source": subtitle_source,
        "needs_whisper": needs_whisper,
        "has_danmaku": has_danmaku,
        "has_comments": has_comments,
        "chapters": len(d["chapters"]),
        # 认知阶段收尾闸门提醒: 认知产出后必须 finish(回写 registry)+verify(验收)
        "must_run_finish": True,
    }
    print(json.dumps(summary, ensure_ascii=False))


def _match_cookie_platform(url: str) -> str | None:
    """按 URL 的 host 做 glob 匹配（非子串匹配整条 URL——后者会被
    evil.com/?ref=bilibili.com 之类伪装命中）。返回首个命中平台的键。"""
    host = (urlparse(url or "").hostname or "").lower()
    for plat, spec in load_platforms().items():
        for pat in ((spec or {}).get("cookie") or {}).get("url_patterns") or []:
            if fnmatch(host, pat):
                return plat
    return None


def cmd_cookie_platform(url: str):
    plat = _match_cookie_platform(url)
    if plat:
        print(plat)


def cmd_cookie_on_failure(url: str):
    """打印命中平台的 cookie.on_failure 策略（die|degrade，缺省 die）。"""
    plat = _match_cookie_platform(url)
    if plat:
        cfg = (load_platforms().get(plat) or {}).get("cookie") or {}
        print(cfg.get("on_failure") or "die")


def cmd_capability(platform: str, key: str):
    v = (load_platforms().get(platform) or {}).get(key)
    if v:
        print(v)


def main():
    parser = argparse.ArgumentParser(description="机械阶段元数据引擎")
    cmd = parser.add_subparsers(dest="cmd", required=True)

    p1 = cmd.add_parser("distill", help="蒸馏 yt-dlp -J 元数据")
    p1.add_argument("info_json")
    p1.add_argument("--out", required=True)
    p1.add_argument("--sub-pref", default="")

    p2 = cmd.add_parser("finalize", help="写 raw/meta.json 并输出交接 JSON")
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
    p2.add_argument("--frames-extracted", type=int, default=0)
    p2.add_argument("--uploader-id", default="")
    p2.add_argument("--upload-date", default="")
    p2.add_argument("--account", default="")

    p3 = cmd.add_parser("sanitize", help="文件名消毒（单测/调试）")
    p3.add_argument("name")

    p4 = cmd.add_parser("cookie-platform", help="URL host 命中的 cookie 配置平台键")
    p4.add_argument("url")

    p5 = cmd.add_parser("cookie-on-failure", help="命中平台的 cookie 失败策略 die|degrade")
    p5.add_argument("url")

    p6 = cmd.add_parser("capability", help="平台能力位取值")
    p6.add_argument("platform")
    p6.add_argument("key")

    p7 = cmd.add_parser("collection_lookup", help="合集归属反查回填 collection")
    p7.add_argument("platform")
    p7.add_argument("video_id")
    p7.add_argument("--distilled", default="", help="merge 目标 distilled.json")
    p7.add_argument("--payload-file", default="", help="注入 API 响应 JSON（离线单测）")
    p7.add_argument("--timeout", type=float, default=10)

    args = parser.parse_args()
    if args.cmd == "distill":
        cmd_distill(args.info_json, args.out, args.sub_pref)
    elif args.cmd == "finalize":
        cmd_finalize(args.distilled_json, args.folder, args.video_file, args.audio_file,
                     args.subtitle_lang, args.subtitle_source, args.needs_whisper,
                     args.has_danmaku, args.has_comments, args.frames_max,
                     args.frames_extracted, args.uploader_id, args.upload_date,
                     args.account)
    elif args.cmd == "sanitize":
        print(sanitize_component(args.name))
    elif args.cmd == "cookie-platform":
        cmd_cookie_platform(args.url)
    elif args.cmd == "cookie-on-failure":
        cmd_cookie_on_failure(args.url)
    elif args.cmd == "capability":
        cmd_capability(args.platform, args.key)
    elif args.cmd == "collection_lookup":
        cmd_collection_lookup(args.platform, args.video_id, args.distilled,
                              args.payload_file, args.timeout)


if __name__ == "__main__":
    main()
