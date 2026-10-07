#!/usr/bin/env python3
"""ensure_cookies.py —— 平台 Cookie 管理（video-summarizer · 能力组件）

消费优先级（手动兜底真正生效的关键顺序）:
  1. cache/_<platform>.cookies.txt 已存在（含用户手动放置）→ 解析+登录校验
     通过即采用并回写 cookies.json 命名空间；无效则告警后继续尝试下一来源，
     绝不覆盖或删除用户文件
  2. cache/cookies.json 平台命名空间有效 → 派生 netscape 文件
  3. 浏览器导出 → 先写临时文件，解析+校验全部通过后才 os.replace 落位正式
     文件（失败不碰既有文件）

单一事实源: cache/cookies.json（平台命名空间，新增平台加顶层键）。
平台参数（域名列表/关键 Cookie/登录校验/Referer/浏览器/失败策略）全部来自
platforms.json；verify_type 目前支持 bilibili_nav，新校验类型需在 check_login
补充实现。on_failure 策略由调用方（pipeline_prepare.sh）实施。

子命令:
  ensure --platform <P> --url <URL> [--cache-dir <DIR>]   确保登录态（默认 cache/；
      --cache-dir 指向临时目录时全部派生物落在该目录，项目内零写入——quick 模式用）
  status --platform <P> [--cache-dir <DIR>]               查看状态（不写任何文件）

未配置平台默认免 Cookie；任何平台手动放置 Netscape 格式的
cache/_<platform>.cookies.txt（generic 平台还可用 cache/_<host>.cookies.txt）
即被 pipeline 采用。
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CONFIG_PATH = Path(__file__).parent / "platforms.json"
CACHE_DIR = Path("cache")

MANUAL_HINT = ("手动方案: 浏览器插件导出 Netscape cookie 文件，放入 cache/_{platform}.cookies.txt"
               "（generic 平台也可用 cache/_<host>.cookies.txt）后重试——ensure 会自动校验采用，"
               "无需手写 cookies.json")


class CookieError(Exception):
    pass


def load_platform_cfg(platform: str) -> dict:
    """从 platforms.json 读平台 cookie 配置。"""
    if not CONFIG_PATH.exists():
        raise CookieError(f"platforms.json 缺失: {CONFIG_PATH}")
    cfg = json.loads(CONFIG_PATH.read_text()).get(platform) or {}
    cookie = cfg.get("cookie") or {}
    if not cookie.get("domains"):
        raise CookieError(f"平台 {platform} 未配置自动 Cookie（缺 cookie.domains）；"
                          f"如需登录态请手动放置 cache/_{platform}.cookies.txt（Netscape 格式）")
    return cookie


def out(payload: dict):
    print(json.dumps(payload, ensure_ascii=False))


def ua() -> str:
    return json.loads(CONFIG_PATH.read_text()).get("_meta", {}).get("ua") or ""


def cookie_json() -> Path:
    return CACHE_DIR / "cookies.json"


def netscape_path(platform: str) -> Path:
    return CACHE_DIR / f"_{platform}.cookies.txt"


def export_tmp_path(platform: str) -> Path:
    return CACHE_DIR / f"_{platform}.export.tmp"


def http_json(url: str, referer: str, cookie_name: str, cookie_value: str) -> dict:
    headers = {"User-Agent": ua(), "Referer": referer}
    if cookie_value:
        headers["Cookie"] = f"{cookie_name}={cookie_value}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def load_entry(platform: str) -> dict | None:
    if not cookie_json().exists():
        return None
    try:
        entry = json.loads(cookie_json().read_text()).get(platform, {})
        key = load_platform_cfg(platform)["login_cookie"]
        return entry if entry.get("cookies", {}).get(key) else None
    except (json.JSONDecodeError, OSError):
        return None


def write_netscape(platform: str, entry: dict):
    cfg = load_platform_cfg(platform)
    path = netscape_path(platform)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"# Netscape HTTP Cookie File (derived from cache/cookies.json:{platform})"]
    for k, v in entry["cookies"].items():
        for d in cfg["domains"]:  # 多域平台每个归属域一行
            lines.append(f".{d}\tTRUE\t/\tTRUE\t2147483647\t{k}\t{v}")
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


def parse_netscape_file(platform: str, path: Path) -> dict:
    """解析 Netscape cookie 文件，按 domains 过滤出关键 Cookie。"""
    cfg = load_platform_cfg(platform)
    wanted = set(cfg.get("wanted") or [])
    entry = {"cookies": {}}
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split("\t")
        if len(f) >= 7 and any(d in f[0] for d in cfg["domains"]) \
                and (not wanted or f[5] in wanted):
            entry["cookies"][f[5]] = f[6].strip()
    login = cfg["login_cookie"]
    if login not in entry["cookies"]:
        raise CookieError(f"{path.name} 未包含 {platform} 的 {login}"
                          f"（浏览器/导出是否登录了该平台？）")
    return entry


def store_entry(platform: str, entry: dict, source: str) -> dict:
    """登录校验通过后并入 cookies.json（保留其他平台命名空间），返回补全的条目。"""
    account = check_login(platform, entry["cookies"][load_platform_cfg(platform)["login_cookie"]])
    if not account:
        raise CookieError(f"{load_platform_cfg(platform)['login_cookie']} 登录校验失败（未登录或已失效）")
    entry.update(account=account, source=source,
                 exported_at=datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"))
    cj = cookie_json()
    old = {}
    if cj.exists():
        try:
            old = json.loads(cj.read_text())
        except json.JSONDecodeError:
            print(f"警告: {cj} 损坏，重建（其他平台命名空间将丢失）", file=sys.stderr)
    old.setdefault("_meta", {"version": 1, "note": "平台命名空间隔离，新增平台加顶层键"})
    old[platform] = entry
    cj.parent.mkdir(parents=True, exist_ok=True)
    cj.write_text(json.dumps(old, ensure_ascii=False, indent=2) + "\n")
    return entry


def cmd_ensure(platform: str, url: str):
    if not (json.loads(CONFIG_PATH.read_text()).get(platform) or {}).get("cookie", {}).get("ensure"):
        raise CookieError(f"平台 {platform} 未配置自动 Cookie 导出；如需登录态请手动放置 "
                          f"cache/_{platform}.cookies.txt（Netscape 格式）")
    cfg = load_platform_cfg(platform)

    # 1) 既有文件（含手动放置）优先：有效即采用，**原样使用不回写**
    #    （write_netscape 只写 wanted 子集，回写会裁掉用户文件里的非关键 cookie）
    final = netscape_path(platform)
    if final.exists():
        try:
            entry = store_entry(platform, parse_netscape_file(platform, final), source="file")
            out({"ok": True, "account": entry["account"], "source": "file"})
            return
        except CookieError as e:
            print(f"警告: 既有 cookie 文件未通过校验（{e}），尝试其他来源", file=sys.stderr)

    # 2) cookies.json 命名空间
    entry = load_entry(platform)
    if entry:
        account = check_login(platform, entry["cookies"][cfg["login_cookie"]])
        if account:
            write_netscape(platform, entry)
            out({"ok": True, "account": account, "source": "cache"})
            return

    # 3) 浏览器导出 → 临时文件，解析+校验通过才落位（失败绝不碰既有文件）
    browser = cfg.get("browser") or "chrome"
    tmp = export_tmp_path(platform)
    tmp.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["yt-dlp", "--cookies-from-browser", browser, "--cookies", str(tmp),
         "--skip-download", url], capture_output=True, text=True)
    if r.returncode != 0 or not tmp.exists():
        tmp.unlink(missing_ok=True)
        raise CookieError(f"从 {browser} 导出 Cookie 失败: {r.stderr.strip()[-200:]}")
    try:
        entry = store_entry(platform, parse_netscape_file(platform, tmp), source=browser)
    except CookieError:
        tmp.unlink(missing_ok=True)
        raise
    os.replace(tmp, final)
    write_netscape(platform, entry)
    out({"ok": True, "account": entry["account"], "source": browser})


def cmd_status(platform: str):
    try:
        cfg = load_platform_cfg(platform)
    except CookieError as e:
        out({"configured": False, "platform": platform, "note": str(e)})
        return
    entry = load_entry(platform)
    payload = {"configured": True, "platform": platform,
               "cookie_file": str(netscape_path(platform)),
               "has_cookie_file": netscape_path(platform).exists()}
    if entry:
        account = check_login(platform, entry["cookies"][cfg["login_cookie"]])
        payload.update(has_cookies=True, account=account or "", valid=bool(account))
    else:
        payload.update(has_cookies=False)
    out(payload)


def main():
    global CACHE_DIR
    parser = argparse.ArgumentParser(description="平台 Cookie 管理")
    cmd = parser.add_subparsers(dest="cmd", required=True)
    p1 = cmd.add_parser("ensure")
    p1.add_argument("--platform", required=True)
    p1.add_argument("--url", required=True)
    p1.add_argument("--cache-dir", default="cache")
    p2 = cmd.add_parser("status")
    p2.add_argument("--platform", required=True)
    p2.add_argument("--cache-dir", default="cache")
    args = parser.parse_args()
    CACHE_DIR = Path(args.cache_dir)
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
