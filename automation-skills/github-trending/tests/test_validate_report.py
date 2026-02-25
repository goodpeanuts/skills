import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATE_SCRIPT = ROOT / "scripts" / "validate_report.py"
CHECK_SCRIPT = ROOT / "scripts" / "check_existing_report.py"
FIXTURES = ROOT / "tests" / "fixtures"
PERIOD = "weekly"
DATE = "2026-02-17"


def run_validator(
    report_dir: Path,
    period: str,
    date: str,
    allow_small_source: bool = False,
    env: dict[str, str] | None = None,
):
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
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, env=env)


def run_existing_check(
    period: str,
    date: str,
    allow_small_source: bool = False,
    env: dict[str, str] | None = None,
):
    cmd = [
        sys.executable,
        str(CHECK_SCRIPT),
        "--period",
        period,
        "--date",
        date,
    ]
    if allow_small_source:
        cmd.append("--allow-small-source")
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, env=env)


def home_env(temp_home: str) -> dict[str, str]:
    env = os.environ.copy()
    env["HOME"] = temp_home
    return env


def stage_fixture_under_home(
    temp_home: str,
    fixture_dir: Path,
    period: str = PERIOD,
    date: str = DATE,
    hidden_root: bool = True,
) -> Path:
    root_name = ".github_trending" if hidden_root else "github_trending"
    report_dir = Path(temp_home) / root_name / period / date
    report_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(fixture_dir, report_dir, dirs_exist_ok=True)
    return report_dir


class ValidateReportTests(unittest.TestCase):
    def test_pass_fixture(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            report_dir = stage_fixture_under_home(temp_home, FIXTURES / "pass" / PERIOD / DATE)
            result = run_validator(report_dir, period=PERIOD, date=DATE, allow_small_source=False, env=env)
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            self.assertIn("VALIDATION PASSED", result.stdout)

    def test_allow_small_source_flag_is_noop(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            report_dir = stage_fixture_under_home(temp_home, FIXTURES / "pass" / PERIOD / DATE)
            result = run_validator(report_dir, period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            self.assertIn("VALIDATION PASSED", result.stdout)

    def test_fail_count_mismatch(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            report_dir = stage_fixture_under_home(temp_home, FIXTURES / "fail" / "count_mismatch" / PERIOD / DATE)
            result = run_validator(report_dir, period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Cross-file count mismatch", result.stdout)

    def test_fail_html_structure(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            report_dir = stage_fixture_under_home(temp_home, FIXTURES / "fail" / "html_structure" / PERIOD / DATE)
            result = run_validator(report_dir, period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("<p><ul>/<ol>", result.stdout)

    def test_fail_source_repo_mismatch(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            report_dir = stage_fixture_under_home(temp_home, FIXTURES / "fail" / "source_repo_mismatch" / PERIOD / DATE)
            result = run_validator(report_dir, period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Source vs Markdown repo mismatch", result.stdout)

    def test_fail_report_dir_outside_home(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            outside_report_dir = FIXTURES / "pass" / PERIOD / DATE
            result = run_validator(outside_report_dir, period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be exactly under current user home", result.stdout)

    def test_fail_report_dir_in_non_hidden_home_folder(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            wrong_report_dir = stage_fixture_under_home(
                temp_home,
                FIXTURES / "pass" / PERIOD / DATE,
                hidden_root=False,
            )
            result = run_validator(wrong_report_dir, period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be exactly under current user home", result.stdout)

    def test_check_existing_report_valid(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            report_dir = stage_fixture_under_home(temp_home, FIXTURES / "pass" / PERIOD / DATE)
            result = run_existing_check(period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            self.assertIn("existing_valid", result.stdout)
            payload = json.loads(result.stdout)
            self.assertEqual(Path(payload["report_dir"]), report_dir)

    def test_check_existing_report_missing(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            result = run_existing_check(period=PERIOD, date="2026-02-18", allow_small_source=True, env=env)
            self.assertEqual(result.returncode, 10, msg=result.stdout + result.stderr)
            self.assertIn("missing", result.stdout)

    def test_check_existing_report_invalid(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            stage_fixture_under_home(temp_home, FIXTURES / "fail" / "source_repo_mismatch" / PERIOD / DATE)
            result = run_existing_check(period=PERIOD, date=DATE, allow_small_source=True, env=env)
            self.assertEqual(result.returncode, 20, msg=result.stdout + result.stderr)
            self.assertIn("existing_invalid", result.stdout)

    def test_check_existing_report_default_base_dir_is_home(self):
        with tempfile.TemporaryDirectory() as temp_home:
            env = home_env(temp_home)
            result = run_existing_check(
                period=PERIOD,
                date="2026-02-18",
                allow_small_source=True,
                env=env,
            )
            self.assertEqual(result.returncode, 10, msg=result.stdout + result.stderr)
            payload = json.loads(result.stdout)
            expected_report_dir = Path(temp_home) / ".github_trending" / PERIOD / "2026-02-18"
            expected_base_dir = Path(temp_home) / ".github_trending"
            self.assertEqual(Path(payload["report_dir"]), expected_report_dir)
            self.assertEqual(Path(payload["base_dir"]), expected_base_dir)
            self.assertEqual(payload["status"], "missing")


if __name__ == "__main__":
    unittest.main()
