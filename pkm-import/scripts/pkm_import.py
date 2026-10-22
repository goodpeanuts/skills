#!/usr/bin/env python3
"""pkm-import：把视频总结仓库 archive/ 的总结增量导入为 Obsidian 库的文献笔记。

职责分离（详见 SKILL.md）：
- 本脚本只实现"我们侧"的规则：特征注释、台账、标题清洗、正文变换、状态机。
- 目标库的一切规范（模板、附件约定、写入节奏、嵌入格式）由执行 agent 每次
  导入前现场读取该库最新规则后作为一次性命令行参数传入；脚本不读库的规则
  文件、不缓存任何库规范。

子命令：
  plan    只读：扫描 archive × 台账 × 库内特征检索 → 状态报告 + 导入计划
  apply   执行：按 plan 创建/更新/记账，逐单元原子写台账
  verify  只读：导入后核验（注释↔台账一一对应、附件在库、无残留引用）
"""

import argparse
import hashlib
import json
import os
import re
import socket
import sys
from datetime import datetime
from pathlib import Path

MARKER_PREFIX = "pkm-import: source-id="
SEARCH_PAYLOAD = "source-id="  # 特征检索负载：不带冒号，避开 Obsidian 搜索操作符
IMAGE_LINE_RE = re.compile(r"^((?:[ \t]*>[ \t]?)*[ \t]*)!\[(.*)\]\(([^)]+)\)([^\n]*)$", re.M)
SUMMARY_PART_RE = re.compile(r"^summary_(\d+)\.md$")
ID_PREFIX_RE = re.compile(r"^([A-Za-z0-9-]+)_")
CREATED_TIME_RE = re.compile(r'^createdTime:\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"?', re.M)
FULLWIDTH = {"\\": "＼", "/": "／", ":": "：", "*": "＊", "?": "？", '"': "＂",
             "<": "＜", ">": "＞", "|": "｜", "#": "＃", "^": "＾", "[": "［", "]": "］"}

STATE_LABELS = {
    "pending": "⏳ 未导入",
    "imported": "✅ 已导入·未变",
    "changed": "✏️  源有改动·待更新",
    "missing": "⚠️  库内缺失",
    "already_in_vault": "♻️  库内已有·将只记账",
    "conflict": "⛔ 同名无特征·硬停",
}


class Fatal(RuntimeError):
    pass


def now_iso():
    return datetime.now().isoformat(timespec="seconds")


def hostname():
    return socket.gethostname().removesuffix(".local")


# ---------------------------------------------------------------- 标题清洗（规则 v1，用户已确认）

def sanitize_title(raw):
    title = "".join(FULLWIDTH.get(ch, ch) for ch in raw)
    title = re.sub(r"\s+", " ", title).strip().strip(".")
    if len(title) > 100:
        title = title[:100].rstrip()
    return title


# ---------------------------------------------------------------- archive 扫描

def note_title_from_summary(summary_path, bv, part):
    for line in summary_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            return sanitize_title(line[2:].strip())
    return sanitize_title(bv if part is None else f"{bv}-p{part:02d}")


def scan_archive(repo, warnings):
    """返回导入单元列表：单视频与分P各一条（一条=一篇笔记=一个特征注释）。"""
    archive = Path(repo) / "archive"
    if not archive.is_dir():
        raise Fatal(f"找不到 archive 目录: {archive}")
    units, seen = [], {}
    for month_dir in sorted(p for p in archive.iterdir() if p.is_dir()):
        for platform_dir in sorted(p for p in month_dir.iterdir() if p.is_dir()):
            for video_dir in sorted(p for p in platform_dir.iterdir() if p.is_dir()):
                platform = platform_dir.name
                m = ID_PREFIX_RE.match(video_dir.name)
                bv = m.group(1) if m else video_dir.name
                course_title = sanitize_title(ID_PREFIX_RE.sub("", video_dir.name))
                single = list(video_dir.glob("summary.md"))
                part_files = {}
                for f in video_dir.glob("summary_*.md"):
                    pm = SUMMARY_PART_RE.match(f.name)
                    if pm:
                        part_files[int(pm.group(1))] = f
                candidates = []
                if part_files:
                    if single:
                        warnings.append(f"{video_dir.name}: 同时有 summary.md 与 summary_NN.md，忽略 summary.md")
                    for n in sorted(part_files):
                        candidates.append((f"{platform}/{bv}/p{n:02d}", n, part_files[n]))
                elif single:
                    candidates.append((f"{platform}/{bv}", None, single[0]))
                else:
                    if not list(video_dir.glob("brief*.md")):
                        warnings.append(f"跳过（无 summary）: {video_dir}")
                    continue
                for sid, part, summary in candidates:
                    if sid in seen:
                        raise Fatal(f"archive 内出现重复 source_id {sid}（{seen[sid]} 与 {summary}），请人工处理")
                    seen[sid] = summary
                    units.append({
                        "source_id": sid,
                        "bv": bv,
                        "part": part,
                        "title": note_title_from_summary(summary, bv, part),
                        "course": ({"id": f"{platform}/{bv}", "title": course_title} if part_files else None),
                        "source_summary": summary.resolve().relative_to(Path(repo).resolve()).as_posix(),
                        "source_sha256": sha256_file(summary),
                    })
    return units


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- 台账（ledger.json）

