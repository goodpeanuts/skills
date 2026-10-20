"""Observable archive contracts using actual shell/finish/verify with offline adapters."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import pipeline_cookies_test as fixtures

URL = fixtures.URL


class ArchiveModesTests(unittest.TestCase):
    executable = fixtures.PipelineCookieTests.executable
    def setUp(self):
        fixtures.PipelineCookieTests.setUp(self)
        p = self.bin / 'yt-dlp'
        s = p.read_text().replace("'title':'Test'", "'title':'Test '+os.environ.get('TEST_REV','one'),'description':os.environ.get('TEST_REV','one'),'tags':[os.environ.get('TEST_REV','one')]")
        marker = "if '--sub-lang' in args:"
        s = s.replace(marker, """if '--write-comments' in args:
 path=pathlib.Path(str(base)+'.info.json');path.write_text(json.dumps({'id':'BV1jEnE6vErq','comments':[{'id':'c1','text':os.environ.get('TEST_REV','one'),'like_count':1}]}));sys.exit(0)
""" + marker)
        p.write_text(s)
        (self.skill / 'scripts/extract_frames.sh').write_text('#!/bin/bash\nmkdir -p "$2"\nprintf "%s" "${TEST_REV:-one}" > "$2/00-00-01.jpg"\necho "frames: extracted=1"\n')
        self.env.update(TEST_SCENARIO='recover', TEST_REV='one')

    def invoke(self, *args, ok=True):
        r = subprocess.run(['bash', str(self.skill / 'scripts/pipeline_prepare.sh'), *args], cwd=self.workspace, env=self.env,
                           capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout)
        return r

    def prepare(self, mode, force=False):
        args = ['quick'] if mode == 'quick' else []
        args += [URL]
        if force: args.append('--force')
        r = self.invoke(*args)
        return json.loads(r.stdout.splitlines()[-1])

    def publish(self, h, content='第一轮', ok=True, invalid=False):
        Path(h['summary_output']).write_text('# Test\n\n> bilibili · author · 时长 10秒 · [原片]('+URL+') · 总结于 2026-10-20 · test-model · test-harness\n\n'+
             ('基于字幕及文本资料生成，未分析画面。\n' if h['mode']=='quick' else '')+'## TL;DR\n'+content if not invalid else '# bad')
        Path(h['evidence_output']).write_text('# 来源底稿\n本轮字幕与评论：'+content)
        return self.invoke('finish', '--folder', h['folder'], '--mode', h['mode'], '--run-id', h['run_id'],
                           '--agent-model', 'test-model', '--harness', 'test-harness', *(['--part', str(h['part'])] if h['part'] else []), ok=ok)

    def meta(self, h):
        suffix = f"_{h['part']:02d}" if h['part'] else ''
        return json.loads((self.workspace / h['folder'] / f'raw/meta{suffix}.json').read_text())

    def test_modes_share_stable_material_and_refresh_dynamic_text(self):
        q = self.prepare('quick'); self.publish(q)
        folder = self.workspace / q['folder']
        subtitle = folder / 'raw/subtitle.srt'
        stamp = subtitle.stat().st_mtime_ns
        self.assertFalse((folder / 'raw/video.mp4').exists())
        self.assertFalse((folder / 'evidence/frames').exists())
        self.env['TEST_REV'] = 'two'
        d = self.prepare('deep'); self.assertEqual(q['folder'], d['folder']); self.publish(d, '标准第二轮')
        self.assertEqual(subtitle.stat().st_mtime_ns, stamp)
        self.assertEqual((folder / 'evidence/audience.json').is_file(), True)
        self.assertEqual(json.loads((folder / 'evidence/audience.json').read_text())['comments']['top'][0]['text'], 'two')
        m = self.meta(d)
        self.assertEqual(m['description'], 'two')
        self.assertEqual(set(m['summaries']), {'quick','deep'})
        stable = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in (folder / 'raw').glob('*') if p.suffix != '.json'}
        frame = folder / 'evidence/frames/00-00-01.jpg'
        frame_before = (frame.read_bytes(), frame.stat().st_mtime_ns)
        standard = (folder / 'summary.md').read_text()
        standard_record = self.meta(d)['summaries']['deep']
        self.env['TEST_REV'] = 'three'
        q2 = self.prepare('quick', True); self.publish(q2, '快速第三轮')
        self.assertEqual((folder / 'summary.md').read_text(), standard)
        self.assertEqual((frame.read_bytes(), frame.stat().st_mtime_ns), frame_before)
        for name, before in stable.items():
            p=Path(name); self.assertEqual((p.read_bytes(), p.stat().st_mtime_ns), before)
        m = self.meta(q2)
        self.assertEqual(m['description'], 'three')
        self.assertEqual(m['files']['video'], d['video_file'])
        self.assertEqual(m['summaries']['deep'], standard_record)
        self.assertEqual(m['frames']['extracted'], 1)
        evidence=(folder / 'evidence/evidence.md').read_text()
        self.assertIn('快速第三轮', evidence); self.assertIn('标准第二轮', evidence); self.assertNotIn('第一轮', evidence)
        self.invoke('verify', '--folder', q['folder'])
        self.assertFalse(list(folder.rglob('*.stale')))
        self.assertFalse(list(folder.rglob('*.bak')))
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ['brief.md','evidence','raw','summary.md'])

    def test_same_mode_needs_confirmation_but_other_mode_does_not(self):
        q=self.prepare('quick'); self.publish(q)
        r=self.invoke('quick',URL,ok=False)
        self.assertIn('确认',r.stderr)
        d=self.prepare('deep'); self.publish(d)
        self.invoke(URL,ok=False)
        q2=self.prepare('quick',True); self.publish(q2,'新快速')
        self.assertIn('新快速',(self.workspace/q['folder']/'brief.md').read_text())

    def test_invalid_candidate_and_cancel_preserve_existing_products(self):
        q=self.prepare('quick'); self.publish(q)
        folder=self.workspace/q['folder']; before=(folder/'brief.md').read_bytes()
        q2=self.prepare('quick',True)
        self.publish(q2,invalid=True,ok=False)
        self.assertEqual((folder/'brief.md').read_bytes(),before)
        self.invoke('abort','--folder',q['folder'],'--run-id',q2['run_id'])
        self.assertEqual(self.meta(q)['last_run']['status'],'cancelled')
        self.assertEqual((folder/'brief.md').read_bytes(),before)

    def test_existing_standard_can_create_quick_without_reading_or_changing_frames(self):
        d=self.prepare('deep'); self.publish(d)
        folder=self.workspace/d['folder']; media=(folder/'raw/video.mp4').stat().st_mtime_ns
        frame=(folder/'evidence/frames/00-00-01.jpg').read_bytes()
        q=self.prepare('quick'); self.publish(q)
        self.assertEqual((folder/'raw/video.mp4').stat().st_mtime_ns,media)
        self.assertEqual((folder/'evidence/frames/00-00-01.jpg').read_bytes(),frame)
        self.assertEqual(set(self.meta(q)['summaries']),{'quick','deep'})

    def test_pending_run_requires_explicit_resume_and_stale_finish_is_rejected(self):
        q=self.prepare('quick')
        self.invoke(URL,ok=False)
        resumed=json.loads(self.invoke('quick',URL,'--resume').stdout.splitlines()[-1])
        self.assertEqual(resumed,q)
        self.invoke('finish','--folder',q['folder'],'--mode','quick','--run-id','wrong',
                    '--agent-model','m','--harness','h',ok=False)
        self.publish(q)

    def test_standard_refreshes_frames_without_redownloading_stable_media(self):
        d=self.prepare('deep'); self.publish(d)
        folder=self.workspace/d['folder']; video=folder/'raw/video.mp4'
        stamp=video.stat().st_mtime_ns
        self.env['TEST_REV']='updated'
        d2=self.prepare('deep',True); self.publish(d2,'新标准')
        self.assertEqual(video.stat().st_mtime_ns,stamp)
        self.assertEqual((folder/'evidence/frames/00-00-01.jpg').read_bytes(),b'updated')
        self.invoke('verify','--folder',d['folder'],'--mode','deep')

    def test_refresh_failure_keeps_old_audience_and_reports_unavailable(self):
        q=self.prepare('quick'); self.publish(q)
        p=self.workspace/q['folder']/'evidence/audience.json'; before=p.read_bytes()
        y=self.bin/'yt-dlp'; y.write_text(y.read_text().replace("if '--write-comments' in args:","if '--write-comments' in args:sys.exit(1)\nif False:"))
        q2=self.prepare('quick',True)
        self.assertEqual(q2['has_comments'],0)
        self.assertEqual(p.read_bytes(),before)
        self.assertEqual(self.meta(q2)['material_state']['comments']['status'],'failed')


    def test_multipage_keeps_part_and_mode_outputs_independent(self):
        p=self.bin/'python3'; source=p.read_text()
        source=source.replace("else:os.execv(sys.executable,[sys.executable]+sys.argv[1:])", """elif len(sys.argv)>2 and sys.argv[1].endswith('/pipeline_meta.py') and sys.argv[2]=='multipage_lookup':
 import json,pathlib,urllib.parse
 args=sys.argv;url=args[args.index('--webpage-url')+1];part=int(urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get('p',['1'])[0])
 path=pathlib.Path(args[args.index('--distilled')+1]);d=json.loads(path.read_text());d['id']='BV1jEnE6vErq_p'+str(part);d['collection']={'id':'BV1jEnE6vErq','title':'Course'};path.write_text(json.dumps(d))
 print(json.dumps({'is_multipage':True,'explicit_p':True,'part':part,'page_count':3,'course':{'id':'BV1jEnE6vErq','title':'Course','safe_dir':'BV1jEnE6vErq_Course'}}))
