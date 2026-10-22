"""Isolated behavioural tests; no Obsidian process or real vault is accessed."""
import copy
import json
from pathlib import Path
import re
import runpy
import tempfile
import unittest
from unittest.mock import patch

from pkm_engine import Engine, digest, read_json

BASE = runpy.run_path(str(Path(__file__).with_name('pkm_import.py')))


class MemoryVault:
    def __init__(self, path):
        self.path = str(path)
        self.notes = {'AGENTS.md': '# Rules\nRead the actual template.', 'Templates/Note.md': '---\nup: "[[NONE]]"\ncreatedTime: "{{DATE}}"\n---'}
        self.binary = {}
        self.created = []
        self.written = []
        self.fail = None
        self.ops = []

    def templates(self):
        return ['Note']

    def read(self, path):
        self.ops.append(('read', path))
        return self.notes.get(path)

    def rpc(self, op, **p):
        self.ops.append((op, p))
        if op == 'template_folder':
            return 'Templates'
        if op == 'identity':
            return {'name': 'Vault', 'path': self.path, 'eval': True}
        if op == 'list':
            return list(self.notes)
        if op == 'read_many':
            return {k: self.notes.get(k) for k in p['paths']}
        if op == 'markers':
            return [{'source_id': sid, 'path': path} for path, text in self.notes.items() for sid in p['ids'] if f'<!-- pkm-import: source-id={sid} -->' in text and path.startswith(p['folder'] + '/')]
        if op == 'identity_matches':
            return [path for path, text in self.notes.items() if path not in p['exclude'] and f'createdTime: {p["value"]}' in text]
        if op == 'binary_hash':
            return digest(self.binary[p['path']]) if p['path'] in self.binary else None
        if op == 'mkdir':
            return True
        if op == 'stat':
            return {'path': p['path']} if p['path'] in self.notes or p['path'] in self.binary else None
        raise AssertionError(op)

    def create_template(self, path, template):
        if path in self.notes:
            raise ValueError('exists')
        self.created.append(path)
        self.notes[path] = f'---\nup:\n  - "[[NONE]]"\ncreatedTime: 2026-01-01 12:00:{len(self.created):02}\ncustom: preserve\n---\n'
        if self.fail == 'create_timeout':
            self.fail = None
            raise RuntimeError('template timeout')

    def write(self, path, data, expected=None, binary=False):
        if binary:
            if self.fail == 'attachment':
                self.fail = None
                raise PermissionError('attachment denied')
            self.binary[path] = data
        else:
            if self.notes.get(path) != expected:
                raise ValueError('concurrent change')
            self.notes[path] = data
            self.written.append(path)
            if self.fail == 'write_response_lost':
                self.fail = None
                raise RuntimeError('write response lost')


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        for n in range(1, 4):
            folder = self.repo / 'archive/2026-01/bilibili' / f'BV{n}_视频{n}'
            folder.mkdir(parents=True)
            if n < 3:
                (folder / 'evidence').mkdir()
                (folder / 'evidence/frame.jpg').write_bytes(f'image-{n}'.encode())
                (folder / 'summary.md').write_text(f'# 视频{n}\n\n' + '中文😀 `\\n` `\\t`\n' * 1000 + '\n![图](evidence/frame.jpg)\n')
            else:
                (folder / 'brief.md').write_text('# 快速简报')
        self.base = dict(BASE)
        self.units = self.base['scan_archive'](str(self.repo), [])
        self.request = dict(schemaVersion=2, requestId='request-12345', repo=str(self.repo), ledger=str(self.root / 'ledger.json'),
                            plan=str(self.root / 'state/request-12345/plan.json'), state_root=str(self.root / 'state'),
                            target=dict(vault_path=str(self.root / 'VAULT_NOT_ON_DISK'), vault_name='Vault', notes_folder='Notes'),
                            units=[{k:u[k] for k in ('source_id', 'source_sha256')} for u in self.units])
        self.vault = MemoryVault(self.request['target']['vault_path'])
        self.engine = Engine(self.base, self.request, self.vault)
        self.params = dict(template='Note', template_path='Templates/Note.md', attachments_folder='Assets', attachment_naming='{md5}{ext}', embed='![[{path}]]', create_interval=0)
        self.engine.inspect({'readPaths': ['Templates/Note.md']})
        self.plan = self.engine.plan({'parameters': self.params})
        self.payload = {'planRevision': self.plan['planRevision']}

    def test_exact_scope_and_long_content_preserve_template_identity_and_only_verify_selected(self):
        self.vault.notes['History/old.md'] = 'old unrelated invalid note'
        result = self.engine.apply(self.payload)
        self.assertEqual([r['status'] for r in result['results']], ['imported', 'imported'])
        self.assertEqual(len(self.vault.created), 2)
        self.assertEqual(len(self.vault.binary), 2)
        self.assertIn('custom: preserve', self.vault.notes[self.vault.created[0]])
        self.assertIn('`\\n` `\\t`', self.vault.notes[self.vault.created[0]])
        self.assertNotIn('evidence/', self.vault.notes[self.vault.created[0]])
        self.assertEqual(self.engine.verify(self.payload)['checked'], 2)
        self.assertEqual([r['status'] for r in self.engine.verify(self.payload)['results']], ['passed', 'passed'])
        self.assertEqual(self.vault.notes['History/old.md'], 'old unrelated invalid note')
        self.assertFalse(self.plan['warnings'])

    def test_images_in_callouts_keep_quote_depth_and_copy_the_attachment(self):
        source = self.repo / self.units[0]['source_summary']
        source.write_text('# 块内附件\n\n> [!example]+ 展开图示\n> 正文保留。\n>\n> ![图片](evidence/frame.jpg)\n>\n> > [!note] 嵌套\n> > ![同一图片](evidence/frame.jpg)\n')
        self.units = self.base['scan_archive'](str(self.repo), [])
        self.request['units'] = [{k:u[k] for k in ('source_id', 'source_sha256')} for u in self.units]
        plan = self.engine.plan({'parameters': self.params})
        payload = {'planRevision': plan['planRevision']}
        self.engine.apply(payload)
        target = self.vault.created[0]
        raw = self.vault.notes[target]
        import hashlib
        attachment = 'Assets/' + hashlib.md5(b'image-1').hexdigest() + '.jpg'
        self.assertIn('> [!example]+ 展开图示\n> 正文保留。\n>\n> ![[' + attachment + ']]', raw)
        self.assertIn('> > [!note] 嵌套\n> > ![[' + attachment + ']]', raw)
        self.assertEqual(self.vault.binary[attachment], b'image-1')
        self.assertNotIn('evidence/', raw)
        self.assertEqual(self.engine.verify(payload)['checked'], 2)

    def test_attachment_denial_happens_before_template_or_ledger_and_retry_is_safe(self):
        self.vault.fail = 'attachment'
        with self.assertRaises(PermissionError):
            self.engine.apply(self.payload)
        self.assertEqual(self.vault.created, [])
        self.assertFalse(Path(self.request['ledger']).exists())
        self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 2)

    def test_lost_write_response_resumes_without_recreating_or_duplicate_history(self):
        self.vault.fail = 'write_response_lost'
        with self.assertRaises(RuntimeError):
            self.engine.apply(self.payload)
        self.assertTrue(self.engine.status({})['units'][0]['recoverable'])
        self.engine.apply(self.payload)
        self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 2)
        ledger = read_json(self.request['ledger'])
        for u in self.units:
            self.assertEqual(len(ledger['imports'][u['source_id']]['per_profile'][self.engine.key]['history']), 1)

    def test_unknown_template_creation_timeout_never_recreates_overwrites_or_deletes(self):
        self.vault.fail = 'create_timeout'
        with self.assertRaises(RuntimeError):
            self.engine.apply(self.payload)
        raw = copy.deepcopy(self.vault.notes)
        with self.assertRaisesRegex(ValueError, '归属不确定'):
            self.engine.apply(self.payload)
        self.assertEqual(self.vault.notes, raw)
        self.assertEqual(len(self.vault.created), 1)

    def test_known_template_receipt_can_resume_after_a_local_journal_write_error(self):
        save = self.engine.save
        def fail_once(path, value):
            save(path, value)
            if any(v.get('stage') == 'created' for v in value.get('units', {}).values()):
                self.engine.save = save
                raise OSError('crash after receipt persisted')
        self.engine.save = fail_once
        with self.assertRaises(OSError):
            self.engine.apply(self.payload)
        identity = self.vault.notes[self.vault.created[0]].split('createdTime: ')[1].split('\n')[0]
        self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 2)
        self.assertIn('createdTime: ' + identity, self.vault.notes[self.vault.created[0]])

    def stop_after_quoted_template_receipt(self, body=''):
        create = self.vault.create_template
        def quoted_create(path, template):
            create(path, template)
            self.vault.notes[path] = re.sub(r'^(createdTime: )(.+)$', r'\1"\2"', self.vault.notes[path], flags=re.M).rstrip('\n') + body
        self.vault.create_template = quoted_create
        save = self.engine.save
        def stop(path, value):
            save(path, value)
            if any(v.get('stage') == 'created' for v in value.get('units', {}).values()):
                self.engine.save = save
                raise OSError('stop after owned template receipt')
        self.engine.save = stop
        with self.assertRaises(OSError):
            self.engine.apply(self.payload)
        self.vault.create_template = create
        return self.vault.created[0]

    def test_template_date_serialization_resumes_same_identity_without_duplicate_history(self):
        target = self.stop_after_quoted_template_receipt()
        original = self.vault.notes[target]
        self.vault.notes[target] = re.sub(r'^(createdTime: )"([^"]+)"$', r'\1\2', original, flags=re.M) + '\n'
        self.assertTrue(self.engine.status({})['units'][0]['recoverable'])
        self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 2)
        receipt = read_json(self.engine.journal_path)['units'][self.units[0]['source_id']]
        self.assertEqual(receipt['initial_template_sha256'], digest(original))
        self.assertIn('createdTime: 2026-01-01 12:00:01\n', receipt['protected'])
        self.assertEqual([r['status'] for r in self.engine.verify(self.payload)['results']], ['passed', 'passed'])
        self.engine.apply(self.payload)
        ledger = read_json(self.request['ledger'])
        self.assertEqual(len(ledger['imports'][self.units[0]['source_id']]['per_profile'][self.engine.key]['history']), 1)

    def test_template_date_serialization_during_create_interval_is_accepted(self):
        create = self.vault.create_template
        def quoted_create(path, template):
            create(path, template)
            self.vault.notes[path] = re.sub(r'^(createdTime: )(.+)$', r'\1"\2"', self.vault.notes[path], flags=re.M).rstrip('\n')
        self.vault.create_template = quoted_create
        identity_matches = self.vault.rpc
        def rpc(op, **p):
            if op == 'identity_matches':
                return [path for path, raw in self.vault.notes.items() if path not in p['exclude'] and re.search(r'^createdTime: "?' + re.escape(p['value']) + r'"?$', raw, re.M)]
            return identity_matches(op, **p)
        self.vault.rpc = rpc
        def normalize(_):
            for path in self.vault.created[-1:]:
                self.vault.notes[path] = re.sub(r'^(createdTime: )"([^"]+)"$', r'\1\2', self.vault.notes[path], flags=re.M).rstrip('\n') + '\n'
        with patch('pkm_engine.time.sleep', side_effect=normalize):
            self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 2)
        self.assertEqual([r['status'] for r in self.engine.verify(self.payload)['results']], ['passed', 'passed'])

    def test_template_serialization_never_accepts_changed_fields_or_body(self):
        target = self.stop_after_quoted_template_receipt()
        original = self.vault.notes[target]
        normalized = re.sub(r'^(createdTime: )"([^"]+)"$', r'\1\2', original, flags=re.M) + '\n'
        edits = [normalized.replace('12:00:01', '12:00:59'), normalized.replace('[[NONE]]', '[[OTHER]]'),
                 normalized.replace('custom: preserve', 'custom: edited'), normalized + 'USER EDIT\n',
                 normalized.replace('\n---\n', '\nnew: value\n---\n')]
        for edited in edits:
            with self.subTest(edited=edited):
                self.vault.notes[target] = edited
                self.assertFalse(self.engine.status({})['units'][0]['recoverable'])
                with self.assertRaisesRegex(ValueError, '半成品已被修改'):
                    self.engine.apply(self.payload)
                self.assertEqual(self.vault.notes[target], edited)
                self.assertEqual(len(self.vault.created), 1)

    def test_template_with_body_does_not_get_serialization_exception(self):
        target = self.stop_after_quoted_template_receipt('\nTemplate body\n')
        self.vault.notes[target] = re.sub(r'^(createdTime: )"([^"]+)"$', r'\1\2', self.vault.notes[target], flags=re.M)
        self.assertFalse(self.engine.status({})['units'][0]['recoverable'])
        with self.assertRaisesRegex(ValueError, '半成品已被修改'):
            self.engine.apply(self.payload)

    def test_ledger_commit_with_lost_response_reconciles_once(self):
        save = self.base['save_ledger']
        def fail_once(path, ledger):
            save(path, ledger)
            self.base['save_ledger'] = save
            raise OSError('ledger commit response lost')
        self.base['save_ledger'] = fail_once
        with self.assertRaises(OSError):
            self.engine.apply(self.payload)
        self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 2)
        ledger = read_json(self.request['ledger'])
        self.assertEqual(len(ledger['imports'][self.units[0]['source_id']]['per_profile'][self.engine.key]['history']), 1)

    def test_modified_half_note_aborts_without_touching_user_content(self):
        self.vault.fail = 'write_response_lost'
        with self.assertRaises(RuntimeError):
            self.engine.apply(self.payload)
        path = self.vault.created[0]
        self.vault.notes[path] += '\nUSER EDIT'
        with self.assertRaisesRegex(ValueError, '半成品已被修改'):
            self.engine.apply(self.payload)
        self.assertTrue(self.vault.notes[path].endswith('USER EDIT'))
        self.assertEqual(len(self.vault.created), 1)

    def test_changed_rule_source_attachment_or_destination_aborts_before_any_vault_write(self):
        for case in ('rules', 'source', 'attachment', 'target'):
            with self.subTest(case=case):
                notes = copy.deepcopy(self.vault.notes)
                summary = self.repo / self.units[0]['source_summary']
                before = summary.read_text()
                image = summary.parent / 'evidence/frame.jpg'
                raw = image.read_bytes()
                if case == 'rules': self.vault.notes['AGENTS.md'] += '\nchanged'
                if case == 'source': summary.write_text(before + 'changed')
                if case == 'attachment': image.write_bytes(b'changed')
                if case == 'target': self.vault.notes['Notes/视频1.md'] = 'unknown user note'
                with self.assertRaises(ValueError): self.engine.apply(self.payload)
                self.assertEqual(self.vault.created, [])
                self.vault.notes = notes
                summary.write_text(before)
                image.write_bytes(raw)

    def test_verify_detects_full_body_or_identity_or_attachment_tampering(self):
        self.engine.apply(self.payload)
        path = self.vault.created[0]
        original = self.vault.notes[path]
        self.vault.notes[path] = original.replace('中文', '修改', 1)
        self.assertEqual(self.engine.verify(self.payload)['results'][0]['status'], 'failed')
        self.vault.notes[path] = original
        att = next(iter(self.vault.binary))
        self.vault.binary[att] = b'wrong'
        self.assertEqual(self.engine.verify(self.payload)['results'][0]['status'], 'failed')

    def test_newly_confirmed_plan_preserves_half_note_identity_after_rule_change(self):
        self.vault.fail = 'write_response_lost'
        with self.assertRaises(RuntimeError): self.engine.apply(self.payload)
        target = self.vault.created[0]
        before = self.vault.notes[target].split('createdTime: ')[1].split('\n')[0]
        self.vault.notes['AGENTS.md'] += '\nnew rule'
        self.engine.inspect({'readPaths': ['Templates/Note.md']})
        plan = self.engine.plan({'parameters': dict(self.params, tags='new-tag')})
        self.assertNotEqual(plan['planRevision'], self.payload['planRevision'])
        self.assertEqual(plan['attachmentCounts'], {'new': 1, 'reused': 1})
        payload = {'planRevision': plan['planRevision']}
        self.engine.apply(payload)
        self.assertEqual(len(self.vault.created), 2)
        self.assertIn('createdTime: ' + before, self.vault.notes[target])
        self.assertEqual(self.engine.verify(payload)['checked'], 2)

    def test_rule_change_between_units_stops_then_replan_skips_completed_unit(self):
        save = self.base['save_ledger']
        def change_rule(path, ledger):
            save(path, ledger)
            self.base['save_ledger'] = save
            self.vault.notes['AGENTS.md'] += '\nchanged during import'
        self.base['save_ledger'] = change_rule
        with self.assertRaises(ValueError): self.engine.apply(self.payload)
        self.assertEqual(len(self.vault.created), 1)
        completed = self.vault.notes[self.vault.created[0]]
        self.engine.inspect({'readPaths': ['Templates/Note.md']})
        plan = self.engine.plan({'parameters': dict(self.params, tags='remaining-tag', attachments_folder='NewAssets')})
        payload = {'planRevision': plan['planRevision']}
        result = self.engine.apply(payload)
        self.assertEqual(result['results'][0]['status'], 'resumed')
        self.assertEqual(self.vault.notes[self.vault.created[0]], completed)
        self.assertEqual(len(self.vault.created), 2)
        self.assertEqual([r['status'] for r in self.engine.verify(payload)['results']], ['passed', 'passed'])

    def test_expanded_plan_cannot_expand_frozen_source_scope(self):
        from pkm_engine import atomic
        plan = read_json(self.request['plan'])
        plan['units'].append(copy.deepcopy(plan['units'][0]))
        plan['units'][-1]['source_id'] = 'bilibili/OUTSIDE'
        plan.pop('planRevision')
        plan['planRevision'] = digest(plan)
        atomic(self.request['plan'], plan)
        with self.assertRaisesRegex(ValueError, '范围'):
            self.engine.apply({'planRevision': plan['planRevision']})
        self.assertEqual(self.vault.created, [])

    def test_unknown_same_name_note_is_skipped_without_any_changes(self):
        self.vault.notes['Notes/视频1.md'] = 'USER NOTE'
        plan = self.engine.plan({'parameters': self.params})
        result = self.engine.apply({'planRevision': plan['planRevision']})
        self.assertEqual(result['results'][0]['reason'], 'conflict')
        self.assertEqual(self.vault.notes['Notes/视频1.md'], 'USER NOTE')
        self.assertEqual(len(self.vault.created), 1)

    def test_only_record_existing_marker_note_without_rewriting_it(self):
        raw = '---\nup: "[[NONE]]"\ncreatedTime: 2020-01-01 00:00:00\n---\n\n<!-- pkm-import: source-id=bilibili/BV1 -->\nOriginal owned note'
        self.vault.notes['Notes/existing.md'] = raw
        plan = self.engine.plan({'parameters': self.params})
        result = self.engine.apply({'planRevision': plan['planRevision']})
        self.assertEqual(result['results'][0]['status'], 'recorded')
        self.assertEqual(self.vault.notes['Notes/existing.md'], raw)
        self.assertEqual(len(self.vault.created), 1)

    def test_ledger_and_vault_lock_prevent_parallel_mutation(self):
        from pkm_engine import locks
        with locks(self.request):
            with self.assertRaisesRegex(ValueError, '正在导入'):
                self.engine.apply(self.payload)
        self.assertEqual(self.vault.created, [])

    def test_read_only_bridge_defers_local_state_without_writing_vault_or_ledger(self):
        request = dict(self.request, _defer_writes=True, plan=str(self.root / 'isolated/plan.json'))
        engine = Engine(self.base, request, self.vault)
        inspection = engine.execute('inspect', {'readPaths': ['Templates/Note.md']})
        plan = engine.execute('plan', {'parameters': self.params})
        self.assertIn('inspection.json', inspection['_artifacts'])
        self.assertIn('plan.json', plan['_artifacts'])
        self.assertFalse(Path(request['plan']).exists())
        self.assertFalse(Path(request['ledger']).exists())
        self.assertEqual(self.vault.created, [])


if __name__ == '__main__':
    unittest.main()
