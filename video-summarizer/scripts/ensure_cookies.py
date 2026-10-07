#!/usr/bin/env python3
"""ensure_cookies.py —— 平台 Cookie 管理（video-summarizer · 能力组件）

单一事实源: cache/cookies.json（平台命名空间，新增平台加顶层键）；
yt-dlp 消费派生的 Netscape 文件 cache/_<platform>.cookies.txt（可随时重建）。
平台参数（域名 / 关键 Cookie / 登录校验 / Referer）全部来自 platforms.json
配置表——新增平台加配置即可；verify_type 声明校验响应的解析方式，目前支持
bilibili_nav（data.isLogin + data.uname），新校验类型需在 check_login 加实现。

子命令:
  ensure --platform <P> --url <URL>   确保命名空间存在且登录有效；失效则从 Chrome 导出重建
  status --platform <P>               查看当前状态（不写任何文件）

未配置平台默认免 Cookie 运行；任何平台手动放置 Netscape 格式的
cache/_<platform>.cookies.txt 即被 pipeline 使用（不经本脚本校验）。
"""

import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CONFIG_PATH = Path(__file__).parent / "platforms.json"
COOKIE_JSON = Path("cache/cookies.json")

MANUAL_HINT = ("手动方案: 浏览器插件导出 Netscape cookie 文件，放入 cache/_{platform}.cookies.txt，"
               "并在 cache/cookies.json 的 \"{platform}\" 命名空间写入关键 Cookie 键值")


class CookieError(Exception):
    pass


def load_platform_cfg(platform: str) -> dict:
    """从 platforms.json 读平台 cookie 配置。"""
    if not CONFIG_PATH.exists():
        raise CookieError(f"platforms.json 缺失: {CONFIG_PATH}")
    cfg = json.loads(CONFIG_PATH.read_text()).get(platform) or {}
    cookie = cfg.get("cookie") or {}
    if not cookie.get("domain"):
        raise CookieError(f"平台 {platform} 未配置自动 Cookie 导出；如需登录态请手动放置 "
                          f"cache/_{platform}.cookies.txt（Netscape 格式）")
    return cookie


def out(payload: dict):
    print(json.dumps(payload, ensure_ascii=False))


def http_json(url: str, referer: str, cookie_name: str, cookie_value: str) -> dict:
    headers = {"User-Agent": ua(), "Referer": referer}
    if cookie_value:
        headers["Cookie"] = f"{cookie_name}={cookie_value}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def ua() -> str:
    return json.loads(CONFIG_PATH.read_text()).get("_meta", {}).get("ua") or ""


def netscape_path(platform: str) -> Path:
    return Path(f"cache/_{platform}.cookies.txt")


def load_entry(platform: str) -> dict | None:
    if not COOKIE_JSON.exists():
        return None
    try:
        entry = json.loads(COOKIE_JSON.read_text()).get(platform, {})
        key = load_platform_cfg(platform)["login_cookie"]
        return entry if entry.get("cookies", {}).get(key) else None
    except (json.JSONDecodeError, OSError):
        return None


def write_netscape(platform: str, entry: dict):
    cfg = load_platform_cfg(platform)
    path = netscape_path(platform)
    path.parent.mkdir(parents=True, exist_ok=True)
    domain = cfg["domain"]
    lines = [f"# Netscape HTTP Cookie File (derived from cache/cookies.json:{platform})"]
    for k, v in entry["cookies"].items():
        lines.append(f".{domain}\tTRUE\t/\tTRUE\t2147483647\t{k}\t{v}")
    path.write_text("\n".join(lines) + "\n")


def check_login(platform: str, cookie_value: str) -> str | None:
    """返回登录账号名；未登录/失效返回 None。按 verify_type 分发响应解析。"""
    cfg = load_platform_cfg(platform)
    vtype = cfg.get("verify_type")
    try:
        d = http_json(cfg["verify_url"], cfg.get("referer") or "", cfg["login_cookie"],
                      cookie_value)
        if vtype == "bilibili_nav":
            return d.get("data", {}).get("uname") if d.get("data", {}).get("isLogin") else None
        raise CookieError(f"平台 {platform} 的 verify_type={vtype!r} 未实现，"
                          f"请在 ensure_cookies.py check_login 中补充解析逻辑")
    except CookieError:
        raise
    except Exception:
        return None


def ingest_netscape(platform: str) -> dict:
    """把 yt-dlp 从 Chrome 导出的 Netscape 文件收进 JSON 命名空间（唯一事实源）"""
    cfg = load_platform_cfg(platform)
    txt = netscape_path(platform)
    entry = {"cookies": {}}
    wanted = set(cfg.get("wanted") or [])
    for line in txt.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split("\t")
        if len(f) >= 7 and cfg["domain"] in f[0] and (not wanted or f[5] in wanted):
            entry["cookies"][f[5]] = f[6].strip()
    login = cfg["login_cookie"]
    if login not in entry["cookies"]:
        raise CookieError(f"Chrome 导出成功但未包含 {platform} 的 {login}（Chrome 是否登录了该平台？）")
    account = check_login(platform, entry["cookies"][login])
    if not account:
        raise CookieError(f"导出的 {login} 校验失败（未登录或已失效）")
    entry.update(account=account, source="chrome",
                 exported_at=datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"))
    old = json.loads(COOKIE_JSON.read_text()) if COOKIE_JSON.exists() else {}
    old.setdefault("_meta", {"version": 1, "note": "平台命名空间隔离，新增平台加顶层键"})
    old[platform] = entry
    COOKIE_JSON.parent.mkdir(parents=True, exist_ok=True)
    COOKIE_JSON.write_text(json.dumps(old, ensure_ascii=False, indent=2) + "\n")
    return entry


def cmd_ensure(platform: str, url: str):
    if (json.loads(CONFIG_PATH.read_text()).get(platform) or {}).get("cookie", {}).get("ensure"):
        pass  # 配置声明的自动导出平台
    else:
        raise CookieError(
            f"平台 {platform} 未配置自动 Cookie 导出；如需登录态请手动放置 "
            f"cache/_{platform}.cookies.txt（Netscape 格式）")
    entry = load_entry(platform)
    if entry:
        account = check_login(platform, entry["cookies"][load_platform_cfg(platform)["login_cookie"]])
        if account:
            write_netscape(platform, entry)
            out({"ok": True, "account": account, "source": "cache"})
            return
    # 从 Chrome 导出（借助 yt-dlp 访问目标 URL 时落盘的全量 cookie）
    txt = netscape_path(platform)
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
    try:
        cfg = load_platform_cfg(platform)
    except CookieError as e:
        out({"configured": False, "platform": platform, "note": str(e)})
        return
    entry = load_entry(platform)
    if not entry:
        out({"configured": True, "platform": platform, "has_cookies": False})
        return
    account = check_login(platform, entry["cookies"][cfg["login_cookie"]])
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
