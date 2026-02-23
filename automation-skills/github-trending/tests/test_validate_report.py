import subprocess
import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATE_SCRIPT = ROOT / "scripts" / "validate_report.py"
CHECK_SCRIPT = ROOT / "scripts" / "check_existing_report.py"


def run_validator(report_dir: Path, period: str, date: str, allow_small_source: bool = False):
    cmd = [
        sys.executable,
        str(VALIDATE_SCRIPT),
        "--report-dir",
        str(report_dir),
        "--period",
        period,
        "--date",
        date,
    ]
    if allow_small_source:
        cmd.append("--allow-small-source")
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)


def run_existing_check(base_dir: Path, period: str, date: str, allow_small_source: bool = False):
    cmd = [
        sys.executable,
        str(CHECK_SCRIPT),
        "--base-dir",
        str(base_dir),
        "--period",
        period,
        "--date",
        date,
    ]
    if allow_small_source:
        cmd.append("--allow-small-source")
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)


class ValidateReportTests(unittest.TestCase):
    def test_pass_fixture(self):
        report_dir = ROOT / "tests" / "fixtures" / "pass" / "weekly" / "2026-02-17"
        result = run_validator(report_dir, period="weekly", date="2026-02-17", allow_small_source=True)
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("VALIDATION PASSED", result.stdout)

    def test_fail_without_allow_small_source(self):
        report_dir = ROOT / "tests" / "fixtures" / "pass" / "weekly" / "2026-02-17"
        result = run_validator(report_dir, period="weekly", date="2026-02-17", allow_small_source=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("<10", result.stdout)

    def test_fail_count_mismatch(self):
        report_dir = ROOT / "tests" / "fixtures" / "fail" / "count_mismatch" / "weekly" / "2026-02-17"
        result = run_validator(report_dir, period="weekly", date="2026-02-17", allow_small_source=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cross-file count mismatch", result.stdout)

    def test_fail_html_structure(self):
        report_dir = ROOT / "tests" / "fixtures" / "fail" / "html_structure" / "weekly" / "2026-02-17"
        result = run_validator(report_dir, period="weekly", date="2026-02-17", allow_small_source=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("<p><ul>/<ol>", result.stdout)

    def test_fail_source_repo_mismatch(self):
        report_dir = ROOT / "tests" / "fixtures" / "fail" / "source_repo_mismatch" / "weekly" / "2026-02-17"
        result = run_validator(report_dir, period="weekly", date="2026-02-17", allow_small_source=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source vs Markdown repo mismatch", result.stdout)

    def test_check_existing_report_valid(self):
        base_dir = ROOT / "tests" / "fixtures" / "pass"
        result = run_existing_check(base_dir, period="weekly", date="2026-02-17", allow_small_source=True)
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
        self.assertIn("existing_valid", result.stdout)

    def test_check_existing_report_missing(self):
        base_dir = ROOT / "tests" / "fixtures" / "pass"
        result = run_existing_check(base_dir, period="weekly", date="2026-02-18", allow_small_source=True)
        self.assertEqual(result.returncode, 10, msg=result.stdout + result.stderr)
        self.assertIn("missing", result.stdout)

    def test_check_existing_report_invalid(self):
        base_dir = ROOT / "tests" / "fixtures" / "fail" / "source_repo_mismatch"
        result = run_existing_check(base_dir, period="weekly", date="2026-02-17", allow_small_source=True)
        self.assertEqual(result.returncode, 20, msg=result.stdout + result.stderr)
        self.assertIn("existing_invalid", result.stdout)


if __name__ == "__main__":
    unittest.main()
