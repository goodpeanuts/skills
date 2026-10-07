#!/usr/bin/env python3
"""
fetch_bili_meta.py —— B 站元数据聚合器（video-summarizer Pipeline 机械阶段组件）

子命令:
  ensure-cookies --url <URL>          确保 cache/cookies.json 存在且有效（必要时从 Chrome 导出）
  probe-subs    --url <URL>           探测字幕清单并按 CC(zh-Hans/zh) > ai-zh > ai-en 选优
  audience      --url <URL> --danmaku-xml <PATH> --out-dir <DIR> [--duration <sec>]
                                       解析弹幕 + 拉取热评 → evidence/audience.json + comments.json

所有子命令向 stdout 输出 JSON，供 pipeline_prepare.sh 消费。
Cookie 缓存: ./cache/cookies.json（平台命名空间，唯一事实源）；
yt-dlp 用 Netscape 派生文件 ./cache/_bilibili.cookies.txt（可随时重建）。
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/132.0 Safari/537.36")
WANTED_COOKIES = ("SESSDATA", "buvid3", "buvid4", "bili_jct")
COOKIE_JSON = Path("cache/cookies.json")
COOKIE_TXT = Path("cache/_bilibili.cookies.txt")


class BiliError(Exception):
    pass


def out(payload: dict):
    print(json.dumps(payload, ensure_ascii=False))


def http_json(url: str, sessdata: str = "") -> dict:
    headers = {"User-Agent": UA, "Referer": "https://www.bilibili.com/"}
    if sessdata:
        headers["Cookie"] = f"SESSDATA={sessdata}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


# ---------- Cookie ----------

def load_entry() -> dict | None:
    if not COOKIE_JSON.exists():
        return None
    try:
        entry = json.loads(COOKIE_JSON.read_text()).get("bilibili", {})
        return entry if entry.get("cookies", {}).get("SESSDATA") else None
    except (json.JSONDecodeError, OSError):
        return None


def write_netscape(entry: dict):
    COOKIE_TXT.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# Netscape HTTP Cookie File (derived from cache/cookies.json)"]
    for k, v in entry["cookies"].items():
        lines.append(f".bilibili.com\tTRUE\t/\tTRUE\t2147483647\t{k}\t{v}")
    COOKIE_TXT.write_text("\n".join(lines) + "\n")


def check_login(sessdata: str) -> str | None:
    try:
        d = http_json("https://api.bilibili.com/x/web-interface/nav", sessdata)
        return d.get("data", {}).get("uname") if d.get("data", {}).get("isLogin") else None
    except Exception:
        return None


def ingest_netscape_to_json() -> dict:
    """把 yt-dlp 导出的 Netscape txt 中 B 站关键 Cookie 收进 JSON（唯一事实源）"""
    entry = {"cookies": {}}
    for line in COOKIE_TXT.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split("\t")
        if len(f) >= 7 and "bilibili.com" in f[0] and f[5] in WANTED_COOKIES:
            entry["cookies"][f[5]] = f[6].strip()
    if "SESSDATA" not in entry["cookies"]:
        raise BiliError("Chrome 导出成功但未包含 B 站 SESSDATA（Chrome 是否登录了 B 站？）")
    account = check_login(entry["cookies"]["SESSDATA"])
    if not account:
        raise BiliError("导出的 SESSDATA 校验失败（未登录或已失效）")
    entry.update(account=account, source="chrome",
                 exported_at=datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"))
    COOKIE_JSON.write_text(json.dumps(
        {"_meta": {"version": 1, "note": "平台命名空间隔离，新增平台加顶层键"},
         "bilibili": entry}, ensure_ascii=False, indent=2))
    return entry


def cmd_ensure_cookies(url: str):
    entry = load_entry()
    if entry:
        account = check_login(entry["cookies"]["SESSDATA"])
        if account:
            write_netscape(entry)
            out({"ok": True, "account": account, "source": "cache"})
            return
    COOKIE_TXT.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["yt-dlp", "--cookies-from-browser", "chrome", "--cookies", str(COOKIE_TXT),
         "--skip-download", url], capture_output=True, text=True)
    if r.returncode != 0 or not COOKIE_TXT.exists():
        raise BiliError(f"从 Chrome 导出 Cookie 失败: {r.stderr.strip()[-200:]}")
    entry = ingest_netscape_to_json()
    out({"ok": True, "account": entry["account"], "source": "chrome"})


# ---------- 字幕探测 ----------

SUB_PRIORITY = ["zh-Hans", "zh", "zh-Hant", "ai-zh", "ai-en"]


def cmd_probe_subs(url: str):
    r = subprocess.run(
        ["yt-dlp", "--cookies", str(COOKIE_TXT), "--list-subs", url],
        capture_output=True, text=True)
    langs, section = [], None
    for line in r.stdout.splitlines():
        if "Available subtitles" in line:
            section = "subs"
            continue
        if "Available automatic captions" in line:
            section = "auto"
            continue
        if section == "subs":
            m = re.match(r"^(\S+)\s+\S+", line.strip())
            if m and m.group(1) not in ("Language",):
                langs.append(m.group(1))
    best = "none"
    for want in SUB_PRIORITY:
        if want in langs:
            best = want
            break
    if best == "none":
        zh_like = [l for l in langs if l.startswith("zh") or l.startswith("ai-zh")]
        if zh_like:
            best = zh_like[0]
    out({"best": best, "all": [l for l in langs if l != "danmaku"], "danmaku": "danmaku" in langs})


# ---------- 弹幕 / 评论 ----------

def parse_danmaku(xml_path: str, duration_s: float) -> dict | None:
    if not xml_path or not Path(xml_path).exists():
        return None
    root = ET.parse(xml_path).getroot()
    dans = []
    for d in root.iter("d"):
        p = (d.get("p") or "").split(",")
        if len(p) >= 1 and d.text:
            try:
                dans.append((float(p[0]), d.text.strip()))
            except ValueError:
                continue
    if not dans:
        return None
    dans.sort()
    duration_s = duration_s or (dans[-1][0] + 5)
    # 密度峰值：10s 滑窗，贪心取不重叠 Top3
    peaks = []
    timeline = sorted(dans)
    used = []
    for start in range(0, int(max(duration_s, 1)), 5):
        if any(start < u + 10 for u in used):
            continue
        cnt = sum(1 for t, _ in timeline if start <= t < start + 10)
        peaks.append((cnt, start))
    peaks.sort(reverse=True)
    chosen = []
    for cnt, start in peaks:
        if len([c for c in chosen if abs(c["t"] - start) < 10]) >= 1:
            continue
        texts = Counter(txt for t, txt in timeline if start <= t < start + 10)
        chosen.append({"t": start, "window_s": 10, "count": cnt,
                       "top_texts": [t for t, _ in texts.most_common(5)]})
        if len(chosen) == 3:
            break
    top_repeated = [{"text": t, "count": c} for t, c in Counter(
        txt for _, txt in dans).most_common(10) if c >= 2]
    return {"total": len(dans), "duration_s": round(duration_s, 1),
            "density_per_min": round(len(dans) / max(duration_s / 60, 0.1), 1),
            "peaks": chosen, "top_repeated": top_repeated}


def fetch_comments(bvid: str, sessdata: str) -> tuple[dict, list]:
    view = http_json(f"https://api.bilibili.com/x/web-interface/view?bvid={bvid}", sessdata)["data"]
    aid, up_mid, up_name = view["aid"], view["owner"]["mid"], view["owner"]["name"]
    replies, total = [], 0
    for pn in (1, 2):  # 单页上限 ps=20，两页凑热评 30
        d = http_json(f"https://api.bilibili.com/x/v2/reply?type=1&oid={aid}"
                      f"&sort=1&ps=20&pn={pn}", sessdata)
        data = d.get("data", {})
        total = data.get("page", {}).get("acount", total)
        replies.extend(data.get("replies") or [])
        if not data.get("replies"):
            break
    top = []
    for r in replies[:30]:
        subs = (r.get("replies") or [])[:2]
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


def cmd_audience(url: str, danmaku_xml: str, out_dir: str, duration: float):
    bvid = re.search(r"(BV[0-9A-Za-z]{10})", url)
    if not bvid:
        raise BiliError(f"无法从 URL 解析 BV 号: {url}")
    bvid = bvid.group(1)
    entry = load_entry() or {}
    sessdata = entry.get("cookies", {}).get("SESSDATA", "")
    meta, top = fetch_comments(bvid, sessdata)
    danmaku = parse_danmaku(danmaku_xml, duration)
    outdir = Path(out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    audience = {
        "video": {"bvid": bvid, "title": None, "up_mid": meta["up_mid"],
                  "up_name": meta["up_name"], "duration": duration},
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "danmaku": danmaku,
        "comments": {"total": meta["total"], "sampled": meta["sampled"],
                     "up_mid": meta["up_mid"], "top": top},
    }
    (outdir / "audience.json").write_text(json.dumps(audience, ensure_ascii=False, indent=2))
    (outdir / "comments.json").write_text(json.dumps(
        {"aid": meta["aid"], "total": meta["total"], "replies": top},
        ensure_ascii=False, indent=2))
    out({"ok": True, "danmaku_total": danmaku["total"] if danmaku else 0,
         "comments_total": meta["total"], "comments_sampled": meta["sampled"]})


def main():
    parser = argparse.ArgumentParser(description="B 站元数据聚合器")
    cmd = parser.add_subparsers(dest="cmd", required=True)
    p1 = cmd.add_parser("ensure-cookies")
    p1.add_argument("--url", required=True)
    p2 = cmd.add_parser("probe-subs")
    p2.add_argument("--url", required=True)
    p3 = cmd.add_parser("audience")
    p3.add_argument("--url", required=True)
    p3.add_argument("--danmaku-xml", default="")
    p3.add_argument("--out-dir", required=True)
    p3.add_argument("--duration", type=float, default=0)
    args = parser.parse_args()
    try:
        if args.cmd == "ensure-cookies":
            cmd_ensure_cookies(args.url)
        elif args.cmd == "probe-subs":
            cmd_probe_subs(args.url)
        else:
            cmd_audience(args.url, args.danmaku_xml, args.out_dir, args.duration)
    except BiliError as e:
        out({"ok": False, "error": str(e)})
        sys.exit(1)


if __name__ == "__main__":
    main()
