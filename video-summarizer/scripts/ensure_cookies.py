#!/usr/bin/env python3
"""Workspace Cookie store. JSON is authoritative; Netscape files are derived only.

ensure/status --project-root ROOT --platform P [ensure: --url URL --snapshot FILE]
Only missing, malformed or explicitly expired JSON credentials trigger browser export.
Network failures preserve the store. All writers share one workspace lock and budget.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

CONFIG_PATH = Path(__file__).parent / "platforms.json"


class CookieError(Exception):
    def __init__(self, message, code="cookie_error"):
        super().__init__(message)
        self.code = code


def load_platform_cfg(platform):
    cfg = json.loads(CONFIG_PATH.read_text()).get(platform) or {}
    cookie = cfg.get("cookie") or {}
    if not cookie.get("ensure") or not cookie.get("domains"):
        raise CookieError("该平台未配置自动 Cookie 获取", "not_configured")
    return cookie


def ua():
    return json.loads(CONFIG_PATH.read_text()).get("_meta", {}).get("ua") or "Mozilla/5.0"


def check_login(platform, cookie_value, timeout=15):
    """Account for valid credentials; None only for a definite logged-out response."""
    cfg = load_platform_cfg(platform)
    if cfg.get("verify_type") != "bilibili_nav":
        raise CookieError("未实现该平台的登录校验", "not_configured")
    req = urllib.request.Request(cfg["verify_url"], headers={
        "User-Agent": ua(), "Referer": cfg.get("referer") or "",
        "Cookie": "%s=%s" % (cfg["login_cookie"], cookie_value),
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            d = json.loads(resp.read().decode())
    except Exception as error:
        raise CookieError("Cookie 登录校验暂不可用，请稍后重试", "network_error") from error
    if not isinstance(d, dict) or not isinstance(d.get("data") or {}, dict):
        raise CookieError("Cookie 登录校验返回异常，请稍后重试", "network_error")
    data = d.get("data") or {}
    if d.get("code") == -101 or (d.get("code") == 0 and data.get("isLogin") is False):
        return None
    if d.get("code") == 0 and data.get("isLogin") is True and data.get("uname"):
        return data["uname"]
    raise CookieError("Cookie 登录校验返回异常，请稍后重试", "network_error")


def parse_netscape_file(platform, path):
    """Parse a fresh browser export, never a legacy workspace Netscape file."""
    cfg = load_platform_cfg(platform)
    wanted = set(cfg.get("wanted") or [])
    cookies = {}
    for line in path.read_text().splitlines():
        if line.startswith("#HttpOnly_"):
            line = line[len("#HttpOnly_"):]
        if line.startswith("#") or not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 7:
            continue
        domain, name, value = fields[0], fields[5], fields[6].strip()
        if any(domain in (d, "." + d) or domain.endswith("." + d) for d in cfg["domains"]):
            if not wanted or name in wanted:
                cookies[name] = value
    if not cookies.get(cfg["login_cookie"]):
        raise CookieError("Chrome 中没有可用的站点登录态，请先登录后重试", "login_unavailable")
    return {"cookies": cookies}


def atomic_write(path, text, mode=0o600):
    """Replace a complete file in its own directory; never expose a partial JSON."""
    fd, name = tempfile.mkstemp(prefix=".cookies-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def netscape_text(platform, entry):
    cfg = load_platform_cfg(platform)
    lines = ["# Netscape HTTP Cookie File (derived from workspace cookies.json)"]
    for name, value in entry["cookies"].items():
        if any(c in str(name) + str(value) for c in "\r\n\t"):
            raise CookieError("Cookie 数据格式异常", "cache_invalid")
        for domain in cfg["domains"]:
            lines.append(".%s\tTRUE\t/\tTRUE\t2147483647\t%s\t%s" % (domain, name, value))
    return "\n".join(lines) + "\n"


class CookieStore:
    def __init__(self, project_root, timeout=90):
        self.root = Path(project_root).expanduser().resolve()
        if not self.root.is_dir():
            raise CookieError("Cookie 工作区目录不存在", "workspace_error")
        self.cache = self.root / "cache"
        if self.cache.is_symlink():
            raise CookieError("工作区 cache 必须是本地目录", "workspace_error")
        self.json_path = self.cache / "cookies.json"
        self.deadline = time.monotonic() + timeout

    def remaining(self, cap=None):
        value = self.deadline - time.monotonic()
        if value <= 0:
            raise CookieError("Cookie 获取或锁等待超时，请稍后重试", "timeout")
        return min(value, cap) if cap else value

    def run(self, args):
        try:
            return subprocess.run(args, cwd=self.root, capture_output=True, text=True,
                                  timeout=self.remaining())
        except subprocess.TimeoutExpired as error:
            raise CookieError("Cookie 获取超时，请稍后重试", "timeout") from error

    @contextmanager
    def locked(self):
        self.cache.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(self.cache / ".cookies.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            os.fchmod(fd, 0o600)
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(min(0.05, self.remaining()))
            self.remaining()
            yield
        finally:
            os.close(fd)

    def protect_git(self):
        if shutil.which("git"):
            repository = self.run(["git", "rev-parse", "--show-toplevel"])
            if repository.returncode == 0:
                tracked = self.run(["git", "ls-files", "-z", "--", "cache/*cookies*", "cache/.cookies.lock"])
                if tracked.returncode or tracked.stdout:
                    raise CookieError("工作区 Cookie 文件已被 Git 跟踪，请先移除跟踪后重试", "cache_tracked")
        ignore = self.root / ".gitignore"
        text = ignore.read_text() if ignore.exists() else ""
        probes = ("cache/cookies.json", "cache/_bilibili.cookies.txt", "cache/.cookies.lock")
        needs_rule = "/cache/" not in text.splitlines() and "cache/" not in text.splitlines()
        if shutil.which("git") and repository.returncode == 0:
            needs_rule = any(self.run(["git", "check-ignore", "-q", name]).returncode for name in probes)
        if needs_rule:
            mode = (ignore.stat().st_mode & 0o777) if ignore.exists() else 0o644
            atomic_write(ignore, text + ("\n" if text and not text.endswith("\n") else "") + "/cache/\n", mode)
        if shutil.which("git") and repository.returncode == 0:
            if any(self.run(["git", "check-ignore", "-q", name]).returncode for name in probes):
                raise CookieError("Git 忽略规则未覆盖 Cookie 缓存，请检查 .gitignore", "cache_not_ignored")

    def read(self):
        try:
            d = json.loads(self.json_path.read_text())
            return d if isinstance(d, dict) else {}
        except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def entry(self, document, platform):
        cfg = load_platform_cfg(platform)
        entry = document.get(platform)
        if not isinstance(entry, dict) or not isinstance(entry.get("cookies"), dict):
            return None
        cookies = entry["cookies"]
        if not isinstance(cookies.get(cfg["login_cookie"]), str) or not cookies[cfg["login_cookie"]]:
            return None
        if any(not isinstance(k, str) or not isinstance(v, str) or any(c in k + v for c in "\r\n\t") for k, v in cookies.items()):
            return None
        return entry

    def ensure(self, platform, url, snapshot=None):
        cfg = load_platform_cfg(platform)
        destination = Path(snapshot).expanduser().absolute() if snapshot else None
        if destination and (destination.resolve() == self.cache.resolve() or self.cache.resolve() in destination.resolve().parents):
            raise CookieError("Cookie 运行副本必须放在缓存目录之外", "snapshot_error")
        with self.locked():
            self.protect_git()
            document = self.read()
            entry = self.entry(document, platform)
            account = check_login(platform, entry["cookies"][cfg["login_cookie"]], self.remaining(15)) if entry else None
            source = "cache"
            if not account:
                if not shutil.which("yt-dlp"):
                    raise CookieError("yt-dlp 不可用，请先安装 skill 依赖", "browser_unavailable")
                with tempfile.TemporaryDirectory(prefix=".cookie-export-", dir=self.cache) as directory:
                    exported = Path(directory) / "export.cookies.txt"
                    self.run(["yt-dlp", "--ignore-config", "--no-playlist", "--cookies-from-browser", cfg.get("browser") or "chrome",
                              "--cookies", str(exported), "--skip-download", "--socket-timeout", "15", "--retries", "0", url])
                    if not exported.is_file():
                        raise CookieError("无法从 Chrome 获取登录态，请确认浏览器已登录", "browser_unavailable")
                    os.chmod(exported, 0o600)
                    entry = parse_netscape_file(platform, exported)
                account = check_login(platform, entry["cookies"][cfg["login_cookie"]], self.remaining(15))
                if not account:
                    raise CookieError("Chrome 登录态已失效，请登录后重试", "login_unavailable")
                source = cfg.get("browser") or "chrome"
                entry.update(account=account, source=source, exported_at=datetime.now(timezone.utc).isoformat(timespec="seconds"))
                document.setdefault("_meta", {"version": 1, "note": "Workspace Cookie credentials; Netscape files are derived only"})
                document[platform] = entry
                atomic_write(self.json_path, json.dumps(document, ensure_ascii=False, indent=2) + "\n")
            else:
                os.chmod(self.json_path, 0o600)
            text = netscape_text(platform, entry)
            atomic_write(self.cache / ("_%s.cookies.txt" % platform), text)
            if destination:
                atomic_write(destination, text)
            self.remaining()
            return {"ok": True, "state": "valid", "source": source, "account": account}

    def status(self, platform):
        try:
            cfg = load_platform_cfg(platform)
        except CookieError as error:
            if error.code != "not_configured":
                raise
            return {"configured": False, "platform": platform}
        entry = self.entry(self.read(), platform)
        if not entry:
            return {"configured": True, "state": "missing", "valid": False, "has_cookies": False}
        account = check_login(platform, entry["cookies"][cfg["login_cookie"]], self.remaining(15))
        return {"configured": True, "state": "valid" if account else "invalid", "has_cookies": True,
                "valid": bool(account), "account": account or ""}


def main():
    parser = argparse.ArgumentParser(description="Workspace Cookie 管理（JSON 唯一凭据源）")
    commands = parser.add_subparsers(dest="cmd", required=True)
    for name in ("ensure", "status"):
        command = commands.add_parser(name)
        command.add_argument("--project-root", required=True)
        command.add_argument("--platform", required=True)
        if name == "ensure":
            command.add_argument("--url", required=True)
            command.add_argument("--snapshot")
    args = parser.parse_args()
    try:
        store = CookieStore(args.project_root)
        payload = store.ensure(args.platform, args.url, args.snapshot) if args.cmd == "ensure" else store.status(args.platform)
        print(json.dumps(payload, ensure_ascii=False))
    except (CookieError, OSError) as error:
        message = str(error) if isinstance(error, CookieError) else "Cookie 缓存读写失败，请检查工作区权限"
        print(json.dumps({"ok": False, "state": "unknown", "code": getattr(error, "code", "cache_write_failed"), "error": message}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
