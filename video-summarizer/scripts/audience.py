#!/usr/bin/env python3
"""audience.py —— 观众反馈采集与消化（video-summarizer · 能力组件）

子命令（两分支输出同一 audience.json schema）:
  bili    --url <URL> [--danmaku-xml <PATH>] --out-dir <DIR> [--duration <sec>]
          B 站能力位: v2/reply 热评 API（ps=20 两页凑 top30、楼中楼≤2、作者回复
          标注 is_up）+ 弹幕 XML 解析（10s 窗口不重叠峰值 Top3、高频文本 Top10）
  generic --info-json <PATH> --out-dir <DIR> [--duration <sec>]
          通用能力位: 消化 yt-dlp --write-comments 产出的 info.json
          （YouTube 等平台原生支持；按赞数取 top30，回复按 parent 关联）

输出: <out-dir>/audience.json（Git 追踪）。
bili 分支同时落 <out-dir>/comments.info.json（原始侧账，Git 忽略）；
generic 分支的 comments.info.json 由 pipeline 调 yt-dlp 落盘，本脚本只读。

schema: {"video": {..., "author": {"name","id"}}, "generated_at": ...,
         "danmaku": null | {...}, "comments": {"total","sampled","up_mid","top":[...]}}
非弹幕平台 danmaku 为 null；summary 模板的观众反馈章节据 top 内容自行判断有无信号。
"""

import argparse
import json
import re
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/132.0 Safari/537.36")
TOP_N = 30       # 热评采样条数
SUB_REPLY_N = 2  # 每条热评携带的楼中楼条数
PEAK_N = 3       # 弹幕峰值窗口数


class AudienceError(Exception):
    pass


def http_json(url: str, sessdata: str = "") -> dict:
    headers = {"User-Agent": UA, "Referer": "https://www.bilibili.com/"}
    if sessdata:
        headers["Cookie"] = f"SESSDATA={sessdata}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def load_sessdata() -> str:
    p = Path("cache/cookies.json")
    try:
        return json.loads(p.read_text()).get("bilibili", {}).get("cookies", {}).get("SESSDATA", "")
    except (OSError, json.JSONDecodeError):
        return ""


# ---------- B 站: 弹幕 ----------

def parse_danmaku(xml_path: str, duration_s: float) -> dict | None:
    if not xml_path or not Path(xml_path).exists():
        return None
    root = ET.parse(xml_path).getroot()
    dans = []
    for d in root.iter("d"):
        p = (d.get("p") or "").split(",")
        if d.text and p:
            try:
                dans.append((float(p[0]), d.text.strip()))
            except ValueError:
                continue
    if not dans:
        return None
    dans.sort(key=lambda x: x[0])
    duration_s = duration_s or (dans[-1][0] + 5)
    # 峰值: 5s 步进扫描 10s 窗口，按弹幕数排序后贪心取互不重叠 Top3
    windows = []
    for start in range(0, int(max(duration_s, 1)), 5):
        cnt = sum(1 for t, _ in dans if start <= t < start + 10)
        windows.append((cnt, start))
    windows.sort(reverse=True)
    chosen = []
    for cnt, start in windows:
        if len(chosen) >= PEAK_N:
            break
        if any(abs(start - c["t"]) < 10 for c in chosen):
            continue
        texts = Counter(txt for t, txt in dans if start <= t < start + 10)
        chosen.append({"t": start, "window_s": 10, "count": cnt,
                       "top_texts": [t for t, _ in texts.most_common(5)]})
    top_repeated = [{"text": t, "count": c} for t, c in
                    Counter(txt for _, txt in dans).most_common(10) if c >= 2]
    return {"total": len(dans), "duration_s": round(duration_s, 1),
            "density_per_min": round(len(dans) / max(duration_s / 60, 0.1), 1),
            "peaks": chosen, "top_repeated": top_repeated}


# ---------- B 站: 评论 ----------

def fetch_bili_comments(bvid: str, sessdata: str) -> tuple[dict, list]:
    view = http_json(f"https://api.bilibili.com/x/web-interface/view?bvid={bvid}", sessdata)["data"]
    aid, up_mid, up_name = view["aid"], view["owner"]["mid"], view["owner"]["name"]
    replies, total = [], 0
    for pn in (1, 2):  # 接口单页上限 ps=20，两页凑热评池
        d = http_json(f"https://api.bilibili.com/x/v2/reply?type=1&oid={aid}"
                      f"&sort=1&ps=20&pn={pn}", sessdata)
        data = d.get("data", {})
        total = data.get("page", {}).get("acount", total)
        replies.extend(data.get("replies") or [])
        if not data.get("replies"):
            break
    top = []
    for r in replies[:TOP_N]:
        subs = (r.get("replies") or [])[:SUB_REPLY_N]
        top.append({
            "like": r["like"], "user": r["member"]["uname"], "text": r["content"]["message"],
            "is_up": r["member"]["mid"] == up_mid, "rcount": r.get("rcount", 0),
            "replies": [{"like": s["like"], "user": s["member"]["uname"],
                         "is_up": s["member"]["mid"] == up_mid,
                         "text": s["content"]["message"]} for s in subs],
        })
    meta = {"aid": aid, "up_mid": up_mid, "up_name": up_name,
            "total": total, "sampled": len(top)}
    return meta, top