else:os.execv(sys.executable,[sys.executable]+sys.argv[1:])""")
        p.write_text(source)
        q=json.loads(self.invoke('quick',URL+'?p=1').stdout.splitlines()[-1]);self.publish(q)
        d=json.loads(self.invoke(URL+'?p=1').stdout.splitlines()[-1]);self.publish(d,'标准P1')
        q2=json.loads(self.invoke('quick',URL+'?p=2').stdout.splitlines()[-1]);self.publish(q2,'快速P2')
        self.assertEqual(q['folder'],d['folder']);self.assertEqual(d['folder'],q2['folder'])
        folder=self.workspace/q['folder']
        self.assertTrue((folder/'brief_01.md').is_file());self.assertTrue((folder/'summary_01.md').is_file())
        self.assertTrue((folder/'brief_02.md').is_file());self.assertFalse((folder/'summary_02.md').exists())
        self.assertTrue((folder/'evidence/frames/p01/00-00-01.jpg').exists())
        self.assertFalse((folder/'evidence/frames/p02').exists())
        self.invoke('verify','--folder',q['folder'])


class ArchiveUtilityTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        import tempfile
        self.tmp=tempfile.TemporaryDirectory()
        previous=Path.cwd()
        self.addCleanup(lambda: os.chdir(previous))
        self.addCleanup(self.tmp.cleanup)
        os.chdir(self.tmp.name)
        spec=importlib.util.spec_from_file_location('archive_contract',fixtures.SKILL/'scripts/pipeline_archive.py')
        self.archive=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.archive)
        self.folder=Path('archive/2026-10/test/video')
        (self.folder/'raw').mkdir(parents=True);(self.folder/'evidence').mkdir()
        self.meta={'platform':'test','id':'v','agent_model':'m','harness':'h','subtitle':{'selected':'zh','source':'manual'}}
        (self.folder/'raw/meta.json').write_text(json.dumps(self.meta))
        (self.folder/'summary.md').write_text('# Test\n> test · author · 原片 · 总结于 2026-10-20 · m · h\n\n## TL;DR\n完整测试内容。')
        (self.folder/'evidence/evidence.md').write_text('evidence')
        Path('archive/registry.json').write_text(json.dumps({'videos':{'test':{'v':{'folder':str(self.folder),'summary_file':'summary.md','agent_model':'m','harness':'h','summarized_at':'2026-10-20'}}}}))

    def test_legacy_meta_without_summary_date_uses_original_registry_date(self):
        import argparse
        self.archive.verify(argparse.Namespace(folder=str(self.folder),part=None,mode=None))
        self.assertNotIn('summarized_at',json.loads((self.folder/'raw/meta.json').read_text()))

    def test_finish_rejects_output_path_that_is_not_the_selected_mode(self):
        import argparse
        before=(self.folder/'summary.md').read_bytes()
        self.meta.update(schema_version=2,last_run={'id':'run','mode':'quick','status':'prepared','handoff':{'summary_file':'../../escape','summary_output':'/tmp/brief.md','evidence_output':'/tmp/evidence.md'}})
        (self.folder/'raw/meta.json').write_text(json.dumps(self.meta))
        with self.assertRaisesRegex(ValueError,'文件名'):
            self.archive.finish(argparse.Namespace(folder=str(self.folder),part=None,mode='quick',run_id='run'))
        self.assertEqual((self.folder/'summary.md').read_bytes(),before)
