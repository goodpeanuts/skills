#!/usr/bin/env python3
"""Shared archive state and validated publication for quick/standard summaries."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid


def now():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return {} if default is None else default


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2) + '\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def lock():
    # Stable lock inode; registry itself is replaced atomically. Cache is already ignored.
    Path('cache').mkdir(exist_ok=True)
    with open('cache/.archive.lock', 'a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def layout(folder, part=None):
    suffix = f'_{part:02d}' if part else ''
    return Path(folder) / 'raw' / f'meta{suffix}.json', suffix


def checked_folder(folder):
    p = Path(folder)
    if p.is_absolute() or not p.parts or p.parts[0] != 'archive' or '..' in p.parts:
        raise ValueError('folder 必须是项目根 archive/ 下的相对路径')
    if not Path('archive').resolve().is_relative_to(Path.cwd().resolve()) or not p.resolve().is_relative_to(Path('archive').resolve()):
        raise ValueError('归档路径越界')
    return p


def summaries(meta):
    result = dict(meta.get('summaries') or {})
    # Legacy archives were standard mode. Never invent historical model/date values.
    if not result and meta.get('agent_model'):
        part = meta.get('part') if meta.get('is_multipage') else None
        result['deep'] = {'file': f'summary_{part:02d}.md' if part else 'summary.md',
                          'status': 'completed', 'agent_model': meta.get('agent_model'),
                          'harness': meta.get('harness'), 'summarized_at': meta.get('summarized_at', '')}
    return result


def fingerprint(path):
    p = Path(path)
    if not p.is_file():
        return None
    data = p.read_bytes()
    if p.suffix == '.json':
        try:
            def clean(value):
                if isinstance(value, dict):
                    return {k: clean(v) for k, v in value.items() if k not in ('generated_at', 'fetched_at', 'updated_at')}
                return [clean(v) for v in value] if isinstance(value, list) else value
            data = json.dumps(clean(json.loads(data)), sort_keys=True, ensure_ascii=False).encode()
        except (ValueError, UnicodeError):
            pass
    return hashlib.sha256(data).hexdigest()


def inputs(folder, part, mode, capabilities=None):
    _, s = layout(folder, part)
    files = [f'raw/subtitle{s}.srt', f'evidence/chapters{s}.json', 'evidence/audience.json']
    if capabilities is not None and not capabilities.get('comments'):
        files.remove('evidence/audience.json')
    if part and (capabilities is None or capabilities.get('danmaku')):
        files.append(f'evidence/audience{s}.json')
    if capabilities is not None and capabilities.get('danmaku'):
        files.append(f'evidence/danmaku{s}.xml')
    if mode == 'deep':
        sub = f'/p{part:02d}' if part else ''
        files += [str(p.relative_to(folder)) for p in sorted((Path(folder) / f'evidence/frames{sub}').glob('*.jpg'))]
    return {f: fingerprint(Path(folder) / f) for f in files if (Path(folder) / f).is_file()}


def plan(args):
    d, mp = read(args.distilled), read(args.multipage)
    part = int(mp.get('part') or 0) if mp.get('is_multipage') else None
    registry = read('archive/registry.json', {'videos': {}})
    entry = registry.get('videos', {}).get(d['platform'], {}).get(d['id'], {})
    folder = entry.get('folder')
    if folder and not checked_folder(folder).is_dir():
        print('警告: registry 目录缺失，按未总结重新采集', file=sys.stderr)
        folder = None
    if not folder:
        for candidate in sorted(Path('archive').glob(f'*/{d["platform"]}/*')):
            if not candidate.is_dir():
                continue
            owned = False
            for p in (candidate / 'raw').glob('meta*.json'):
                m = read(p)
                owned |= m.get('platform') == d['platform'] and (m.get('id') == d['id'] or
                         (part and m.get('is_multipage') and (m.get('collection') or {}).get('id') == (mp.get('course') or {}).get('id')))
            if owned:
                folder = str(candidate)
                break
    if not folder:
        safe = (mp.get('course') or {}).get('safe_dir') if part else d['safe_dir']
        folder = f'archive/{datetime.now().astimezone():%Y-%m}/{d["platform"]}/{safe}'
    checked_folder(folder)
    meta_path, s = layout(folder, part)
    old = read(meta_path)
    if old and (old.get('platform') != d['platform'] or old.get('id') != d['id']):
        raise ValueError('目录冲突: meta 归属不一致')
    if not old and Path(folder).exists() and not part and any(Path(folder).iterdir()):
        raise ValueError('目录冲突: 目录存在但无可核验的 meta')
    if old and not old.get('summaries') and entry:
        old['summaries'] = entry.get('summaries') or {'deep': {
            'file': entry.get('summary_file') or ('summary' + s + '.md'), 'status': 'completed',
            **{k: entry.get(k) for k in ('agent_model', 'harness', 'summarized_at')}}}
    current = summaries(old)
    legacy = entry.get('summaries') or ({'deep': {'file': entry.get('summary_file', f'summary{s}.md')}} if entry else {})
    target = current.get(args.mode) or legacy.get(args.mode)
    expected_file = ('brief' if args.mode == 'quick' else 'summary') + s + '.md'
    if target and target.get('file') not in (None, expected_file):
        raise ValueError('目标模式归档文件名无效')
    target_file = Path(folder) / expected_file
    if target_file.exists() and not args.force:
        raise ValueError('相同模式总结已存在，需要用户确认重新生成覆盖后使用 --force')
    pending = old.get('last_run') or {}
    if pending.get('status') == 'prepared':
        if args.resume and pending.get('mode') == args.mode:
            print(json.dumps(pending['handoff'], ensure_ascii=False))
            return
        raise ValueError('同一视频/分P已有未完成任务；恢复请用 --resume，取消请用 abort --run-id')
    if part:
        for sibling in (Path(folder) / 'raw').glob('meta_*.json'):
            other = read(sibling).get('last_run') or {}
            if sibling != meta_path and other.get('status') == 'prepared':
                raise ValueError('同课程另一个分P正在使用共享评论，等待该任务完成后重试')
    out = dict(folder=folder, part=part, suffix=s, frames_sub=f'/p{part:02d}' if part else '',
               meta_file=str(meta_path), summary_file=('brief' if args.mode == 'quick' else 'summary') + s + '.md',
               run_id=uuid.uuid4().hex, mode=args.mode, previous=old)
    print(json.dumps(out, ensure_ascii=False))


def prepare_meta(args):
    d, p, runtime = read(args.distilled), read(args.plan), read(args.runtime)
    old = p['previous']
    m = dict(old)
    t = now()
    for key in ('extractor', 'platform', 'host', 'media_kind', 'id', 'url', 'title', 'duration', 'language',
                'upload_date', 'uploader', 'uploader_id', 'description', 'tags'):
        m[key] = d.get(key)
    m.update(schema_version=2, part=p['part'], is_multipage=bool(p['part']),
             course_page_count=runtime.get('course_page_count') or old.get('course_page_count'),
             chapters_count=len(d.get('chapters') or []))
    m['collection'] = old.get('collection') or d.get('collection')
    m['account'] = runtime.get('account') or old.get('account')
    m['generated_at'] = old.get('generated_at') or t
    m['updated_at'] = t
    m['summaries'] = summaries(old)
    m['files'] = {**old.get('files', {}), **{k: v for k, v in runtime['files'].items() if v}}
    m['subtitle'] = {**old.get('subtitle', {}), **runtime['subtitle']}
    if runtime['material_state'].get('subtitle', {}).get('refreshed'):
        m['subtitle']['candidates'] = {'manual': d.get('subs_manual', []), 'auto': d.get('subs_auto', [])}
        m['subtitle'].pop('error', None)
    if runtime.get('subtitle_error'):
        m['subtitle']['error'] = runtime['subtitle_error']
    m['needs_whisper'] = runtime['needs_whisper']
    if p['mode'] == 'deep':
        m['frames'] = runtime['frames']
    else:
        m.setdefault('frames', {'max': 0, 'extracted': 0})
    m['capabilities'] = runtime['capabilities']
    state = dict(old.get('material_state') or {})
    for name, detail in runtime['material_state'].items():
        previous = state.get(name) or {}
        state[name] = {**previous, **detail, 'checked_at': t}
        if detail.get('refreshed'):
            state[name]['updated_at'] = t
        state[name].pop('refreshed', None)
    paths = {'subtitle': f'raw/subtitle{p["suffix"]}.srt', 'video': m['files'].get('video'), 'audio': m['files'].get('audio'), 'comments': 'evidence/audience.json', 'danmaku': f'evidence/danmaku{p["suffix"]}.xml', 'chapters': f'evidence/chapters{p["suffix"]}.json'}
    for name, rel in paths.items():
        if not rel or name not in state:
            continue
        path = Path(rel) if name in ('video', 'audio') else Path(p['folder']) / rel
        if path.is_file():
            if not state[name].get('fingerprint') or runtime['material_state'].get(name, {}).get('refreshed'):
                state[name]['fingerprint'] = fingerprint(path)
            state[name].setdefault('updated_at', datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).astimezone().isoformat(timespec='seconds'))
    m['material_state'] = state
    output = Path(tempfile.mkdtemp(prefix=f'vs-output-{p["run_id"]}-'))
    h = {k: d.get(k) for k in ('id', 'platform', 'host', 'title', 'url', 'duration', 'language', 'uploader', 'uploader_id', 'upload_date', 'media_kind')}
    folder, s = p['folder'], p['suffix']
    h.update(folder=folder, part=p['part'], is_multipage=bool(p['part']), mode=p['mode'], run_id=p['run_id'],
             summary_file=p['summary_file'], summary_output=str(output / p['summary_file']),
             evidence_output=str(output / 'evidence.md'), video_file=m['files'].get('video', ''),
             audio_file=m['files'].get('audio', ''),
             subtitle_file=str(Path(folder) / f'raw/subtitle{s}.srt') if runtime['subtitle']['selected'] != 'none' else '',
             subtitle_lang=m['subtitle']['selected'], subtitle_source=m['subtitle']['source'],
             needs_whisper=int(m['needs_whisper']), context_terms=runtime.get('context_terms', ''),
             subtitle_download_failed=bool(runtime.get('subtitle_error')), has_comments=int(m['capabilities']['comments']),
             has_danmaku=int(m['capabilities']['danmaku']), chapters=m['chapters_count'], must_run_finish=True,
             collection_id=(m.get('collection') or {}).get('id'), collection_title=(m.get('collection') or {}).get('title'))
    source = inputs(folder, p['part'], p['mode'], m['capabilities'])
    source['video_details'] = hashlib.sha256(json.dumps({k: m.get(k) for k in ('title', 'description', 'tags', 'uploader')}, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    m['material_state']['details']['fingerprint'] = source['video_details']
    m['last_run'] = {'id': p['run_id'], 'mode': p['mode'], 'status': 'prepared', 'started_at': t,
                     'overwrite_confirmed': args.force, 'inputs': source, 'handoff': h}
    atomic(p['meta_file'], m)
    print(json.dumps(h, ensure_ascii=False))


def validate_summary(text, folder, mode, model, harness):
    top = next((line.strip() for line in text.splitlines() if line.startswith('>')), '')
    if not re.search(r' · 总结于 \d{4}-\d{2}-\d{2} · ' + re.escape(model) + r' · ' + re.escape(harness) + r'\s*$', top):
        raise ValueError('总结顶行 model/harness 与 meta 不一致，或元数据行形态错误')
    if not model.strip() or not harness.strip() or model.lower() == 'unknown' or harness.lower() == 'unknown':
        raise ValueError('agent_model / harness 必须非空且不能为 unknown')
    if not re.search(r'^#\s+\S', text, re.M) or len(text.strip()) < 40:
        raise ValueError('总结正文为空或缺少标题')
    for alt, rel in re.findall(r'!\[(.*?)\]\((.*?)\)', text):
        if mode == 'quick':
            raise ValueError('快速简报禁止帧插图')
        target = (Path(folder) / rel).resolve()
        if not target.is_relative_to(Path(folder).resolve()) or not target.is_file():
            raise ValueError(f'帧插图断链: {rel}')
    if mode == 'deep':
        ts = re.compile(r'\d{1,2}:\d{2}(?::\d{2})?')
        for line in text.splitlines():
            if ts.search(line) and not line.lstrip().startswith(('### [', '![', '>')) and 'http' not in line:
                raise ValueError('行文时间戳仅允许小节范围/帧图 alt')
        for diagram in re.findall(r'```mermaid\n(.*?)```', text, re.S):
            if ts.search(diagram):
                raise ValueError('mermaid 节点含时间戳')


def merge_evidence(previous, candidate, mode):
    start, end = f'<!-- video-summarizer:{mode} -->', f'<!-- /video-summarizer:{mode} -->'
    if 'video-summarizer:' in candidate:
        raise ValueError('临时底稿应只含当前模式正文，不得包含管理标记')
    block = f'{start}\n{candidate.strip()}\n{end}'
    pattern = re.compile(re.escape(start) + r'.*?' + re.escape(end), re.S)
    if pattern.search(previous):
        return pattern.sub(lambda _: block, previous).rstrip() + '\n'
    if previous.strip() and '<!-- video-summarizer:' not in previous:
        if mode == 'deep':
            return block + '\n'
        previous = '<!-- video-summarizer:deep -->\n' + previous.strip() + '\n<!-- /video-summarizer:deep -->\n'
    return (previous.rstrip() + '\n\n' + block).lstrip() + '\n'


def finish(args):
    folder = str(checked_folder(args.folder))
    meta_path, s = layout(folder, args.part)
    with lock():
        m = read(meta_path)
        if not m:
            raise ValueError('meta 不存在（机械阶段未运行）')
        if m.get('is_multipage') and not args.part:
            raise ValueError('多P目录必须带 --part N')
        pending = m.get('last_run') or {}
        modern = m.get('schema_version') == 2
        if modern:
            if pending.get('id') != args.run_id or pending.get('mode') != args.mode or pending.get('status') != 'prepared':
                raise ValueError('run-id / mode 与当前未完成任务不一致')
            h = pending['handoff']
            expected_file = ('brief' if args.mode == 'quick' else 'summary') + s + '.md'
            if h.get('summary_file') != expected_file or Path(h['summary_output']).name != expected_file or Path(h['evidence_output']).name != 'evidence.md':
                raise ValueError('候选产物文件名与当前模式/分P不一致')
            if Path(h['evidence_output']).is_symlink():
                raise ValueError('候选底稿不得为符号链接')
            output = Path(h['summary_output']).parent.resolve()
            if not output.name.startswith('vs-output-' + args.run_id + '-') or not output.is_relative_to(Path(tempfile.gettempdir()).resolve()):
                raise ValueError('临时成品路径无效')
            if Path(h['evidence_output']).parent.resolve() != output or Path(h['summary_output']).is_symlink():
                raise ValueError('临时成品路径不一致')
            source = Path(h['summary_output'])
            evidence_source = Path(h['evidence_output'])
            dest = Path(folder) / h['summary_file']
        else:
            dest = Path(folder) / f'summary{s}.md'
            source = dest
            evidence_source = Path(folder) / f'evidence/evidence{s}.md'
        if not source.is_file() or not evidence_source.is_file():
            raise ValueError('总结或证据底稿缺失，拒绝登记')
        text, evidence = source.read_text(), evidence_source.read_text()
        if not evidence.strip():
            raise ValueError('证据底稿为空')
        validate_summary(text, folder, args.mode, args.agent_model, args.harness)
        if modern and args.mode == 'deep' and m.get('files', {}).get('video'):
            frames_dir = Path(folder) / ('evidence/frames' + (f'/p{args.part:02d}' if args.part else ''))
            if not any(frames_dir.glob('*.jpg')):
                raise ValueError('标准模式缺少有效关键帧，不能标记画面分析完成')
        if args.mode == 'quick' and not re.search(r'未分析画面|未进行画面分析', text):
            raise ValueError('快速简报需注明未分析画面')
        if modern and dest.exists() and not pending.get('overwrite_confirmed'):
            raise ValueError('目标模式产物已出现，需重新确认覆盖')
        if args.subtitle_lang:
            m['subtitle']['selected'] = args.subtitle_lang
        if args.subtitle_source:
            m['subtitle']['source'] = args.subtitle_source
            if args.subtitle_source in ('asr', 'whisper') and m['subtitle']['selected'] == 'none':
                m['subtitle']['selected'] = m.get('language') or 'und'
        subtitle = Path(folder) / f'raw/subtitle{s}.srt'
        if m.get('needs_whisper') and not subtitle.is_file():
            raise ValueError('待转写字幕尚未生成')
        if subtitle.is_file():
            m['needs_whisper'] = False
            if m['subtitle'].get('source') in ('asr', 'whisper'):
                state = m.setdefault('material_state', {}).get('subtitle') or {}
                if state.get('fingerprint') != fingerprint(subtitle):
                    m['material_state']['subtitle'] = {'status': 'ok', 'updated_at': now(), 'fingerprint': fingerprint(subtitle)}
        record = {'file': dest.name, 'status': 'completed', 'summarized_at': now(),
                  'agent_model': args.agent_model, 'harness': args.harness, 'visual_analysis': args.mode == 'deep' and m.get('media_kind') != 'audio',
                  'inputs': {**pending.get('inputs', {}), **inputs(folder, args.part, args.mode, m.get('capabilities'))}}
        m['summaries'] = {**summaries(m), args.mode: record}
        standard = m['summaries'].get('deep')
        preferred = standard if standard and (Path(folder) / standard['file']).is_file() else m['summaries'].get('quick') or standard
        m.update(agent_model=preferred.get('agent_model'), harness=preferred.get('harness'), summarized_at=preferred.get('summarized_at'))
        if modern:
            if args.mode == 'deep' and m.get('files', {}).get('video'):
                sub = f'/p{args.part:02d}' if args.part else ''
                m['frames']['extracted'] = len(list((Path(folder) / f'evidence/frames{sub}').glob('*.jpg')))
            evidence_path = Path(folder) / f'evidence/evidence{s}.md'
            merged = merge_evidence(evidence_path.read_text() if evidence_path.exists() else '', evidence, args.mode)
            atomic(dest, text)
            atomic(evidence_path, merged)
            m['last_run'] = {k: v for k, v in pending.items() if k != 'handoff'}
            m['last_run'].update(status='completed', finished_at=now())
        registry = read('archive/registry.json', {'videos': {}})
        entry = {k: m.get(k) for k in ('title', 'url', 'duration', 'language', 'upload_date', 'uploader', 'uploader_id', 'host', 'collection', 'part')}
        entry.update(folder=folder, summaries=m['summaries'], summary_file=preferred['file'],
                     agent_model=preferred.get('agent_model'), harness=preferred.get('harness'), summarized_at=preferred.get('summarized_at'),
                     subtitle_lang=m['subtitle']['selected'], subtitle_source=m['subtitle']['source'])
        registry.setdefault('videos', {}).setdefault(m['platform'], {})[m['id']] = entry
        atomic(meta_path, m)
        atomic('archive/registry.json', registry)
        if modern:
            shutil.rmtree(source.parent)
    print(f"registry 已更新: {m['platform']}/{m['id']} ({args.mode})")


def verify(args):
    registry = read('archive/registry.json', {'videos': {}})
    folders = [checked_folder(args.folder)] if args.folder else sorted(Path('archive').glob('*/*/*'))
    errors, count = [], 0
    for folder in folders:
        if not folder.is_dir():
            errors.append(f'{folder}: 目录缺失'); continue
        metas = sorted((folder / 'raw').glob('meta*.json'))
        if args.part:
            metas = [layout(folder, args.part)[0]]
        if not metas:
            errors.append(f'{folder}: meta 缺失')
        for meta_path in metas:
            try:
                m = read(meta_path)
                if not m:
                    raise ValueError('meta 缺失')
                entry = registry.get('videos', {}).get(m['platform'], {}).get(m['id'], {})
                available = summaries(m)
                if available and not m.get('schema_version'):
                    available['deep']['summarized_at'] = entry.get('summarized_at', '')
                if not available and not m.get('schema_version'):
                    available = {'deep': {'file': f'summary_{m["part"]:02d}.md' if m.get('part') else 'summary.md', **entry}}
                modes = [args.mode] if args.mode else list(available)
                if not modes:
                    raise ValueError('尚无已完成总结')
                for mode in modes:
                    record = available.get(mode)
                    if not record:
                        raise ValueError(f'{mode} 未完成')
                    if m.get('schema_version') == 2:
                        suffix = f'_{m["part"]:02d}' if m.get('part') else ''
                        expected = ('brief' if mode == 'quick' else 'summary') + suffix + '.md'
                        if record.get('file') != expected or record.get('status') != 'completed':
                            raise ValueError(f'{mode} 文件或完成状态无效')
                    if entry.get('folder') != str(folder):
                        raise ValueError('registry 未登记或目录不一致')
                    registered = (entry.get('summaries') or {}).get(mode) if m.get('schema_version') == 2 else entry
                    if not registered:
                        raise ValueError(f'registry 未登记 {mode}')
                    for key in ('agent_model', 'harness', 'summarized_at', *(['file', 'status'] if m.get('schema_version') == 2 else [])):
                        if record.get(key) != registered.get(key):
                            raise ValueError(f'registry {key} 与 meta 不一致')
                    text = (folder / record['file']).read_text()
                    validate_summary(text, folder, mode, record.get('agent_model') or '', record.get('harness') or '')
                    _, s = layout(folder, m.get('part') if m.get('is_multipage') else None)
                    evidence = (folder / f'evidence/evidence{s}.md').read_text()
                    if m.get('schema_version') == 2 and f'<!-- video-summarizer:{mode} -->' not in evidence:
                        raise ValueError(f'{mode} 证据底稿缺失')
                    count += 1
            except (ValueError, OSError, KeyError) as e:
                errors.append(f'{meta_path}: {e}')
    if errors:
        raise ValueError('\n'.join(errors))
    print(f'PASS ({count} 份总结)')


def main():
    if len(sys.argv) > 2 and sys.argv[1] == 'legacy':
        import subprocess
        with lock():
            return subprocess.call(['bash', *sys.argv[2:]], env={**os.environ, 'VS_ARCHIVE_LOCKED': '1'})
    if len(sys.argv) > 2 and sys.argv[1] == 'run':
        import subprocess
        Path('cache').mkdir(exist_ok=True)
        with open('cache/.prepare.lock', 'a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            return subprocess.call(['bash', *sys.argv[2:]], env={**os.environ, 'VS_PREP_LOCKED': '1'})
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('plan')
    for name in ('distilled', 'multipage'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--mode', choices=['quick', 'deep'], required=True)
    p.add_argument('--force', action='store_true'); p.add_argument('--resume', action='store_true')
    p = sub.add_parser('prepare-meta')
    for name in ('distilled', 'plan', 'runtime'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--force', action='store_true')
    for command in ('finish', 'verify', 'abort'):
        p = sub.add_parser(command)
        p.add_argument('--folder', required=command != 'verify')
        p.add_argument('--part', type=int)
        p.add_argument('--mode', choices=['quick', 'deep'], default='deep' if command == 'finish' else None)
        p.add_argument('--run-id')
        if command == 'finish':
            p.add_argument('--agent-model', required=True); p.add_argument('--harness', required=True)
            p.add_argument('--subtitle-lang'); p.add_argument('--subtitle-source', choices=['manual', 'auto', 'asr', 'whisper', 'none'])
    args = parser.parse_args()
    if getattr(args, 'part', None) is not None and args.part < 1:
        parser.error('--part 须为正整数')
    try:
        if args.command == 'plan':
            with lock(): plan(args)
        elif args.command == 'prepare-meta':
            with lock(): prepare_meta(args)
        elif args.command == 'finish': finish(args)
        elif args.command == 'verify':
            with lock(): verify(args)
        elif args.command == 'abort':
            with lock():
                path, _ = layout(str(checked_folder(args.folder)), args.part)
                m = read(path); pending = m.get('last_run') or {}
                if not args.run_id or pending.get('id') != args.run_id or pending.get('status') != 'prepared':
                    raise ValueError('run-id 不匹配')
                h = pending.pop('handoff', {})
                if h.get('summary_output'):
                    output = Path(h['summary_output']).parent.resolve()
                    if not output.name.startswith('vs-output-' + args.run_id + '-') or not output.is_relative_to(Path(tempfile.gettempdir()).resolve()):
                        raise ValueError('临时成品路径无效')
                    shutil.rmtree(output, ignore_errors=True)
                pending.update(status='cancelled', finished_at=now()); atomic(path, m)
            print('已取消；已有正式总结保留')
    except (ValueError, OSError, KeyError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
