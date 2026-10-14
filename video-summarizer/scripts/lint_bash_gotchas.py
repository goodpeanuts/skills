#!/usr/bin/env python3
"""lint_bash_gotchas.py —— 静态扫 skill 全部 bash 脚本的三类已知陷阱

定位是防御性代码体检：bash 3.2 的兼容性与 set -e 语义陷阱都已被
线上事故验证过（2026-10-14 全角变量尾随导致 unbound variable 崩溃扫过一次
6 处；更早还有「函数尾 [[ ]] && cmd 无 return」与「local 声明引用同组变量」
两处踩坑记录）。这些坑一旦再次出现只有到运行时才暴露，所以把规则做成扫
描器，在 unit tests 里运行，任何新增带坑的 .sh 交付前就会被拦下。

规则

A. `$var+全角/非 ASCII` 紧邻
   bash 3.2.57 在 UTF-8 locale 下把 `$x` 后第一字节（如 ）=U+FF09 的 0xEF）
   并入变量名 → 变量查找失败 → set -u 报 unbound variable。拦截所有
   双引号字符串内 `$[A-Za-z_]\\w*` 紧跟非 ASCII 字节的写法，建议写 `${x}…`。
   位置参数 $1/$2（数字）由 bash 按数字单字读，安全，规则内豁免。

B. bash 函数尾行是 `[[ ]] && cmd`（且函数体无显式 return）
   条件不成立时函数返回非零，若调用点把它当简单命令用 → set -e 整个脚本
   静默死掉且无任何输出。应改成 `if [[ ]]; then cmd; fi` 或接 `|| return 0`。

C. 同一行 `local a=x b=$a` 引用同组新声明变量
   local 的声明顺序不保证，b 取到的可能是未定义或外层 a。

用法:
  python3 lint_bash_gotchas.py [file.sh ...]      # 不带参数则扫 skill 全部 .sh
"""

from __future__ import annotations  # PEP 604 兼容 3.8/3.9

import argparse
import re
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = SKILL_DIR / "scripts"

# --- 规则 A: $var 紧邻非 ASCII ------------------------------------------------
# 只看引号内的 $var(排除已经 ${var} 形式),跳过数字位置参数与特殊参数,跳过纯 ASCII 后继
# 在字符类里排除「.」(解压归档/文件后缀场景常见,$x.log)以免过度报
RULE_A_RE = re.compile(r'"[^"\n]*?\$(?!\{)([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F.])')

# --- 规则 B: 函数尾 [[ cond ]] && cmd --------------------------------------
FUNC_TAIL_RE = re.compile(r"^\s*\[\[[^\]]+\]\]\s*&&\s*[^|#&]+?\s*$")

# --- 规则 C: 同一 local 声明行内互相引用 --------------------------------
RULE_C_RE = re.compile(r"\blocal\s+(?:\w+=\S+\s+)*(\w+)=\S+\s+(?:\w+=\S+\s+)*\w+=\$?\{?\1\}?\b")


def _is_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def _is_lint_exempt(line: str) -> bool:
    """行尾标注 # lint-exempt 的行跳过全部规则——用于 of_tests 里故意构造的反面 fixture。"""
    return "# lint-exempt" in line


def _find_rule_a(path: Path, src: str) -> list[str]:
    issues = []
    for lineno, line in enumerate(src.splitlines(), 1):
        if _is_comment(line) or _is_lint_exempt(line):
            continue
        # 剔除 heredoc 边界行(<<EOF / <<'EOF')与行内嵌套引号,只看最外层引号内 $var
        if "<<-?" in line and line.count('"') < 2:
            continue
        for m in RULE_A_RE.finditer(line):
            var = m.group(1)
            if var.isdigit():
                continue  # 位置参数数字安全
            tail_start = line[m.end():m.end() + 6]
            issues.append(
                f"  A  {path.name}:{lineno}  ${var} 紧邻非 ASCII（后续: {tail_start!r}）"
                "——bash 3.2 会把第一字节并入变量名，改写成 ${" + var + "}"
            )
    return issues


