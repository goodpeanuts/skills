"""Run the actual shell pipeline with deterministic site/download adapters."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SKILL = Path(__file__).parents[2]
URL = 'https://www.bilibili.com/video/BV1jEnE6vErq/'


class PipelineCookieTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.skill = self.base / 'skill'
        shutil.copytree(SKILL / 'scripts', self.skill / 'scripts', ignore=shutil.ignore_patterns('tests', '__pycache__'))
        config = self.skill / 'scripts/platforms.json'
        d = json.loads(config.read_text())
        d['bilibili'].update(season_lookup=None, comments=None, danmaku=None)
        config.write_text(json.dumps(d))
        self.workspace = self.base / 'workspace'; self.workspace.mkdir()
        (self.workspace / 'cache').mkdir()
        self.cached = self.workspace / 'cache/cookies.json'
        self.cached.write_text(json.dumps({'bilibili': {'cookies': {'SESSDATA': 'valid'}}}))
        self.bin = self.base / 'bin'; self.bin.mkdir()
        self.state = self.base / 'state.json'; self.state.write_text('{}')
        self.calls = self.base / 'calls.jsonl'
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'TEST_STATE': str(self.state), 'TEST_CALLS': str(self.calls),
                    'PYTHONDONTWRITEBYTECODE': '1'}
        self.executable('python3', '''import importlib.util,os,sys
from unittest.mock import patch
if len(sys.argv)>1 and sys.argv[1].endswith('/ensure_cookies.py'):
 p=sys.argv[1];sys.argv=sys.argv[1:]
 spec=importlib.util.spec_from_file_location('cookies',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 with open(os.environ['TEST_CALLS'],'a') as f:f.write('ensure\\n')
 def login(platform,value,timeout=15):
  if os.environ.get('TEST_SCENARIO')=='network':raise m.CookieError('network unavailable','network_error')
  return None if value=='expired' else 'account'
 with patch.object(m,'check_login',side_effect=login):m.main()
else:os.execv(sys.executable,[sys.executable]+sys.argv[1:])
''')
        self.executable('yt-dlp', '''import json,os,pathlib,sys
args=sys.argv[1:];p=pathlib.Path(os.environ['TEST_STATE']);d=json.loads(p.read_text());scenario=os.environ['TEST_SCENARIO']
with open(os.environ['TEST_CALLS'],'a') as f:f.write(json.dumps(args)+'\\n')
if '--cookies-from-browser' in args:
 path=pathlib.Path(args[args.index('--cookies')+1]);path.write_text('# Netscape HTTP Cookie File\\n.bilibili.com\\tTRUE\\t/\\tTRUE\\t2147483647\\tSESSDATA\\tfresh\\n');sys.exit(0)
if '--cookies' in args:
 with open(args[args.index('--cookies')+1],'a') as f:f.write('# downloader working copy\\n')
if '-J' in args:
 d['probes']=d.get('probes',0)+1;p.write_text(json.dumps(d));lang='ai-zh'
 if scenario in ('none','recover') and (d['probes']==1 or scenario=='none'):lang=None
 if scenario=='download' and d['probes']>1:lang='zh-Hans'
 print(json.dumps({'id':'BV1jEnE6vErq','extractor_key':'BiliBili','title':'Test','webpage_url':args[-1],
  'duration':10,'formats':[{'vcodec':'h264','acodec':'aac'}], 'playlist_id':'original-collection' if d['probes']==1 else None,
  'subtitles':{lang:[{'ext':'srt'}]} if lang else {}}));sys.exit(0)
base=pathlib.Path(args[args.index('-o')+1])
if '--sub-lang' in args:
 d['downloads']=d.get('downloads',0)+1;p.write_text(json.dumps(d))
 if scenario=='download' and d['downloads']==1:sys.exit(1)
 path=pathlib.Path(str(base)+'.'+args[args.index('--sub-lang')+1]+'.srt');path.write_text('1\\n00:00:00,000 --> 00:00:01,000\\nsubtitle\\n')
elif '--skip-download' not in args:
 path=pathlib.Path(str(base).replace('%(ext)s','m4a' if 'audio' in str(base) else 'mp4'));path.write_bytes(b'media')
''')
        self.executable('ffmpeg', 'import pathlib,sys\npathlib.Path(sys.argv[-1]).write_bytes(b"audio")\n')
        (self.skill / 'scripts/extract_frames.sh').write_text('#!/bin/bash\necho "frames: extracted=0"\n')

    def executable(self, name, source):
        p = self.bin / name
        p.write_text('#!' + sys.executable + '\n' + source)
        p.chmod(0o755)

    def run_pipeline(self, scenario, deep=False):
        if deep:
            subprocess.run(['bash', str(self.skill / 'scripts/pipeline_prepare.sh'), 'init'], cwd=self.workspace, env=self.env, check=True, capture_output=True)
        command = ['bash', str(self.skill / 'scripts/pipeline_prepare.sh')]
        command += [URL] if deep else ['quick', URL]
        result = subprocess.run(command, cwd=self.workspace, env={**self.env, 'TEST_SCENARIO': scenario}, capture_output=True, text=True, timeout=30)
        if scenario == 'network':
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout.strip().splitlines()[-1])
        calls = self.calls.read_text().splitlines()
        for line in calls:
            if line.startswith('['):
                args = json.loads(line)
                if '--cookies' in args and '--cookies-from-browser' not in args:
                    cookie = Path(args[args.index('--cookies') + 1])
                    self.assertNotIn(self.workspace / 'cache', cookie.parents)
        self.assertTrue((self.workspace / data['folder'] / 'raw/meta.json').is_file())
        return data, calls

    def test_quick_reprobes_missing_subtitle_and_archives(self):
        data, calls = self.run_pipeline('recover')
        self.assertEqual(data['subtitle_lang'], 'ai-zh')
        self.assertEqual(data['needs_whisper'], 0)
        self.assertEqual(calls.count('ensure'), 2)
        self.assertFalse(data['audio_file'])
        self.assertTrue((self.workspace / data['subtitle_file']).is_file())

    def test_download_retry_uses_reprobed_language(self):
        data, calls = self.run_pipeline('download')
        self.assertEqual(data['subtitle_lang'], 'zh-Hans')
        self.assertEqual(data['needs_whisper'], 0)
        self.assertEqual(calls.count('ensure'), 2)
        downloads = [json.loads(c) for c in calls if c.startswith('[') and '--sub-lang' in json.loads(c)]
        self.assertEqual([args[args.index('--sub-lang') + 1] for args in downloads], ['ai-zh', 'zh-Hans'])

    def test_no_subtitles_stops_retrying_and_prepares_audio(self):
        data, calls = self.run_pipeline('none')
        self.assertEqual(data['needs_whisper'], 1)
        self.assertEqual(calls.count('ensure'), 2)
        self.assertEqual(json.loads(self.state.read_text())['probes'], 2)
        self.assertTrue((self.workspace / data['audio_file']).exists())

    def test_cookie_network_failure_is_not_no_subtitles(self):
        before = self.cached.read_bytes()
        result = self.run_pipeline('network')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cookie 准备失败', result.stderr)
        self.assertNotIn('needs_whisper', result.stdout)
        self.assertEqual(self.cached.read_bytes(), before)
        self.assertEqual(self.calls.read_text().splitlines(), ['ensure'])

    def test_deep_uses_same_store_and_keeps_original_collection(self):
        data, calls = self.run_pipeline('recover', deep=True)
        self.assertEqual(data['subtitle_lang'], 'ai-zh')
        self.assertEqual(data['needs_whisper'], 0)
        self.assertEqual(calls.count('ensure'), 2)
        meta = json.loads((self.workspace / data['folder'] / 'raw/meta.json').read_text())
        self.assertEqual(meta['collection']['id'], 'original-collection')

    def test_comments_read_explicit_workspace_even_with_different_cwd(self):
        spec = importlib.util.spec_from_file_location('audience', self.skill / 'scripts/audience.py')
        audience = importlib.util.module_from_spec(spec); spec.loader.exec_module(audience)
        self.assertEqual(audience.load_sessdata(str(self.workspace)), 'valid')


if __name__ == '__main__':
    unittest.main()
