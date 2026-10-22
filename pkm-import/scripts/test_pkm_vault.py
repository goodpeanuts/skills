"""Execute the actual RPC JavaScript against an isolated in-memory Obsidian API."""
import base64
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from pkm_vault import Vault, run_rpc_cli

HARNESS = r'''
const readline=require('node:readline');globalThis.crypto=require('node:crypto').webcrypto;
const notes=new Map([['Notes/test.md','initial']]);const binary=new Map();
const f=p=>notes.has(p)||binary.has(p)?{path:p,extension:p.split('.').at(-1),stat:{size:0}}:null;
globalThis.app={internalPlugins:{getPluginById:()=>({instance:{options:{folder:'Templates'}}})},vault:{getFiles:()=>Array.from(notes.keys()).map(f),getMarkdownFiles:()=>Array.from(notes.keys()).filter(p=>p.endsWith('.md')).map(f),getAbstractFileByPath:f,read:async f=>notes.get(f.path),
readBinary:async f=>binary.get(f.path),process:async(f,fn)=>notes.set(f.path,fn(notes.get(f.path))),
createBinary:async(p,b)=>{if(f(p))throw Error('exists');binary.set(p,b)},getName:()=> 'Vault',adapter:{getBasePath:()=>'/test/vault'}}};
(async()=>{for await(const line of readline.createInterface({input:process.stdin})){let logs=[];const before=console.log;console.log=x=>logs.push(String(x));try{const result=await eval(JSON.parse(line));if(typeof result!=="string")throw Error("RPC must return its envelope");process.stdout.write(JSON.stringify({stdout:logs.concat('=> '+result).join('\n')+'\n'})+'\n')}catch(e){process.stdout.write(JSON.stringify({error:String(e)})+'\n')}finally{console.log=before}}})();
'''


class CliTransportTests(unittest.TestCase):
    def test_complete_reply_does_not_wait_for_a_lingering_client_or_replay(self):
        import sys
        import time
        packet = '=> PKM_RPC:' + base64.b64encode(json.dumps({'ok': True, 'value': '中文😀'}).encode()).decode()
        code = 'import time; print(' + repr(packet) + ', flush=True); time.sleep(60)'
        start = time.monotonic()
        with patch('pkm_vault.subprocess.Popen', wraps=subprocess.Popen) as spawn:
            result = run_rpc_cli([sys.executable, '-c', code], timeout=2)
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.decode().strip(), packet)
        self.assertEqual(spawn.call_count, 1)

    def test_incomplete_reply_times_out_and_does_not_replay(self):
        import sys
        code = "import time; print('=> PKM_RPC:truncated', flush=True); time.sleep(60)"
        with patch('pkm_vault.subprocess.Popen', wraps=subprocess.Popen) as spawn:
            with self.assertRaises(subprocess.TimeoutExpired):
                run_rpc_cli([sys.executable, '-c', code], timeout=0.15)
        self.assertEqual(spawn.call_count, 1)


class RpcTests(unittest.TestCase):
    def setUp(self):
        self.node = subprocess.Popen(['node', '-e', HARNESS], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.close)
        self.vault = Vault('Vault')
        self.mock = patch('pkm_vault.run_rpc_cli', side_effect=self.run_cli)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def close(self):
        self.node.stdin.close()
        self.node.wait(timeout=5)
        self.node.stdout.close()
        self.node.stderr.close()

    def run_cli(self, argv, **kwargs):
        self.assertEqual(argv[:3], ['obsidian', 'vault=Vault', 'eval'])
        code = argv[3].removeprefix('code=')
        self.assertTrue(code.isascii())
        self.assertLess(len(code), 32768)
        self.node.stdin.write(json.dumps(code) + '\n')
        self.node.stdin.flush()
        value = json.loads(self.node.stdout.readline())
        return subprocess.CompletedProcess(argv, 0, value.get('stdout', '').encode(), value.get('error', '').encode())

    def test_multibyte_long_text_literal_escapes_and_code_fences_round_trip(self):
        content = '# 中文😀\n```js\nconst s="\\n\\t\\\\\\\"";\n```\n' * 1200
        self.assertGreater(len(content.encode()), 8192)
        self.vault.write('Notes/test.md', content, expected='initial')
        self.assertEqual(self.vault.read('Notes/test.md'), content)
        self.vault.write('Notes/test.md', content + '更新', expected=content)
        self.assertEqual(self.vault.read('Notes/test.md'), content + '更新')

    def test_binary_chunks_round_trip_with_hash_verification(self):
        raw = bytes(range(256)) * 1100
        self.vault.write('Assets/frame.jpg', raw, binary=True)
        import hashlib
        self.assertEqual(self.vault.rpc('binary_hash', path='Assets/frame.jpg'), hashlib.sha256(raw).hexdigest())

    def test_out_of_order_or_corrupt_chunks_do_not_modify_a_note(self):
        self.vault.rpc('begin', id='bad', path='Notes/test.md', bytes=3, sha='wrong', kind='text', expected='initial')
        with self.assertRaisesRegex(RuntimeError, 'out of order'):
            self.vault.rpc('chunk', id='bad', index=1, data='YWJj')
        self.vault.rpc('chunk', id='bad', index=0, data='YWJj')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            self.vault.rpc('commit', id='bad')
        self.assertEqual(self.vault.read('Notes/test.md'), 'initial')

    def test_stale_content_is_never_overwritten(self):
        with self.assertRaisesRegex(RuntimeError, 'concurrently'):
            self.vault.write('Notes/test.md', 'replacement', expected='stale')
        self.assertEqual(self.vault.read('Notes/test.md'), 'initial')

    def test_markers_only_claim_first_body_line_and_template_config_is_dynamic(self):
        sid = 'bilibili/BV1'
        self.vault.write('Notes/test.md', 'intro\n<!-- pkm-import: source-id=' + sid + ' -->', expected='initial')
        self.assertEqual(self.vault.rpc('markers', folder='Notes', ids=[sid]), [])
        before = self.vault.read('Notes/test.md')
        self.vault.write('Notes/test.md', '---\nup: test\n---\n\n<!-- pkm-import: source-id=' + sid + ' -->\nbody', expected=before)
        self.assertEqual(self.vault.rpc('markers', folder='Notes', ids=[sid]), [{'source_id': sid, 'path': 'Notes/test.md'}])
        self.assertEqual(self.vault.rpc('template_folder'), 'Templates')

    def test_missing_truncated_or_invalid_cli_packets_are_errors(self):
        for raw in [b'Vault not found.', b'PKM_RPC:truncated', b'PKM_RPC:abc\nPKM_RPC:abc']:
            with patch('pkm_vault.run_rpc_cli', return_value=subprocess.CompletedProcess([], 0, raw, b'')):
                with self.assertRaises(RuntimeError):
                    self.vault.read('Notes/test.md')

    def test_timeout_does_not_replay_a_mutating_cli_request(self):
        timeout = subprocess.TimeoutExpired(['obsidian', 'eval'], 60)
        with patch('pkm_vault.run_rpc_cli', side_effect=timeout) as run:
            with self.assertRaisesRegex(RuntimeError, '超时'):
                self.vault.rpc('commit', id='owned-transfer')
        self.assertEqual(run.call_count, 1)

    def test_vault_paths_cannot_escape(self):
        for path in ['../outside.md', '/outside.md', 'a/../../b.md', 'a\\b.md']:
            with self.assertRaises(ValueError):
                self.vault.read(path)


if __name__ == '__main__':
    unittest.main()