def cmd_bili(url: str, danmaku_xml: str, out_dir: str, duration: float):
    m = re.search(r"(BV[0-9A-Za-z]{10})", url)
    if not m:
        raise AudienceError(f"无法从 URL 解析 BV 号: {url}")
    sessdata = load_sessdata()
    meta, top = fetch_bili_comments(m.group(1), sessdata)
    danmaku = parse_danmaku(danmaku_xml, duration)
    audience = {
        "video": {"id": m.group(1), "title": None,
                  "author": {"name": meta["up_name"], "id": meta["up_mid"]},
                  "duration": duration},
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "danmaku": danmaku,
        "comments": {"total": meta["total"], "sampled": meta["sampled"],
                     "up_mid": meta["up_mid"], "top": top},
    }
    outdir = Path(out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "audience.json").write_text(json.dumps(audience, ensure_ascii=False, indent=2) + "\n")
    (outdir / "comments.info.json").write_text(json.dumps(
        {"aid": meta["aid"], "total": meta["total"], "replies": top},
        ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"ok": True, "danmaku_total": danmaku["total"] if danmaku else 0,
                      "comments_total": meta["total"], "comments_sampled": meta["sampled"]},
                     ensure_ascii=False))


# ---------- 通用: yt-dlp --write-comments 消化 ----------

def cmd_generic(info_json: str, out_dir: str, duration: float,
                uploader: str, uploader_id: str):
    info = json.loads(Path(info_json).read_text())
    comments = info.get("comments") or []

    def is_author(c: dict) -> bool:
        if uploader_id and c.get("author_id") and str(c["author_id"]) == str(uploader_id):
            return True
        return bool(uploader and c.get("author") == uploader)

    tops = [c for c in comments if not c.get("parent")]
    tops.sort(key=lambda c: c.get("like_count") or 0, reverse=True)
    top = []
    for c in tops[:TOP_N]:
        replies = [r for r in comments if r.get("parent") == c.get("id")]
        replies.sort(key=lambda r: r.get("like_count") or 0, reverse=True)
        top.append({
            "like": c.get("like_count") or 0,
            "user": c.get("author") or "",
            "text": (c.get("text") or "").strip(),
            "is_up": is_author(c), "rcount": len(replies),
            "replies": [{"like": r.get("like_count") or 0, "user": r.get("author") or "",
                         "is_up": is_author(r), "text": (r.get("text") or "").strip()}
                        for r in replies[:SUB_REPLY_N]],
        })
    audience = {
        "video": {"id": info.get("id"), "title": info.get("title"),
                  "author": {"name": uploader or info.get("channel") or info.get("uploader"),
                             "id": uploader_id or info.get("uploader_id") or info.get("channel_id")},
                  "duration": duration or info.get("duration") or 0},
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "danmaku": None,
        "comments": {"total": len(comments), "sampled": len(top),
                     "up_mid": None, "top": top},
    }
    outdir = Path(out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "audience.json").write_text(json.dumps(audience, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"ok": True, "comments_total": len(comments),
                      "comments_sampled": len(top)}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="观众反馈采集与消化")
    cmd = parser.add_subparsers(dest="cmd", required=True)
    p1 = cmd.add_parser("bili")
    p1.add_argument("--url", required=True)
    p1.add_argument("--danmaku-xml", default="")
    p1.add_argument("--out-dir", required=True)
    p1.add_argument("--duration", type=float, default=0)
    p2 = cmd.add_parser("generic")
    p2.add_argument("--info-json", required=True)
    p2.add_argument("--out-dir", required=True)
    p2.add_argument("--duration", type=float, default=0)
    p2.add_argument("--uploader", default="")
    p2.add_argument("--uploader-id", default="")
    args = parser.parse_args()
    try:
        if args.cmd == "bili":
            cmd_bili(args.url, args.danmaku_xml, args.out_dir, args.duration)
        else:
            cmd_generic(args.info_json, args.out_dir, args.duration,
                        args.uploader, args.uploader_id)
    except AudienceError as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
