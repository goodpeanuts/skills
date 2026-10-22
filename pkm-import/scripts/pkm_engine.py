"""Versioned request executor. Vault policy values are supplied by the Agent per plan."""
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import string
import time
import uuid

from pkm_vault import Vault, relative_path

API_VERSION = 2
ACTIONS = ('inspect', 'plan', 'apply', 'verify', 'status')


def digest(value):
    raw = value if isinstance(value, bytes) else value.encode() if isinstance(value, str) else json.dumps(value, ensure_ascii=True, sort_keys=True).encode()
    return hashlib.sha256(raw).hexdigest()


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def has_marker(raw, sid):
    if not raw:
        return False
    body = raw
    if raw.startswith('---\n'):
        end = raw.find('\n---', 3)
        if end < 0:
            return False
        body = raw[end + 4:]
    return body.lstrip('\r\n').split('\n', 1)[0].strip() == '<!-- pkm-import: source-id=' + sid + ' -->'


def read_json(path, default=None):
    return json.loads(Path(path).read_text()) if Path(path).exists() else default


def template_serialization_matches(raw, receipt):
    """Only recognize Obsidian's date quoting change in an owned, bodyless template.

    Do not use YAML equivalence for arbitrary edits or accept changes after a
    content write. Old receipts can prove their original bodyless snapshot from
    the protected frontmatter and its exact fingerprint.
    """
    if (not isinstance(raw, str) or receipt.get('stage') != 'created'
            or receipt.get('unit', {}).get('state') != 'pending'
            or receipt.get('after_sha256') or receipt.get('before_write_sha256')):
        return False
    protected = receipt.get('protected')
    if not isinstance(protected, str) or not protected.startswith('---\n') or not protected.endswith('\n---'):
        return False
    date = re.compile(r'''^createdTime: (?:"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"|'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'|(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}))$''', re.M)
    def canonical(value):
        matches = list(date.finditer(value))
        if len(matches) != 1:
            return None
        return date.sub(lambda m: 'createdTime: ' + next(x for x in m.groups() if x is not None), value).rstrip('\n')
    original = next((protected + suffix for suffix in ('', '\n', '\n\n')
                     if digest(protected + suffix) == receipt.get('template_sha256')), None)
    return original is not None and canonical(original) is not None and canonical(original) == canonical(raw)


def owns_snapshot(raw, receipt):
    return raw is not None and (digest(raw) in {receipt.get(k) for k in
        ('template_sha256', 'after_sha256', 'before_write_sha256')}
        or template_serialization_matches(raw, receipt))


@contextmanager
def locks(request):
    """Kernel-owned locks release on crash; never guess whether a stale lock is safe."""
    try:
        import fcntl
    except ImportError:
        fcntl = None
        import msvcrt
    base = Path(request['state_root']) / 'locks'
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    handles = []
    try:
        for key in sorted({digest(request['ledger']), digest(request['target']['vault_path'])}):
            fd = os.open(base / (key + '.lock'), os.O_RDWR | os.O_CREAT, 0o600)
            handles.append(fd)
            try:
                if fcntl:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                else:
                    if os.fstat(fd).st_size == 0:
                        os.write(fd, b'0')
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                raise ValueError('同一库或台账正在导入，请稍后查询状态再重试') from exc
        yield
    finally:
        for fd in handles:
            os.close(fd)


