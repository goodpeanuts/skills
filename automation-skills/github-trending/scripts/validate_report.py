#!/usr/bin/env python3
"""Validate GitHub Trending report outputs against strict contracts."""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterable

PERIODS = {"daily", "weekly", "monthly"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
GITHUB_URL_RE = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/?$")
OUTPUT_ROOT_NAME = ".github_trending"

REQUIRED_MD_FIELDS = ["是什么", "作用", "效果", "项目分析", "建议"]
REQUIRED_HTML_LABELS = {"是什么", "作用", "效果", "项目分析"}
REQUIRED_HTML_CLASSES = {"overview-section", "repo-card", "tag", "suggestion-box"}


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


@dataclass
class MarkdownEntry:
    rank: int
    repo: str
    url: str


@dataclass
class HtmlCard:
    rank: int | None = None
    repo_url: str | None = None
    labels: set[str] = field(default_factory=set)
    tag_count: int = 0
    has_suggestion: bool = False


class TrendingSourceParser(HTMLParser):
    """Extract repo links from GitHub Trending source page."""

    def __init__(self) -> None:
        super().__init__()
        self._article_depth = 0
        self._seen_in_article = False
        self.repos: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_map = dict(attrs)
        class_attr = attrs_map.get("class") or ""

        if tag == "article" and "Box-row" in class_attr:
            if self._article_depth == 0:
                self._seen_in_article = False
            self._article_depth += 1
            return

        if self._article_depth > 0 and tag == "a" and not self._seen_in_article:
            href = attrs_map.get("href") or ""
            # 跳过赞助链接，因为它不是真正的趋势项目仓库
            if "/sponsors/" in href:
                return
            repo = normalize_repo_path(href)
            if repo:
                self.repos.append(repo)
                self._seen_in_article = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "article" and self._article_depth > 0:
            self._article_depth -= 1
            if self._article_depth == 0:
                self._seen_in_article = False


class HtmlReportParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.cards: list[HtmlCard] = []
        self.classes_seen: set[str] = set()
        self.section_heading_found = False

        self._card_depth = 0
        self._current_card: HtmlCard | None = None
        self._p_depth = 0
        self.invalid_list_inside_p = False

        self._inside_repo_title = False
        self._repo_title_depth = 0
        self._repo_title_parts: list[str] = []

        self._inside_label = False
        self._label_parts: list[str] = []

        self._inside_h2 = False
        self._h2_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_map = dict(attrs)
        class_attr = attrs_map.get("class") or ""
        classes = {c.strip() for c in class_attr.split() if c.strip()}

        self.classes_seen.update(classes)

        if tag == "h2":
            self._inside_h2 = True
            self._h2_parts = []
        if tag == "p":
            self._p_depth += 1
        if tag in {"ul", "ol"} and self._p_depth > 0:
            self.invalid_list_inside_p = True

        if tag == "div":
            if "repo-card" in classes:
                if self._card_depth == 0:
                    self._current_card = HtmlCard()
                self._card_depth += 1
            elif self._card_depth > 0:
                self._card_depth += 1

            if self._card_depth > 0 and "repo-title" in classes:
                self._inside_repo_title = True
                self._repo_title_depth = self._card_depth
                self._repo_title_parts = []

            if self._card_depth > 0 and "suggestion-box" in classes and self._current_card:
                self._current_card.has_suggestion = True

        if self._card_depth > 0 and tag == "span":
            if "tag" in classes and self._current_card:
                self._current_card.tag_count += 1
            if "label" in classes:
                self._inside_label = True
                self._label_parts = []

        if self._card_depth > 0 and tag == "a" and self._current_card:
            href = attrs_map.get("href") or ""
            if GITHUB_URL_RE.match(href) and not self._current_card.repo_url:
                self._current_card.repo_url = href

    def handle_data(self, data: str) -> None:
        if self._inside_h2:
            self._h2_parts.append(data)
        if self._inside_repo_title:
            self._repo_title_parts.append(data)
        if self._inside_label:
            self._label_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "h2" and self._inside_h2:
            heading = "".join(self._h2_parts).strip()
            if "🚀 热门项目详细分析" in heading:
                self.section_heading_found = True
            self._inside_h2 = False
            self._h2_parts = []
        if tag == "p" and self._p_depth > 0:
            self._p_depth -= 1

        if tag == "span" and self._inside_label and self._current_card:
            label = normalize_label("".join(self._label_parts))
            if label:
                self._current_card.labels.add(label)
            self._inside_label = False
            self._label_parts = []

        if tag == "div" and self._card_depth > 0:
            if self._inside_repo_title and self._card_depth == self._repo_title_depth and self._current_card:
                title = "".join(self._repo_title_parts).strip()
                match = re.match(r"^(\d+)\.", title)
                if match:
                    self._current_card.rank = int(match.group(1))
                self._inside_repo_title = False
                self._repo_title_parts = []

            self._card_depth -= 1
            if self._card_depth == 0 and self._current_card:
                self.cards.append(self._current_card)
                self._current_card = None


def normalize_label(label: str) -> str:
    return label.strip().strip(":：").strip()


def normalize_repo_path(path: str) -> str | None:
    if not path:
        return None
    clean = path.strip()
    if clean.startswith("https://github.com/"):
        clean = clean[len("https://github.com/") :]
    clean = clean.lstrip("/").rstrip("/")
    if REPO_RE.fullmatch(clean):
        return clean
    return None


def repo_from_url(url: str) -> str | None:
    match = GITHUB_URL_RE.match(url)
    if not match:
        return None
    return match.group(1)


def dedupe_in_order(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result


def describe_repo_diff(expected: list[str], actual: list[str]) -> str:
    expected_set = set(expected)
    actual_set = set(actual)
    missing = [repo for repo in expected if repo not in actual_set]
    extra = [repo for repo in actual if repo not in expected_set]

    first_mismatch = None
    for idx, (exp, got) in enumerate(zip(expected, actual), start=1):
        if exp != got:
            first_mismatch = (idx, exp, got)
            break
    if first_mismatch is None and len(expected) != len(actual):
        idx = min(len(expected), len(actual)) + 1
        exp = expected[idx - 1] if len(expected) >= idx else "<none>"
        got = actual[idx - 1] if len(actual) >= idx else "<none>"
        first_mismatch = (idx, exp, got)

    parts: list[str] = []
    if first_mismatch:
        idx, exp, got = first_mismatch
        parts.append(f"first_mismatch_at={idx} expected={exp} actual={got}")
    if missing:
        parts.append(f"missing={missing}")
    if extra:
        parts.append(f"extra={extra}")
    return "; ".join(parts) if parts else "unknown difference"


def extract_source_repos(source_html: str) -> list[str]:
    parser = TrendingSourceParser()
    parser.feed(source_html)
    repos = dedupe_in_order(parser.repos)
    if repos:
        return repos

    fallback_h2 = re.findall(
        r"<h2[^>]*>\s*<a[^>]*href=\"/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\"",
        source_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    repos = dedupe_in_order(fallback_h2)
    if repos:
        return repos

    # Avoid generic href fallback here: it can capture unrelated repositories from
    # non-trending sections when page structure changes.
    return []


def parse_markdown_entries(md_text: str, result: ValidationResult) -> list[MarkdownEntry]:
    heading_pattern = re.compile(
        r"^###\s+(\d+)\.\s+\[([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\]\((https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?)\)$"
    )

    lines = md_text.splitlines()
    headings: list[tuple[int, int, str, str]] = []
    for idx, line in enumerate(lines):
        match = heading_pattern.match(line.strip())
        if match:
            headings.append((idx, int(match.group(1)), match.group(2), match.group(3)))

    if not headings:
        result.error("Markdown report has no valid repo headings: '### N. [owner/repo](https://github.com/owner/repo)'.")
        return []

    entries: list[MarkdownEntry] = []
    for i, (line_idx, rank, repo, url) in enumerate(headings):
        end = headings[i + 1][0] if i + 1 < len(headings) else len(lines)
        block = "\n".join(lines[line_idx:end])

        # Require at least one backtick tag line near heading.
        tag_region = "\n".join(lines[line_idx : min(end, line_idx + 4)])
        if not re.search(r"`[^`]+`", tag_region):
            result.error(f"Markdown repo #{rank} ({repo}) is missing tags line.")

        positions = []
        for field in REQUIRED_MD_FIELDS:
            field_match = re.search(rf"^\*\s+\*\*{re.escape(field)}\*\*:\s+.+", block, flags=re.MULTILINE)
            if not field_match:
                result.error(f"Markdown repo #{rank} ({repo}) is missing required field: {field}.")
                continue
            positions.append((field, field_match.start()))

        if len(positions) == len(REQUIRED_MD_FIELDS):
            ordered = [name for name, _ in sorted(positions, key=lambda x: x[1])]
            if ordered != REQUIRED_MD_FIELDS:
                result.error(
                    f"Markdown repo #{rank} ({repo}) fields are out of order. Expected: {' -> '.join(REQUIRED_MD_FIELDS)}."
                )

        entries.append(MarkdownEntry(rank=rank, repo=repo, url=url.rstrip("/")))

    expected_ranks = list(range(1, len(entries) + 1))
    actual_ranks = [entry.rank for entry in entries]
    if actual_ranks != expected_ranks:
        result.error(f"Markdown ranking must be sequential 1..N, got: {actual_ranks}.")

    return entries


def parse_html_cards(html_text: str) -> HtmlReportParser:
    parser = HtmlReportParser()
    parser.feed(html_text)
    return parser


def validate_manifest(manifest: dict, period: str, date: str, result: ValidationResult) -> list[dict]:
    required_fields = ["date", "period", "source_item_count", "reported_item_count", "repos"]
    for field in required_fields:
        if field not in manifest:
            result.error(f"Manifest missing required field: {field}.")

    if manifest.get("date") != date:
        result.error(f"Manifest date mismatch: expected {date}, got {manifest.get('date')}.")

    if manifest.get("period") != period:
        result.error(f"Manifest period mismatch: expected {period}, got {manifest.get('period')}.")

    source_count = manifest.get("source_item_count")
    reported_count = manifest.get("reported_item_count")
    repos = manifest.get("repos")

    if not isinstance(source_count, int):
        result.error("Manifest source_item_count must be integer.")
    if not isinstance(reported_count, int):
        result.error("Manifest reported_item_count must be integer.")
    if not isinstance(repos, list):
        result.error("Manifest repos must be a list.")
        return []

    normalized_repos: list[dict] = []
    for index, item in enumerate(repos, start=1):
        if not isinstance(item, dict):
            result.error(f"Manifest repos[{index}] must be object.")
            continue

        rank = item.get("rank")
        repo = item.get("repo")
        url = item.get("url")

        if rank != index:
            result.error(f"Manifest repos[{index}] rank must be {index}, got {rank}.")

        if not isinstance(repo, str) or not REPO_RE.fullmatch(repo):
            result.error(f"Manifest repos[{index}] repo is invalid: {repo}.")

        if not isinstance(url, str) or not GITHUB_URL_RE.fullmatch(url):
            result.error(f"Manifest repos[{index}] url is invalid: {url}.")

        if isinstance(repo, str) and isinstance(url, str):
            repo_from_manifest_url = repo_from_url(url)
            if repo_from_manifest_url and repo_from_manifest_url != repo:
                result.error(
                    f"Manifest repos[{index}] repo/url mismatch: repo={repo}, url={url}."
                )

        normalized_repos.append({"rank": rank, "repo": repo, "url": str(url).rstrip("/")})

    if isinstance(reported_count, int) and isinstance(repos, list) and reported_count != len(repos):
        result.error(
            f"Manifest reported_item_count ({reported_count}) does not match repos length ({len(repos)})."
        )

    return normalized_repos


def validate_report_dir(
    report_dir: Path,
    period: str,
    date: str,
    allow_small_source: bool = False,
) -> ValidationResult:
    result = ValidationResult()

    if period not in PERIODS:
        result.error(f"Invalid period: {period}. Expected one of {sorted(PERIODS)}.")
    if not DATE_RE.fullmatch(date):
        result.error(f"Invalid date: {date}. Expected YYYY-MM-DD.")

    expected_report_dir = (Path.home() / OUTPUT_ROOT_NAME / period / date).resolve()
    actual_report_dir = report_dir.expanduser().resolve()
    if actual_report_dir != expected_report_dir:
        result.error(
            "Report directory must be exactly under current user home: "
            f"expected '{expected_report_dir}', got '{actual_report_dir}'."
        )

    source_file = actual_report_dir / "original_trending.html"
    md_file = actual_report_dir / f"report_{date}.md"
    html_file = actual_report_dir / f"report_{date}.html"
    manifest_file = actual_report_dir / "report_manifest.json"

    required_files = [source_file, md_file, html_file, manifest_file]
    for file_path in required_files:
        if not file_path.exists():
            result.error(f"Missing required file: {file_path}.")

    if result.errors:
        return result

    source_text = source_file.read_text(encoding="utf-8", errors="ignore")
    if not source_text.strip():
        result.error("original_trending.html is empty.")
    md_text = md_file.read_text(encoding="utf-8", errors="ignore")
    html_text = html_file.read_text(encoding="utf-8", errors="ignore")

    try:
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        result.error(f"Manifest JSON parse error: {exc}.")
        return result

    source_repos = extract_source_repos(source_text)
    if not source_repos:
        result.error("Cannot extract repo list from original_trending.html.")

    markdown_entries = parse_markdown_entries(md_text, result)

    if "## 📊 概述与趋势分析" not in md_text:
        result.error("Markdown missing section heading: ## 📊 概述与趋势分析")
    if "## 🚀 热门项目详细分析" not in md_text:
        result.error("Markdown missing section heading: ## 🚀 热门项目详细分析")

    html_parser = parse_html_cards(html_text)

    for required_class in sorted(REQUIRED_HTML_CLASSES):
        if required_class not in html_parser.classes_seen:
            result.error(f"HTML missing required class usage: .{required_class}")

    if not html_parser.section_heading_found:
        result.error("HTML missing section heading: 🚀 热门项目详细分析")

    if html_parser.invalid_list_inside_p:
        result.error("HTML contains invalid nested structure: <p><ul>/<ol>.")

    body_match = re.search(r"<body[^>]*>(.*)</body>", html_text, flags=re.IGNORECASE | re.DOTALL)
    body_text = body_match.group(1) if body_match else html_text
    if "`" in body_text:
        result.error("HTML body contains Markdown backticks (`), which is disallowed.")

    html_cards = html_parser.cards
    html_ranks = [card.rank for card in html_cards]
    expected_html_ranks = list(range(1, len(html_cards) + 1))
    if html_ranks != expected_html_ranks:
        result.error(f"HTML card ranking must be sequential 1..N, got: {html_ranks}.")

    for idx, card in enumerate(html_cards, start=1):
        if not card.repo_url:
            result.error(f"HTML repo-card #{idx} is missing valid GitHub repo link.")
        if card.tag_count < 1:
            result.error(f"HTML repo-card #{idx} must include at least one .tag badge.")
        missing_labels = REQUIRED_HTML_LABELS - card.labels
        if missing_labels:
            result.error(
                f"HTML repo-card #{idx} is missing labels: {', '.join(sorted(missing_labels))}."
            )
        if not card.has_suggestion:
            result.error(f"HTML repo-card #{idx} is missing .suggestion-box.")

    manifest_repos = validate_manifest(manifest, period, date, result)

    counts = {
        "source": len(source_repos),
        "markdown": len(markdown_entries),
        "html": len(html_cards),
        "manifest_reported": manifest.get("reported_item_count") if isinstance(manifest, dict) else None,
        "manifest_repos": len(manifest_repos),
    }

    if isinstance(manifest.get("source_item_count"), int) and source_repos:
        if manifest.get("source_item_count") != len(source_repos):
            result.error(
                "Manifest source_item_count mismatch: "
                f"manifest={manifest.get('source_item_count')}, extracted={len(source_repos)}."
            )

    if len({counts["source"], counts["markdown"], counts["html"], counts["manifest_repos"]}) > 1:
        result.error(f"Cross-file count mismatch: {counts}.")

    if isinstance(counts["manifest_reported"], int):
        if counts["manifest_reported"] != counts["manifest_repos"]:
            result.error(
                "Manifest reported_item_count mismatch with repos length: "
                f"reported={counts['manifest_reported']}, repos={counts['manifest_repos']}."
            )

    if markdown_entries and manifest_repos:
        md_repos = [entry.repo for entry in markdown_entries]
        mf_repos = [item["repo"] for item in manifest_repos if isinstance(item.get("repo"), str)]
        if md_repos != mf_repos:
            result.error("Markdown repo order/content does not match manifest repos.")

    if html_cards and manifest_repos:
        html_repos = [repo_from_url(card.repo_url or "") for card in html_cards]
        mf_repos = [item["repo"] for item in manifest_repos if isinstance(item.get("repo"), str)]
        if html_repos != mf_repos:
            result.error("HTML repo order/content does not match manifest repos.")

    # Critical omission check: source repo identities must match each output in order.
    if source_repos and markdown_entries:
        md_repos = [entry.repo for entry in markdown_entries]
        if md_repos != source_repos:
            result.error(
                "Source vs Markdown repo mismatch: "
                + describe_repo_diff(expected=source_repos, actual=md_repos)
            )

    if source_repos and html_cards:
        html_repos = [repo_from_url(card.repo_url or "") for card in html_cards]
        normalized_html_repos = [repo for repo in html_repos if repo]
        if normalized_html_repos != source_repos:
            result.error(
                "Source vs HTML repo mismatch: "
                + describe_repo_diff(expected=source_repos, actual=normalized_html_repos)
            )

    if source_repos and manifest_repos:
        mf_repos = [item["repo"] for item in manifest_repos if isinstance(item.get("repo"), str)]
        if mf_repos != source_repos:
            result.error(
                "Source vs Manifest repo mismatch: "
                + describe_repo_diff(expected=source_repos, actual=mf_repos)
            )

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate GitHub Trending report output directory.")
    parser.add_argument(
        "--report-dir",
        required=True,
        help="Path to report directory (must be: ~/.github_trending/<period>/<date>)",
    )
    parser.add_argument("--period", required=True, choices=sorted(PERIODS))
    parser.add_argument("--date", required=True, help="Date in YYYY-MM-DD format")
    parser.add_argument(
        "--allow-small-source",
        action="store_true",
        help="Deprecated no-op flag kept for backward compatibility.",
    )
    args = parser.parse_args()

    result = validate_report_dir(
        report_dir=Path(args.report_dir),
        period=args.period,
        date=args.date,
        allow_small_source=args.allow_small_source,
    )

    if result.errors:
        print("VALIDATION FAILED")
        for idx, error in enumerate(result.errors, start=1):
            print(f"{idx}. {error}")
        if result.warnings:
            print("WARNINGS")
            for idx, warning in enumerate(result.warnings, start=1):
                print(f"{idx}. {warning}")
        return 1

    print("VALIDATION PASSED")
    if result.warnings:
        print("WARNINGS")
        for idx, warning in enumerate(result.warnings, start=1):
            print(f"{idx}. {warning}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