def load_ledger(path):
    p = Path(path)
    if not p.exists():
        return {"version": 1, "profiles": {}, "imports": {}}
    data = json.loads(p.read_text(encoding="utf-8"))
    data.setdefault("profiles", {})
    data.setdefault("imports", {})
    return data


def save_ledger(path, data):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def profile_key(vault_path):
    return f"{hostname()}:{vault_path}"


def frontmatter_of(raw):
    if not raw.startswith("---"):
        raise Fatal("笔记缺少 frontmatter")
    end = raw.index("\n---", 3)
    return raw[:end + 4]  # 含结尾 "---"


def inject_tags(fm_text, tags):
    """在 frontmatter 中确保 tags 存在且包含我们的标签；其余内容一字不动。"""
    body_lines = fm_text.rstrip("\n").split("\n")
    closing = body_lines[-1]
    inner = body_lines[1:-1]
    out, i, done = [], 0, False
    while i < len(inner):
        line = inner[i]
        m = re.match(r"^tags:\s*(\[.*\])?\s*$", line)
        if m and not done:
            done = True
            if m.group(1):  # 行内列表 → 拆成块并合并
                try:
                    existing = json.loads(m.group(1).replace("，", ","))
                except json.JSONDecodeError:
                    existing = [x.strip() for x in m.group(1).strip("[]").split(",") if x.strip()]
                merged = list(dict.fromkeys(existing + list(tags)))
                out.append("tags:")
                out += [f"  - {t}" for t in merged]
                i += 1
                continue
            else:
                out.append(line)
                j = i + 1
                existing = []
                while j < len(inner) and re.match(r"^\s+-\s+", inner[j]):
                    existing.append(re.sub(r"^\s+-\s+", "", inner[j]).strip())
                    j += 1
                merged = list(dict.fromkeys(existing + list(tags)))
                out += [f"  - {t}" for t in merged]
                i = j
                continue
        out.append(line)
        i += 1
    if not done:
        out.append("tags:")
        out += [f"  - {t}" for t in tags]
    return "\n".join(["---", *out, closing]) + "\n"


def unit_target(unit, profile):
    if unit["course"]:
        return f"{profile['notes_folder']}/{unit['course']['title']}/{unit['title']}.md"
    return f"{profile['notes_folder']}/{unit['title']}.md"


def record_import(ledger, unit, pkey, status, target, action):
    entry = ledger["imports"].setdefault(unit["source_id"], {
        "title": unit["title"],
        "course": ({**unit["course"], "folder": None} if unit["course"] else None),
        "source_summary": unit["source_summary"],
        "per_profile": {},
    })
    if entry["course"] and not entry["course"]["folder"]:
        entry["course"]["folder"] = f"{unit['_notes_folder']}/{unit['course']['title']}"
    entry["per_profile"][pkey] = {
        "status": status,
        "target": target,
        "source_sha256": unit["source_sha256"],
        "imported_at": now_iso(),
        "history": [{"action": action, "at": now_iso()}],
    }


def append_history(ledger, unit, pkey, action):
    per = ledger["imports"][unit["source_id"]]["per_profile"][pkey]
    per["history"].append({"action": action, "at": now_iso()})
    per["source_sha256"] = unit["source_sha256"]
    per["imported_at"] = now_iso()


# Versioned public request API; import siblings without depending on the caller cwd.
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pkm_engine import Engine, API_VERSION, ACTIONS, atomic, digest

PKM_API_VERSION = API_VERSION


def capabilities():
    return {"apiVersion": PKM_API_VERSION, "actions": list(ACTIONS), "vaultIO": "obsidian-cli-vault-api"}


def execute_request(request, action, payload=None):
    return Engine(globals(), request).execute(action, payload or {})