def _find_rule_b(path: Path, src: str) -> list[str]:
    """扫描每个 () { 函数体的最后一行。

    不处理 { 嵌套深度——$() 子壳不算函数定义，函数定义的 { 是行尾 '{',
    且我们已经在 _is_comment 跳过注释。
    """
    issues = []
    lines = src.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^\s*(?:function\s+)?(\w+)\s*\(\)\s*\{\s*$", line)
        if not m:
            i += 1
            continue
        # 函数起点 i,找匹配的 }(不在引号/注释内的裸行 '}')
        start = i
        i += 1
        while i < len(lines) and lines[i].rstrip() != "}":
            i += 1
        if i >= len(lines):
            break  # 未闭合函数,跳过
        end = i
        # body 是 start+1 .. end-1
        body = lines[start + 1:end]
        has_return = any(re.search(r"\breturn\b", b) for b in body)
        if has_return or not body:
            i = end + 1
            continue
        # 找 body 中最后一个非空、非 exempt 行
        last_idx = len(body) - 1
        while last_idx >= 0 and (not body[last_idx].strip() or _is_lint_exempt(body[last_idx])):
            last_idx -= 1
        if last_idx < 0:
            i = end + 1
            continue
        last = body[last_idx].strip()
        if FUNC_TAIL_RE.match(last):
            issues.append(
                f"  B  {path.name}:{start + 2 + last_idx}  函数尾行 `{last}` 且无显式 return"
                "——条件不成立时返回值非零,set -e 会静默杀脚本;改写成 if [[ ]]; then ... fi 或接 || return 0"
            )
        i = end + 1
    return issues


def _find_rule_c(path: Path, src: str) -> list[str]:
    issues = []
    for lineno, line in enumerate(src.splitlines(), 1):
        if _is_comment(line) or _is_lint_exempt(line):
            continue
        if not line.lstrip().startswith("local ") and " local " not in line:
            continue
        # 单行内多个赋值,后一个引用前面
        m = RULE_C_RE.search(line)
        if m:
            issues.append(
                f"  C  {path.name}:{lineno}  同行 local 声明引用同组变量: {m.group(0)!r}"
                "——声明顺序不保证,拆成两行"
            )
    return issues


RULES = (
    ("A", "bash 3.2 $var+全角 引发 unbound variable"),
    ("B", "bash 函数尾 [[ ]] && cmd 无 return 静默终止"),
    ("C", "local 同行声明引用同组变量 未定义"),
)


def _strip_heredocs(src: str) -> str:
    """剥离 heredoc body——它是字面字符串,bash 不会解析,误报根源。

    识别 <<EOF / <<'EOF' / <<-EOF / <<-"EOF" 的占位符,从下一行开始到单独一行
    只含该标识符为止,整段 body 行替换为空(保留行号,让规则报错行数仍然对得上)。
    """
    lines = src.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if m:
            marker = m.group(1)
            out.append(line)
            i += 1
            # body 行 + 收尾 marker 行
            while i < n:
                content = lines[i].rstrip("\n")
                if content == marker:
                    out.append(lines[i])  # 收尾 marker 行保留(函数尾判定可能需要)
                    i += 1
                    break
                out.append("\n")  # body 行清空,但保留行号
                i += 1
            continue
        out.append(line)
        i += 1
    return "".join(out)


def lint_file(path: Path) -> list[str]:
    src = path.read_text(encoding="utf-8")
    src = _strip_heredocs(src)
    return _find_rule_a(path, src) + _find_rule_b(path, src) + _find_rule_c(path, src)


def collect_files(args: argparse.Namespace) -> list[Path]:
    if args.files:
        return [Path(f).resolve() for f in args.files]
    if not SCRIPTS_DIR.is_dir():
        return []
    return sorted(SCRIPTS_DIR.rglob("*.sh"))


def main() -> int:
    ap = argparse.ArgumentParser(description="扫描 skill 全部 bash 脚本的已知陷阱")
    ap.add_argument("files", nargs="*", help="指定 .sh 文件;缺省扫 scripts/**/*.sh")
    args = ap.parse_args()

    files = collect_files(args)
    if not files:
        print("未发现 .sh 文件", file=sys.stderr)
        return 0

    all_issues: list[str] = []
    for f in files:
        all_issues.extend(lint_file(f))

    if all_issues:
        print(f"FAIL: {len(all_issues)} 处陷阱检出")
        print("规则:")
        for k, desc in RULES:
            print(f"  {k}  {desc}")
        print()
        for line in all_issues:
            print(line)
        return 1

    print(f"PASS: {len(files)} 个 .sh 未检出明显陷阱")
    return 0


if __name__ == "__main__":
    sys.exit(main())
