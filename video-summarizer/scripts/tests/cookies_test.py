"""Offline behavioral tests for the shared workspace store."""
import contextlib
import fcntl
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('cookie_manager', Path(__file__).parents[1] / 'ensure_cookies.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
URL = 'https://www.bilibili.com/video/BV1jEnE6vErq/'


def concurrent_ensure(root, snapshot):
    with patch.object(m, 'check_login', return_value='account'):
        m.CookieStore(root).ensure('bilibili', URL, snapshot)


def concurrent_refresh(root, snapshot):
    m.CookieStore(root).ensure('bilibili', URL, snapshot)


class CookieTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'workspace'
        self.root.mkdir()
        self.cache = self.root / 'cache'
        self.snapshot = Path(self.tmp.name) / 'snapshot.txt'
        self.store = m.CookieStore(self.root)

    def seed(self, value='valid', other=None):
        self.cache.mkdir(exist_ok=True)
        d = {'bilibili': {'cookies': {'SESSDATA': value, 'buvid3': 'device'}}, 'other': other or {'keep': True}}
        (self.cache / 'cookies.json').write_text(json.dumps(d))
        return (self.cache / 'cookies.json').read_bytes()

    def browser(self, args, **kwargs):
        exported = Path(args[args.index('--cookies') + 1])
        exported.write_text('# Netscape HTTP Cookie File\n.bilibili.com\tTRUE\t/\tTRUE\t2147483647\tSESSDATA\tfresh\n')
        return subprocess.CompletedProcess(args, 0, '', '')

    def test_valid_json_repairs_derived_without_browser(self):
        before = self.seed()
        (self.cache / '_bilibili.cookies.txt').write_text('STALE')
        with patch.object(m, 'check_login', return_value='account'), patch.object(self.store, 'run', wraps=self.store.run) as run:
            result = self.store.ensure('bilibili', URL, self.snapshot)
        self.assertEqual(result['source'], 'cache')
        self.assertFalse(any(call.args[0][0] == 'yt-dlp' for call in run.call_args_list))
        self.assertEqual((self.cache / 'cookies.json').read_bytes(), before)
        self.assertEqual(self.snapshot.read_bytes(), (self.cache / '_bilibili.cookies.txt').read_bytes())
        self.assertIn('valid', self.snapshot.read_text())
        for file in (self.cache / 'cookies.json', self.cache / '_bilibili.cookies.txt', self.snapshot):
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
        self.assertIn('/cache/', (self.root / '.gitignore').read_text())

    def test_invalid_json_refreshes_and_preserves_other_platform(self):
        self.seed('expired')
        real = self.store.run
        def run(args):
            return self.browser(args) if args[0] == 'yt-dlp' else real(args)
        with patch.object(m, 'check_login', side_effect=[None, 'account']), patch.object(self.store, 'run', side_effect=run):
            self.assertEqual(self.store.ensure('bilibili', URL, self.snapshot)['source'], 'chrome')
        d = json.loads((self.cache / 'cookies.json').read_text())
        self.assertEqual(d['bilibili']['cookies']['SESSDATA'], 'fresh')
        self.assertEqual(d['other'], {'keep': True})

    def test_missing_or_malformed_json_ignores_legacy_netscape(self):
        for original in (None, '{broken'):
            with self.subTest(original=original):
                self.cache.mkdir(exist_ok=True)
                p = self.cache / 'cookies.json'
                p.unlink(missing_ok=True)
                if original is not None:
                    p.write_text(original)
                (self.cache / '_bilibili.cookies.txt').write_text('LEGACY-VALID')
                real = self.store.run
                with patch.object(m, 'check_login', return_value='account') as login, patch.object(self.store, 'run', side_effect=lambda args: self.browser(args) if args[0] == 'yt-dlp' else real(args)):
                    result = self.store.ensure('bilibili', URL)
                self.assertEqual(result['source'], 'chrome')
                self.assertEqual(login.call_count, 1)
                self.assertEqual(login.call_args.args[1], 'fresh')

    def test_network_error_never_exports_or_overwrites(self):
        before = self.seed()
        with patch.object(m, 'check_login', side_effect=m.CookieError('network', 'network_error')), patch.object(self.store, 'run', wraps=self.store.run) as run:
            with self.assertRaises(m.CookieError) as error:
                self.store.ensure('bilibili', URL, self.snapshot)
        self.assertEqual(error.exception.code, 'network_error')
        self.assertFalse(any(call.args[0][0] == 'yt-dlp' for call in run.call_args_list))
        self.assertEqual((self.cache / 'cookies.json').read_bytes(), before)
        self.assertFalse(self.snapshot.exists())

    def test_failed_browser_keeps_old_credentials(self):
        before = self.seed('expired')
        real = self.store.run
        with patch.object(m, 'check_login', return_value=None), patch.object(self.store, 'run', side_effect=lambda args: subprocess.CompletedProcess(args, 1, '', 'PRIVATE') if args[0] == 'yt-dlp' else real(args)):
            with self.assertRaises(m.CookieError) as error:
                self.store.ensure('bilibili', URL)
        self.assertNotIn('PRIVATE', str(error.exception))
        self.assertEqual((self.cache / 'cookies.json').read_bytes(), before)
        self.assertFalse(list(self.cache.glob('.cookie-export-*')))

    def test_snapshot_failure_reports_error_no_persistent_fallback(self):
        self.seed()
        with patch.object(m, 'check_login', return_value='account'):
            with self.assertRaises(OSError):
                self.store.ensure('bilibili', URL, self.root / 'missing' / 'snapshot')
        self.assertTrue(json.loads((self.cache / 'cookies.json').read_text()))

    def test_lock_wait_is_bounded(self):
        self.cache.mkdir()
        with (self.cache / '.cookies.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaises(m.CookieError) as error:
                m.CookieStore(self.root, timeout=0.05).ensure('bilibili', URL)
        self.assertEqual(error.exception.code, 'timeout')

    def test_two_processes_share_complete_json_and_snapshots(self):
        before = self.seed()
        ctx = multiprocessing.get_context('fork')
        workers = [ctx.Process(target=concurrent_ensure, args=(self.root, Path(self.tmp.name) / ('snapshot%d' % i))) for i in range(2)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(10)
            self.assertFalse(worker.is_alive())
            self.assertEqual(worker.exitcode, 0)
        self.assertEqual((self.cache / 'cookies.json').read_bytes(), before)
        self.assertEqual((Path(self.tmp.name) / 'snapshot0').read_bytes(), (Path(self.tmp.name) / 'snapshot1').read_bytes())

    def test_concurrent_expiration_exports_once(self):
        self.seed('expired')
        marker = Path(self.tmp.name) / 'exports'
        original_run = m.CookieStore.run
        def run(store, args):
            if args[0] != 'yt-dlp':
                return original_run(store, args)
            with marker.open('a') as stream:
                stream.write('export\n')
            return self.browser(args)
        ctx = multiprocessing.get_context('fork')
        with patch.object(m, 'check_login', side_effect=lambda platform, value, timeout=15: None if value == 'expired' else 'account'), patch.object(m.CookieStore, 'run', new=run):
            workers = [ctx.Process(target=concurrent_refresh, args=(self.root, Path(self.tmp.name) / ('refreshed%d' % i))) for i in range(2)]
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(10)
                self.assertFalse(worker.is_alive())
                self.assertEqual(worker.exitcode, 0)
        self.assertEqual(marker.read_text().splitlines(), ['export'])
        d = json.loads((self.cache / 'cookies.json').read_text())
        self.assertEqual(d['other'], {'keep': True})
        self.assertEqual((Path(self.tmp.name) / 'refreshed0').read_bytes(), (Path(self.tmp.name) / 'refreshed1').read_bytes())

    def test_git_ignore_override_is_repaired(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / '.gitignore').write_text('cache/\n!cache/\n')
        self.seed()
        with patch.object(m, 'check_login', return_value='account'):
            self.store.ensure('bilibili', URL)
        for file in ('cache/cookies.json', 'cache/_bilibili.cookies.txt'):
            self.assertEqual(subprocess.run(['git', 'check-ignore', '-q', file], cwd=self.root).returncode, 0)

    def test_status_is_read_only(self):
        with patch.object(m, 'check_login') as login:
            self.assertEqual(self.store.status('bilibili')['state'], 'missing')
            login.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_tracked_credentials_are_refused_without_modification(self):
        self.seed()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', 'add', 'cache/cookies.json'], cwd=self.root, check=True)
        before = (self.cache / 'cookies.json').read_bytes()
        with patch.object(m, 'check_login') as login, self.assertRaises(m.CookieError) as error:
            self.store.ensure('bilibili', URL)
        self.assertEqual(error.exception.code, 'cache_tracked')
        login.assert_not_called()
        self.assertEqual((self.cache / 'cookies.json').read_bytes(), before)

    def test_workspaces_do_not_share_credentials(self):
        self.seed('first')
        other = Path(self.tmp.name) / 'other'; other.mkdir()
        other_store = m.CookieStore(other)
        with patch.object(m, 'check_login', return_value='account'):
            self.store.ensure('bilibili', URL, self.snapshot)
        self.assertEqual(other_store.status('bilibili')['state'], 'missing')
        self.assertFalse((other / 'cache').exists())

    def test_check_login_distinguishes_expiration_from_outage(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self): return b'{"code":-101,"data":{}}'
        with patch.object(m.urllib.request, 'urlopen', return_value=Response()):
            self.assertIsNone(m.check_login('bilibili', 'secret'))
        with patch.object(m.urllib.request, 'urlopen', side_effect=OSError('secret')):
            with self.assertRaises(m.CookieError) as error:
                m.check_login('bilibili', 'secret')
        self.assertEqual(error.exception.code, 'network_error')
        self.assertNotIn('secret', str(error.exception))


if __name__ == '__main__':
    unittest.main()