def standalone_request(args):
    repo = str(Path(args.repo).resolve())
    ledger_path = str(Path(args.ledger or Path(repo) / "pkm-import" / "ledger.json").resolve())
    ledger = load_ledger(ledger_path)
    if args.vault_path:
        path = str(Path(args.vault_path).resolve())
        saved = ledger["profiles"].get(profile_key(path), {})
        target = dict(vault_path=path, vault_name=args.vault_name or saved.get("vault_name"), notes_folder=args.notes_folder or saved.get("notes_folder"))
    elif len(ledger["profiles"]) == 1:
        target = {k: next(iter(ledger["profiles"].values()))[k] for k in ("vault_path", "vault_name", "notes_folder")}
    else:
        raise Fatal("请通过 --vault-path/--vault-name/--notes-folder 指定本次目标")
    if not all(target.values()):
        raise Fatal("目标配置不完整")
    units = scan_archive(repo, [])
    if args.only:
        units = [u for u in units if args.only in u["bv"]]
    if not units:
        raise Fatal("没有标准总结候选")
    plan_path = Path(args.json).resolve()
    request = dict(schemaVersion=2, requestId=uuid.uuid4().hex, repo=repo, ledger=ledger_path, target=target,
                   plan=str(plan_path), state_root=str(plan_path.parent / ".pkm-runtime"),
                   units=[{k:u[k] for k in ("source_id", "source_sha256")} for u in units])
    sidecar = plan_path.with_suffix(".request.json")
    if sidecar.exists():
        previous = json.loads(sidecar.read_text())
        if any(previous.get(k) != request[k] for k in ("repo", "ledger", "target", "units")):
            raise Fatal("该计划路径已有其他请求，请使用新的 --json 路径")
        return previous
    atomic(sidecar, request)
    return request


def cmd_verify_all(ledger_path):
    # Explicit historical audit. Never claims template provenance or visual compliance.
    from pkm_vault import Vault
    ledger = load_ledger(ledger_path)
    results = []
    for key, profile in ledger["profiles"].items():
        vault = Vault(profile["vault_name"])
        if Path(vault.rpc("identity")["path"]).resolve() != Path(profile["vault_path"]).resolve():
            raise Fatal("库身份与台账不一致")
        for sid, entry in ledger["imports"].items():
            per = entry["per_profile"].get(key)
            if not per:
                continue
            raw = vault.read(per["target"])
            ok = raw is not None and f"<!-- pkm-import: source-id={sid} -->" in raw and bool(CREATED_TIME_RE.search(raw)) and "evidence/" not in raw
            attachments = re.findall(r"!\[\[([^\]|]+)\]\]", raw or "")
            for attachment in attachments:
                if not vault.rpc("stat", path=attachment):
                    ok = False
            results.append(dict(profile=key, source_id=sid, status="passed" if ok else "failed"))
    return dict(scope="ledger", checked=len(results), results=results, limitations=["历史巡检不证明身份生成来源、完整正文或显示效果合规"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("capabilities")
    request_cmd = sub.add_parser("request")
    request_cmd.add_argument("--request", required=True)
    request_cmd.add_argument("--action", choices=ACTIONS, required=True)
    request_cmd.add_argument("--payload", help="JSON 参数文件；省略时从 stdin 读取 JSON")
    for action in ("inspect", "plan"):
        command = sub.add_parser(action)
        command.add_argument("--repo", required=True)
        command.add_argument("--ledger")
        command.add_argument("--vault-path")
        command.add_argument("--vault-name")
        command.add_argument("--notes-folder")
        command.add_argument("--only")
        command.add_argument("--json", required=True, help="计划路径；同目录保存请求与恢复记录")
        command.add_argument("--parameters", help="现场确定的 JSON 参数文件；plan 必须提供")
    for action in ("apply", "verify", "status"):
        command = sub.add_parser(action)
        command.add_argument("--plan")
        command.add_argument("--plan-revision")
        if action == "verify":
            command.add_argument("--all", action="store_true")
            command.add_argument("--ledger")
    args = parser.parse_args()
    if args.command == "capabilities":
        result = capabilities()
    elif args.command == "request":
        request = json.loads(Path(args.request).read_text())
        payload = json.loads(Path(args.payload).read_text() if args.payload else sys.stdin.read() or "{}")
        result = execute_request(request, args.action, payload)
    elif args.command in ("inspect", "plan"):
        request = standalone_request(args)
        params = json.loads(Path(args.parameters).read_text()) if args.parameters else None
        inspection = execute_request(request, "inspect", {"readPaths": [params["template_path"]] if params else []})
        if args.command == "plan":
            if not params:
                raise Fatal("plan 必须传入 --parameters，本次参数须来自现场读取库规则")
            result = execute_request(request, "plan", {"parameters": params})
        else:
            result = inspection
    elif args.command == "verify" and args.all:
        if not args.ledger:
            raise Fatal("全台账巡检须指定 --ledger")
        result = cmd_verify_all(args.ledger)
    else:
        if not args.plan:
            raise Fatal("请指定 --plan；全台账巡检须显式使用 verify --all")
        request = json.loads(Path(args.plan).with_suffix(".request.json").read_text())
        if args.command in ("apply", "verify") and not args.plan_revision:
            raise Fatal("请显式传入已确认的 --plan-revision")
        result = execute_request(request, args.command, {"planRevision": args.plan_revision})
    print(json.dumps(result, ensure_ascii=False))
    return 1 if any(r.get("status") == "failed" for r in result.get("results", [])) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"error": str(error), "recover": "status"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