class Engine:
    def __init__(self, base, request, vault=None):
        self.base, self.request = base, request
        self.target = request['target']
        self.vault = vault or Vault(self.target['vault_name'])
        self.directory = Path(request['plan']).parent
        self.inspect_path = self.directory / 'inspection.json'
        self.journal_path = self.directory / 'journal.json'
        self.key = base['profile_key'](self.target['vault_path'])
        self.artifacts = {}

    def save(self, path, value):
        if self.request.get('_defer_writes'):
            self.artifacts[Path(path).name] = value
        else:
            atomic(path, value)

    def load(self, path, default=None):
        return self.artifacts.get(Path(path).name, read_json(path, default))

    def identity(self):
        identity = self.vault.rpc('identity')
        if Path(identity['path']).resolve() != Path(self.target['vault_path']).resolve() or identity['name'] != self.target['vault_name']:
            raise ValueError('Obsidian CLI 库身份与所选路径不一致')
        return identity

    def sources(self):
        warnings = []
        all_units = self.base['scan_archive'](self.request['repo'], warnings)
        selected = {u['source_id']: u for u in self.request['units']}
        if len(selected) != len(self.request['units']):
            raise ValueError('导入范围包含重复单元')
        units = [u for u in all_units if u['source_id'] in selected]
        if len(units) != len(selected):
            raise ValueError('所选总结已缺失，请刷新后重新发起')
        for unit in units:
            if unit['source_sha256'] != selected[unit['source_id']]['source_sha256']:
                raise ValueError('所选总结已变化，请刷新后重新发起')
            source = (Path(self.request['repo']) / unit['source_summary']).resolve()
            if not source.is_relative_to(Path(self.request['repo']).resolve()):
                raise ValueError('来源路径越过工作区')
            unit['_repo'] = self.request['repo']
        return units, [w for w in warnings if any(u['bv'] in w for u in units)]

    def inspect(self, payload):
        identity = self.identity()
        units, warnings = self.sources()
        ledger = self.base['load_ledger'](self.request['ledger'])
        paths = self.vault.rpc('list', folder='')
        folders = {PurePosixPath(self.target['notes_folder'])}
        for unit in units:
            previous = ledger['imports'].get(unit['source_id'], {}).get('per_profile', {}).get(self.key)
            target = relative_path(previous['target'] if previous else self.base['unit_target'](unit, self.target))
            folders.add(PurePosixPath(target).parent)
        ancestors = {p for folder in folders for p in (*folder.parents, folder) if str(p) != '.'}
        rule_paths = ['AGENTS.md'] + [str(p / 'AGENTS.md') for p in sorted(ancestors, key=lambda p: (len(p.parts), str(p)))]
        requested = payload.get('readPaths', [])
        if len(requested) > 12:
            raise ValueError('每次最多读取 12 个规则或模板文件')
        resources = list(dict.fromkeys([p for p in rule_paths if p in paths] + [relative_path(p) for p in requested]))
        old = self.load(self.inspect_path, {'resources': {}})
        contents = self.vault.rpc('read_many', paths=resources) if resources else {}
        if any(p in rule_paths and old['resources'].get(p) not in (None, digest(t)) for p, t in contents.items() if t is not None):
            old['resources'] = {}
        for path, text in contents.items():
            if text is None:
                raise ValueError('库规则或模板不存在: ' + path)
            old['resources'][path] = digest(text)
        self.save(self.inspect_path, old)
        sample_paths = [p for p in paths if p.endswith('.md') and p.startswith(self.target['notes_folder'].rstrip('/') + '/')][:2]
        samples = self.vault.rpc('read_many', paths=sample_paths) if sample_paths else {}
        return dict(stage='inspected', identity=identity, templates=self.vault.templates(),
                    resources=contents, samples={p: {'head': t[:1600], 'embeds': re.findall(r'!\[\[[^\]]+\]\]', t)[:4]} for p, t in samples.items() if t},
                    selectedLedger={u['source_id']: ledger['imports'].get(u['source_id']) for u in units},
                    profile=ledger['profiles'].get(self.key), warnings=warnings,
                    availableRulePaths=[p for p in rule_paths if p in paths])

    def parameters(self, value):
        required = ('template', 'template_path', 'attachments_folder', 'attachment_naming', 'embed', 'create_interval')
        if not isinstance(value, dict) or any(k not in value for k in required):
            raise ValueError('请根据现场库规则补齐模板、附件、嵌入与创建间隔参数')
        allowed = {*required, 'tags', 'identity_exempt_paths'}
        if set(value) - allowed:
            raise ValueError('存在未支持的计划参数')
        p = dict(value)
        for key in ('template_path', 'attachments_folder'):
            p[key] = relative_path(p[key])
        if not isinstance(p['template'], str) or p['template'] not in self.vault.templates():
            raise ValueError('模板名不在 Obsidian 模板列表中')
        template_folder = self.vault.rpc('template_folder').strip('/')
        actual_template = relative_path((template_folder + '/' if template_folder else '') + p['template'] + '.md')
        if p['template_path'] != actual_template:
            raise ValueError('模板路径与模板名不对应')
        if not isinstance(p['create_interval'], (int, float)) or not math.isfinite(p['create_interval']) or p['create_interval'] < 0:
            raise ValueError('创建间隔无效')
        for key, fields in [('attachment_naming', {'md5', 'ext'}), ('embed', {'path'})]:
            if not isinstance(p[key], str) or not p[key] or any(name and (name not in fields or spec or conversion) for _, name, spec, conversion in string.Formatter().parse(p[key])):
                raise ValueError('附件或嵌入格式占位符无效')
        p.setdefault('tags', 'literature')
        if not isinstance(p['tags'], str) or any(c in p['tags'] for c in '\r\n\x00'):
            raise ValueError('标签无效')
        p['identity_exempt_paths'] = [relative_path(x) for x in p.get('identity_exempt_paths', [])]
        return p

    def resource_snapshot(self, params):
        inspected = self.load(self.inspect_path)
        if not inspected:
            raise ValueError('请先 inspect 并现场读取库规则')
        if params['template_path'] not in inspected['resources']:
            raise ValueError('请先通过 inspect 的 readPaths 现场读取适用模板')
        paths = list(dict.fromkeys([*inspected['resources'], params['template_path']]))
        contents = self.vault.rpc('read_many', paths=paths)
        if any(t is None for t in contents.values()):
            raise ValueError('规则或模板已缺失')
        current = {p: digest(t) for p, t in contents.items()}
        if any(current[p] != sha for p, sha in inspected['resources'].items()):
            raise ValueError('库规则已变化，请重新 inspect、计划并确认')
        return current

    def body(self, unit, params):
        source = (Path(self.request['repo']) / unit['source_summary']).resolve()
        raw_source = source.read_bytes()
        if digest(raw_source) != unit['source_sha256']:
            raise ValueError('所选总结已变化，请刷新后重新发起')
        text = raw_source.decode('utf-8')
        lines = text.splitlines()
        body = '\n'.join(lines[1:]).lstrip('\n') if lines and lines[0].startswith('# ') else text
        attachments = {}
        def repl(match):
            indent, alt, rel, tail = match.groups()
            src = (source.parent / rel.strip()).resolve()
            if not src.is_relative_to(Path(self.request['repo']).resolve()) or not src.is_file():
                raise ValueError('所选总结的图片缺失或越过工作区: ' + rel)
            raw = src.read_bytes()
            name = params['attachment_naming'].format(md5=hashlib.md5(raw).hexdigest(), ext=src.suffix.lower())
            target = relative_path(params['attachments_folder'] + '/' + name)
            if target in attachments and attachments[target]['sha256'] != digest(raw):
                raise ValueError('同名附件映射了不同内容，请检查现场命名参数')
            attachments[target] = dict(source=str(src), target=target, sha256=digest(raw), bytes=len(raw))
            return indent + params['embed'].format(path=target) + tail
        body = self.base['IMAGE_LINE_RE'].sub(repl, body)
        if re.search(r'\]\((?:\./)?evidence/', body):
            raise ValueError('所选总结存在未处理的 evidence 引用')
        return '<!-- pkm-import: source-id=' + unit['source_id'] + ' -->\n\n' + body, list(attachments.values())

    def attachment_counts(self, items):
        counts = {'new': 0, 'reused': 0}
        seen_attachments = {}
        for item in items:
            if item['state'] not in ('pending', 'changed'):
                continue
            for att in item['attachments']:
                if att['target'] in seen_attachments:
                    if seen_attachments[att['target']] != att['sha256']:
                        raise ValueError('同名附件映射了不同内容，请检查现场命名参数')
                    continue
                seen_attachments[att['target']] = att['sha256']
                existing = self.vault.rpc('binary_hash', path=att['target'])
                if existing is not None and existing != att['sha256']:
                    raise ValueError('同名附件内容不匹配，拒绝覆盖: ' + att['target'])
                counts['reused' if existing else 'new'] += 1
        return counts

    def snapshot(self, params):
        params = self.parameters(params)
        self.identity()
        units, warnings = self.sources()
        ledger = self.base['load_ledger'](self.request['ledger'])
        hits = self.vault.rpc('markers', folder=self.target['notes_folder'], ids=[u['source_id'] for u in units])
        items = []
        for u in units:
            old = ledger['imports'].get(u['source_id'], {}).get('per_profile', {}).get(self.key)
            target = relative_path(old['target'] if old else self.base['unit_target'](u, self.target))
            raw = self.vault.read(target)
            found = [h['path'] for h in hits if h['source_id'] == u['source_id']]
            if len(found) > 1:
                raise ValueError('同一来源有多个特征笔记，请先检查: ' + u['source_id'])
            if old:
                state = 'missing' if raw is None else 'changed' if old.get('source_sha256') != u['source_sha256'] else 'imported'
            elif found:
                target = relative_path(found[0]); raw = self.vault.read(target); state = 'already_in_vault'
            else:
                state = 'pending' if raw is None else 'conflict'
            if old and raw is not None and not has_marker(raw, u['source_id']):
                state = 'conflict'
            body, attachments = self.body(u, params)
            items.append({**{k: v for k, v in u.items() if not k.startswith('_')}, 'target': target, 'state': state,
                          'before_sha256': digest(raw) if raw is not None else None, 'body_sha256': digest(body), 'attachments': attachments})
        attachment_counts = self.attachment_counts(items)
        return dict(attachmentCounts=attachment_counts, schemaVersion=2, requestId=self.request['requestId'], profile_key=self.key, profile=self.target,
                    previous_profile=ledger['profiles'].get(self.key), parameters=params, resources=self.resource_snapshot(params), units=items, warnings=warnings)

    def plan(self, payload):
        plan = self.snapshot(payload.get('parameters'))
        journal = self.load(self.journal_path, {'units': {}})
        if journal.get('units'):
            ledger = self.base['load_ledger'](self.request['ledger'])
            for unit in plan['units']:
                receipt = journal['units'].get(unit['source_id'])
                if not receipt:
                    continue
                raw = self.vault.read(unit['target'])
                if not owns_snapshot(raw, receipt) or receipt.get('stage') == 'intent':
                    raise ValueError('半成品归属不确定或已被修改，请 status 后人工核对')
                if receipt['unit']['target'] != unit['target']:
                    raise ValueError('已有创建凭据的目标位置发生变化')
                if receipt.get('stage') == 'complete':
                    self.verify_unit(unit, receipt, plan['parameters'], ledger)
                else:
                    unit['state'] = receipt['unit']['state']
            plan['previousRevision'] = journal['planRevision']
        plan['attachmentCounts'] = self.attachment_counts(plan['units'])
        plan['planRevision'] = digest(plan)
        self.save(self.request['plan'], plan)
        return self.report(plan, 'planned')

    def report(self, plan, stage):
        counts = {}
        attachments = {}
        for u in plan['units']:
            counts[u['state']] = counts.get(u['state'], 0) + 1
            if u['state'] in ('pending', 'changed'):
                attachments.update({a['target']: a for a in u['attachments']})
        return dict(stage=stage, planRevision=plan['planRevision'], target=plan['profile'], parameters=plan['parameters'],
                    counts=counts, attachmentCount=len(attachments), attachmentCounts=plan['attachmentCounts'],
                    units=[{k: u[k] for k in ('source_id', 'title', 'target', 'state')} for u in plan['units']], warnings=plan['warnings'])

    def load_plan(self, revision):
        plan = self.load(self.request['plan'])
        if not plan or revision != plan.get('planRevision') or digest({k:v for k,v in plan.items() if k != 'planRevision'}) != revision:
            raise ValueError('计划版本无效，请重新计划并确认')
        return plan

    def check(self, plan, journal):
        current = self.snapshot(plan['parameters'])
        for field in ('resources', 'profile', 'profile_key'):
            if current[field] != plan[field]:
                raise ValueError('库规则或目标已变化，请重新计划并确认')
        if len(plan['units']) != len(current['units']):
            raise ValueError('计划范围与冻结请求不一致')
        for old, new in zip(plan['units'], current['units']):
            if any(old[k] != new[k] for k in ('source_id', 'source_summary', 'source_sha256', 'title', 'course', 'part', 'bv', 'target', 'attachments', 'body_sha256')):
                raise ValueError('来源或目标已变化，请重新计划并确认')
            receipt = journal['units'].get(old['source_id'])
            if not receipt:
                if old != new:
                    raise ValueError('目标库状态已变化，请重新计划并确认')
            else:
                raw = self.vault.read(old['target'])
                if not owns_snapshot(raw, receipt):
                    raise ValueError('半成品已被修改或归属不确定，请人工核对；不覆盖或删除')
        previous = current['previous_profile']
        if previous != plan['previous_profile'] and previous != journal.get('persisted_profile'):
            raise ValueError('台账 profile 已被其他会话修改')

    def apply(self, payload):
        plan = self.load_plan(payload.get('planRevision'))
        with locks(self.request):
            journal = self.load(self.journal_path, dict(requestId=self.request['requestId'], planRevision=plan['planRevision'], units={}, attachments={}))
            if journal['requestId'] != self.request['requestId'] or journal['planRevision'] not in (plan['planRevision'], plan.get('previousRevision')):
                raise ValueError('恢复记录与请求不一致')
            self.check(plan, journal)
            journal['planRevision'] = plan['planRevision']
            self.save(self.journal_path, journal)
            params = plan['parameters']
            ledger = self.base['load_ledger'](self.request['ledger'])
            results = []
            for unit in plan['units']:
                sid, target, state = unit['source_id'], unit['target'], unit['state']
                receipt = journal['units'].get(sid)
                if self.resource_snapshot(params) != plan['resources'] or self.parameters(params) != params:
                    raise ValueError('规则或模板在执行中变化，请重新计划并确认')
                if receipt and receipt.get('stage') == 'complete':
                    self.verify_unit(unit, receipt, params, ledger)
                    results.append(dict(source_id=sid, status='resumed', target=target)); continue
                if state in ('conflict', 'missing', 'imported'):
                    results.append(dict(source_id=sid, status='skipped', reason=state)); continue
                if state == 'already_in_vault':
                    raw = self.vault.read(target)
                    receipt = dict(stage='written', after_sha256=digest(raw), protected=self.base['frontmatter_of'](raw), unit=unit, parameters=params)
                    journal['units'][sid] = receipt
                else:
                    # Validate every attachment before any template creation. Content-addressed existing files are never overwritten.
                    for att in unit['attachments']:
                        content = Path(att['source']).read_bytes()
                        if digest(content) != att['sha256']:
                            raise ValueError('附件源已变化，请重新计划')
                        existing = self.vault.rpc('binary_hash', path=att['target'])
                        if existing is not None and existing != att['sha256']:
                            raise ValueError('同名附件内容不匹配，拒绝覆盖')
                        if existing is None:
                            self.vault.rpc('mkdir', path=str(PurePosixPath(att['target']).parent))
                            self.vault.write(att['target'], content, binary=True)
                        journal.setdefault('attachments', {})[att['target']] = att['sha256']
                        self.save(self.journal_path, journal)
                    raw = self.vault.read(target)
                    if not receipt:
                        receipt = dict(stage='intent', before_sha256=unit['before_sha256'], unit=unit, parameters=params)
                        journal['units'][sid] = receipt
                        self.save(self.journal_path, journal)
                        if state == 'pending':
                            if raw is not None:
                                raise ValueError('目标已出现，不能确认归属')
                            self.vault.rpc('mkdir', path=str(PurePosixPath(target).parent))
                            self.vault.create_template(target, params['template'])
                            raw = self.vault.read(target)
                        elif raw is None or digest(raw) != unit['before_sha256']:
                            raise ValueError('目标正文已变化')
                        fm = self.base['frontmatter_of'](raw)
                        receipt.update(stage='created', protected=fm, template_sha256=digest(raw))
                        self.save(self.journal_path, journal)
                    if receipt.get('stage') == 'intent':
                        raise ValueError('上次创建结果归属不确定，不能自动重建、覆盖或删除')
                    fm = receipt['protected']
                    ct = self.base['CREATED_TIME_RE'].search(fm)
                    if not ct or not re.search(r'^up:\s*\S|^up:\s*\n\s+-\s*\S', fm, re.M):
                        raise ValueError('模板身份字段缺失，保留半成品并停止')
                    if state == 'pending':
                        matches = self.vault.rpc('identity_matches', value=ct.group(1), exclude=params['identity_exempt_paths'] + [params['template_path']])
                        if matches != [target]:
                            raise ValueError('本次创建时间不唯一，保留半成品并停止')
                    time.sleep(params['create_interval'])
                    # Preserve the owned pre-write fingerprint across a newly confirmed plan.
                    raw = self.vault.read(target)
                    if not owns_snapshot(raw, receipt):
                        raise ValueError('笔记已被修改，不能续跑')
                    if digest(raw) != receipt.get('template_sha256') and template_serialization_matches(raw, receipt):
                        receipt['initial_template_sha256'] = receipt['template_sha256']
                        receipt['template_sha256'] = digest(raw)
                        receipt['protected'] = self.base['frontmatter_of'](raw)
                    body, _ = self.body(unit, params)
                    expected = self.base['inject_tags'](receipt['protected'], params['tags'].split(',')) + '\n' + body
                    receipt['before_write_sha256'] = digest(raw)
                    receipt['after_sha256'] = digest(expected)
                    receipt['unit'], receipt['parameters'] = unit, params
                    self.save(self.journal_path, journal)
                    if digest(raw) != receipt['after_sha256']:
                        self.vault.write(target, expected, expected=raw)
                    receipt['stage'] = 'written'
                    self.save(self.journal_path, journal)
                # Re-read and merge current ledger while holding both locks.
                ledger = self.base['load_ledger'](self.request['ledger'])
                self.verify_content(unit, receipt, params)
                ledger['profiles'].setdefault(self.key, dict(self.target, registered_at=self.base['now_iso']()))
                ledger['profiles'][self.key].update(self.target)
                journal['persisted_profile'] = ledger['profiles'][self.key]
                self.save(self.journal_path, journal)
                per = ledger['imports'].get(sid, {}).get('per_profile', {}).get(self.key)
                if not per or per.get('source_sha256') != unit['source_sha256']:
                    if per:
                        self.base['append_history'](ledger, unit, self.key, 'update')
                    else:
                        self.base['record_import'](ledger, unit, self.key, 'already_in_vault' if state == 'already_in_vault' else 'imported', target, 'mark-existing' if state == 'already_in_vault' else 'import')
                self.base['save_ledger'](self.request['ledger'], ledger)
                journal['persisted_profile'] = ledger['profiles'][self.key]
                receipt['stage'] = 'complete'
                self.save(self.journal_path, journal)
                results.append(dict(source_id=sid, status='recorded' if state == 'already_in_vault' else 'updated' if state == 'changed' else 'imported', target=target))
            return dict(stage='applied', planRevision=plan['planRevision'], results=results)

    def verify_content(self, unit, receipt, params):
        unit, params = receipt.get('unit', unit), receipt.get('parameters', params)
        raw = self.vault.read(unit['target'])
        if raw is None or digest(raw) != receipt['after_sha256']:
            raise ValueError('正文完整回读与本次写入不一致: ' + unit['source_id'])
        fm = self.base['frontmatter_of'](raw)
        expected_fm = self.base['inject_tags'](receipt['protected'], params['tags'].split(',')) if unit['state'] != 'already_in_vault' else receipt['protected'] + '\n'
        if fm.rstrip('\n') != expected_fm.rstrip('\n') or not has_marker(raw, unit['source_id']):
            raise ValueError('身份字段或特征标记不一致')
        if unit['state'] == 'already_in_vault':
            for path in re.findall(r'!\[\[([^\]|]+)\]\]', raw):
                if not self.vault.rpc('stat', path=relative_path(path)):
                    raise ValueError('存量笔记附件缺失: ' + path)
        else:
            for att in unit['attachments']:
                if self.vault.rpc('binary_hash', path=att['target']) != att['sha256']:
                    raise ValueError('附件核验失败: ' + att['target'])
        if 'evidence/' in raw:
            raise ValueError('存在 evidence 引用残留')

    def verify_unit(self, unit, receipt, params, ledger):
        unit, params = receipt.get('unit', unit), receipt.get('parameters', params)
        self.verify_content(unit, receipt, params)
        per = ledger['imports'].get(unit['source_id'], {}).get('per_profile', {}).get(self.key)
        if not per or per['target'] != unit['target'] or per.get('source_sha256') != unit['source_sha256']:
            raise ValueError('本次笔记与台账不一致')

    def verify(self, payload):
        plan = self.load_plan(payload.get('planRevision'))
        journal = self.load(self.journal_path, {'units': {}})
        ledger = self.base['load_ledger'](self.request['ledger'])
        results = []
        for unit in plan['units']:
            receipt = journal['units'].get(unit['source_id'])
            if not receipt or receipt.get('stage') != 'complete':
                results.append(dict(source_id=unit['source_id'], status='not_checked', reason=unit['state'])); continue
            try:
                self.verify_unit(unit, receipt, plan['parameters'], ledger)
                if receipt.get('unit', unit)['state'] == 'pending':
                    ct = self.base['CREATED_TIME_RE'].search(receipt['protected']).group(1)
                    matches = self.vault.rpc('identity_matches', value=ct, exclude=plan['parameters']['identity_exempt_paths'] + [plan['parameters']['template_path']])
                    if matches != [unit['target']]:
                        raise ValueError('本次身份时间不唯一')
                results.append(dict(source_id=unit['source_id'], status='passed'))
            except (ValueError, RuntimeError) as exc:
                results.append(dict(source_id=unit['source_id'], status='failed', reason=str(exc)))
        return dict(stage='verified', scope='request', checked=sum(r['status'] != 'not_checked' for r in results), results=results,
                    limitations=['仅核验本次单元及其附件、身份与台账；不代表全库历史或显示效果合规'])

    def status(self, payload):
        journal = self.load(self.journal_path, {'units': {}})
        self.identity()
        results = []
        plan = self.load(self.request['plan'], {'units': []})
        for unit in plan['units']:
            receipt = journal['units'].get(unit['source_id'], {})
            raw = self.vault.read(unit['target'])
            known = owns_snapshot(raw, receipt)
            results.append(dict(source_id=unit['source_id'], target=unit['target'], stage=receipt.get('stage', 'not_started'),
                                recoverable=known, exists=raw is not None))
        return dict(stage='status', planRevision=plan.get('planRevision'), units=results)

    def execute(self, action, payload):
        if action not in ACTIONS:
            raise ValueError('不支持的导入操作')
        result = getattr(self, action)(payload)
        if self.artifacts:
            result['_artifacts'] = self.artifacts
        return result
