#!/usr/bin/env python3
"""Pre-send/report-generation guard for GitHub Trending reports.
Exit codes:
- 0: report exists and is valid (skip generation, safe to send)
- 10: report missing (generation required)
- 20: report exists but invalid (regeneration required)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from validate_report import PERIODS, validate_report_dir


def build_paths(base_dir: Path, period: str, date: str) -> dict[str, Path]:
    report_dir = base_dir / period / date
    return {
        "report_dir": report_dir,
        "source_file": report_dir / "original_trending.html",
        "md_file": report_dir / f"report_{date}.md",
        "html_file": report_dir / f"report_{date}.html",
        "manifest_file": report_dir / "report_manifest.json",
    }


def check_existing_report(
    base_dir: Path,
    period: str,
    date: str,
    allow_small_source: bool = False,
) -> tuple[int, dict[str, object]]:
    paths = build_paths(base_dir=base_dir, period=period, date=date)
    html_exists = paths["html_file"].exists()

    payload: dict[str, object] = {
        "period": period,
        "date": date,
        "report_dir": str(paths["report_dir"]),
        "source_file": str(paths["source_file"]),
        "md_file": str(paths["md_file"]),
        "html_file": str(paths["html_file"]),
        "manifest_file": str(paths["manifest_file"]),
    }

    if not html_exists:
        payload["status"] = "missing"
        payload["action"] = "generate"
        return 10, payload

    result = validate_report_dir(
        report_dir=paths["report_dir"],
        period=period,
        date=date,
        allow_small_source=allow_small_source,
    )

    if result.errors:
        payload["status"] = "existing_invalid"
        payload["action"] = "regenerate"
        payload["errors"] = result.errors
        if result.warnings:
            payload["warnings"] = result.warnings
        return 20, payload

    payload["status"] = "existing_valid"
    payload["action"] = "reuse_and_send"
    if result.warnings:
        payload["warnings"] = result.warnings
    return 0, payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Check whether a report already exists and is valid.")
    parser.add_argument("--period", required=True, choices=sorted(PERIODS))
    parser.add_argument("--date", required=True, help="Date in YYYY-MM-DD")
    parser.add_argument("--base-dir", default="github_trending", help="Base output directory")
    parser.add_argument(
        "--allow-small-source",
        action="store_true",
        help="Allow source item count below 10 during validation.",
    )
    args = parser.parse_args()

    exit_code, payload = check_existing_report(
        base_dir=Path(args.base_dir),
        period=args.period,
        date=args.date,
        allow_small_source=args.allow_small_source,
    )
    print(json.dumps(payload, ensure_ascii=False))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
