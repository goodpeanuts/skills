#!/usr/bin/env python3
"""ensure_cookies.py —— 平台 Cookie 管理（video-summarizer · 能力组件）

单一事实源: cache/cookies.json（平台命名空间，新增平台加顶层键）；
yt-dlp 消费派生的 Netscape 文件 cache/_<platform>.cookies.txt（可随时重建）。

子命令:
  ensure --platform <P> --url <URL>   确保命名空间存在且登录有效；失效则从 Chrome 导出重建
  status --platform <P>               查看当前状态（不写任何文件）

平台配置表 PLATFORMS 声明各平台的能力参数（域名 / 关键 Cookie / 登录校验）。
未配置的平台默认免 Cookie 运行；如需登录态，手动放置 Netscape 格式的
cache/_<platform>.cookies.txt 即可被 pipeline 自动使用。
"""

import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/132.0 Safari/537.36")
COOKIE_JSON = Path("cache/cookies.json")

MANUAL_HINT = ("手动方案: 浏览器插件导出 Netscape cookie 文件，放入 cache/_{platform}.cookies.txt，"
               "并在 cache/cookies.json 的 \"{platform}\" 命名空间写入关键 Cookie 键值")

# 平台配置表：新平台加一项即可获得自动 Cookie 能力
# domain: cookie 归属域；login_cookie: 命名空间有效性判定的关键 Cookie；
# verify: 用该 cookie GET 此接口，响应中 isLogin/uname 判定登录态
PLATFORMS = {
    "bilibili": {
        "domain": "bilibili.com",
        "netscape": Path("cache/_bilibili.cookies.txt"),
        "login_cookie": "SESSDATA",
        "wanted": ("SESSDATA", "buvid3", "buvid4", "bili_jct"),
        "verify": "https://api.bilibili.com/x/web-interface/nav",
    },
}


class CookieError(Exception):
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


def load_entry(platform: str) -> dict | None:
    if not COOKIE_JSON.exists():
        return None
    try:
        entry = json.loads(COOKIE_JSON.read_text()).get(platform, {})
        key = PLATFORMS[platform]["login_cookie"]
        return entry if entry.get("cookies", {}).get(key) else None
    except (json.JSONDecodeError, OSError):
        return None


def write_netscape(platform: str, entry: dict):
    path = PLATFORMS[platform]["netscape"]
    path.parent.mkdir(parents=True, exist_ok=True)
    domain = PLATFORMS[platform]["domain"]
    lines = [f"# Netscape HTTP Cookie File (derived from cache/cookies.json:{platform})"]
    for k, v in entry["cookies"].items():
        lines.append(f".{domain}\tTRUE\t/\tTRUE\t2147483647\t{k}\t{v}")
    path.write_text("\n".join(lines) + "\n")


def check_login(platform: str, sessdata: str) -> str | None:
    """返回登录账号名；未登录/失效返回 None。目前仅 bilibili 配置了校验接口。"""
    try:
        d = http_json(PLATFORMS[platform]["verify"], sessdata)
        return d.get("data", {}).get("uname") if d.get("data", {}).get("isLogin") else None
    except Exception:
        return None


def ingest_netscape(platform: str) -> dict:
    """把 yt-dlp 从 Chrome 导出的 Netscape 文件收进 JSON 命名空间（唯一事实源）"""
    cfg = PLATFORMS[platform]
    txt = cfg["netscape"]
    entry = {"cookies": {}}
    for line in txt.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split("\t")
        if len(f) >= 7 and cfg["domain"] in f[0] and f[5] in cfg["wanted"]:
            entry["cookies"][f[5]] = f[6].strip()
    login = cfg["login_cookie"]
    if login not in entry["cookies"]:
        raise CookieError(f"Chrome 导出成功但未包含 {platform} 的 {login}（Chrome 是否登录了该平台？）")
    account = check_login(platform, entry["cookies"][login])
    if not account:
        raise CookieError(f"导出的 {login} 校验失败（未登录或已失效）")
    entry.update(account=account, source="chrome",
                 exported_at=datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"))
    COOKIE_JSON.write_text(json.dumps(
        {"_meta": {"version": 1, "note": "平台命名空间隔离，新增平台加顶层键"},
         platform: entry}, ensure_ascii=False, indent=2) + "\n")
    return entry


def cmd_ensure(platform: str, url: str):
    if platform not in PLATFORMS:
        raise CookieError(
            f"平台 {platform} 未配置自动 Cookie 导出；如需登录态请手动放置 "
            f"cache/_{platform}.cookies.txt（Netscape 格式）")
    entry = load_entry(platform)
    if entry:
        account = check_login(platform, entry["cookies"][PLATFORMS[platform]["login_cookie"]])
        if account:
            write_netscape(platform, entry)
            out({"ok": True, "account": account, "source": "cache"})
            return
    # 从 Chrome 导出（借助 yt-dlp 访问目标 URL 时落盘的全量 cookie）
    txt = PLATFORMS[platform]["netscape"]
    txt.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["yt-dlp", "--cookies-from-browser", "chrome", "--cookies", str(txt),
         "--skip-download", url], capture_output=True, text=True)
    if r.returncode != 0 or not txt.exists():
        raise CookieError(f"从 Chrome 导出 Cookie 失败: {r.stderr.strip()[-200:]}")
    entry = ingest_netscape(platform)
    write_netscape(platform, entry)
    out({"ok": True, "account": entry["account"], "source": "chrome"})


def cmd_status(platform: str):
    if platform not in PLATFORMS:
        out({"configured": False, "platform": platform})
        return
    entry = load_entry(platform)
    if not entry:
        out({"configured": True, "platform": platform, "has_cookies": False})
        return
    account = check_login(platform, entry["cookies"][PLATFORMS[platform]["login_cookie"]])
    out({"configured": True, "platform": platform, "has_cookies": True,
         "account": account or "", "valid": bool(account)})


def main():
    parser = argparse.ArgumentParser(description="平台 Cookie 管理")
    cmd = parser.add_subparsers(dest="cmd", required=True)
    p1 = cmd.add_parser("ensure")
    p1.add_argument("--platform", required=True)
    p1.add_argument("--url", required=True)
    p2 = cmd.add_parser("status")
    p2.add_argument("--platform", required=True)
    args = parser.parse_args()
    try:
        if args.cmd == "ensure":
            cmd_ensure(args.platform, args.url)
        else:
            cmd_status(args.platform)
    except CookieError as e:
        out({"ok": False, "error": str(e),
             "hint": MANUAL_HINT.format(platform=args.platform)})
        sys.exit(1)


if __name__ == "__main__":
    main()
