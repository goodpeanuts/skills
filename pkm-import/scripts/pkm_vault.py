"""Bounded ASCII RPC over Obsidian CLI; all vault effects use Obsidian APIs."""
import base64
import hashlib
import json
import queue
import threading
import time
from pathlib import PurePosixPath
import subprocess
import uuid

PREFIX = 'PKM_RPC:'
# Only fixed operations are executable. Source text is data, never interpolated JavaScript.
RPC = r'''(async()=>{const p=JSON.parse(atob("PAYLOAD"));const v=app.vault;
const path=x=>{if(typeof x!=="string"||!x||x.startsWith("/")||x.includes("\\")||x.split("/").includes(".."))throw Error("Invalid vault path");return x};
const file=x=>{const f=v.getAbstractFileByPath(path(x));if(!f||!f.extension)throw Error("File not found: "+x);return f};
const marked=(text,id)=>{let body=text;if(text.startsWith("---\n")){const end=text.indexOf("\n---",3);if(end<0)return false;body=text.slice(end+4)}return body.replace(/^[\r\n]+/,"").split("\n")[0].trim()==="<!-- pkm-import: source-id="+id+" -->"};
const enc=s=>btoa(Array.from(new TextEncoder().encode(s),x=>String.fromCharCode(x)).join(""));
const decode=s=>Uint8Array.from(atob(s),x=>x.charCodeAt(0));
const hash=async b=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",b)),x=>x.toString(16).padStart(2,"0")).join("");
let value;try{switch(p.op){
case "template_folder":{const instance=app.internalPlugins?.getPluginById("templates")?.instance;if(!instance||typeof instance.options?.folder!=="string")throw Error("Templates configuration unavailable");value=instance.options.folder;break;}
case "identity":value={name:v.getName(),path:v.adapter.getBasePath(),eval:true};break;
case "list":value=v.getFiles().filter(f=>!p.folder||f.path.startsWith(path(p.folder).replace(/\/$/,"")+"/")).map(f=>f.path);break;
case "read":{const f=v.getAbstractFileByPath(path(p.path));value=f?await v.read(file(p.path)):null;break;}
case "read_many":value={};for(const x of p.paths){const f=v.getAbstractFileByPath(path(x));value[x]=f?await v.read(file(x)):null}break;
case "identity_matches":{value=[];for(const f of v.getMarkdownFiles()){if((p.exclude||[]).includes(f.path))continue;const text=await v.read(f);const m=/^createdTime:\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"?/m.exec(text);if(m&&m[1]===p.value)value.push(f.path)}break;}
case "markers":{value=[];for(const f of v.getMarkdownFiles()){if(p.folder&&p.folder!=="."&&!f.path.startsWith(path(p.folder)+"/"))continue;const text=await v.read(f);for(const id of p.ids)if(marked(text,id))value.push({source_id:id,path:f.path})}break;}
case "stat":{const f=v.getAbstractFileByPath(path(p.path));value=f?{path:f.path,size:f.stat?.size,folder:!f.extension}:null;break;}
case "binary_hash":{const f=v.getAbstractFileByPath(path(p.path));value=f?await hash(await v.readBinary(file(p.path))):null;break;}
case "mkdir":{if(p.path==="."){value=true;break;}let root="";for(const part of path(p.path).split("/")){root+=(root?"/":"")+part;if(!v.getAbstractFileByPath(root))await v.createFolder(root)}value=true;break;}
case "begin":{if(!Number.isInteger(p.bytes)||p.bytes<0||p.bytes>67108864)throw Error("Transfer size invalid");globalThis.__pkmTransfers??={};const t=globalThis.__pkmTransfers;for(const k of Object.keys(t))if(Date.now()-t[k].at>600000)delete t[k];t[p.id]={at:Date.now(),chunks:[],bytes:p.bytes,sha:p.sha,path:path(p.path),kind:p.kind,expected:p.expected_sha};value=true;break;}
case "chunk":{const t=globalThis.__pkmTransfers?.[p.id];if(!t||t.chunks.length!==p.index)throw Error("Transfer interrupted or out of order");t.chunks.push(p.data);value=t.chunks.length;break;}
case "commit":{const t=globalThis.__pkmTransfers?.[p.id];if(!t)throw Error("Transfer missing");try{const b=decode(t.chunks.join(""));if(b.length!==t.bytes||await hash(b)!==t.sha)throw Error("Transfer checksum mismatch");if(t.kind==="binary"){if(v.getAbstractFileByPath(t.path))throw Error("Attachment appeared during transfer");await v.createBinary(t.path,b.buffer)}else{const text=new TextDecoder("utf-8",{fatal:true}).decode(b);const original=await v.read(file(t.path));if(await hash(new TextEncoder().encode(original))!==t.expected)throw Error("Note changed concurrently");await v.process(file(t.path),current=>{if(current!==original)throw Error("Note changed concurrently");return text})}value=true}finally{delete globalThis.__pkmTransfers[p.id]}break;}
case "abort":delete globalThis.__pkmTransfers?.[p.id];value=true;break;
default:throw Error("Unsupported vault operation")}
return "PKM_RPC:"+enc(JSON.stringify({ok:true,value}))
}catch(e){return "PKM_RPC:"+enc(JSON.stringify({ok:false,error:String(e.message||e)}))}})()'''


def relative_path(value):
    if not isinstance(value, str) or not value or '\\' in value or '\x00' in value:
        raise ValueError('库内路径无效')
    p = PurePosixPath(value)
    if p.is_absolute() or '..' in p.parts or (len(value) > 1 and value[1] == ':') or any(c in value for c in '\r\n'):
        raise ValueError('路径越过目标库')
    return p.as_posix()


def run_rpc_cli(argv, timeout=60):
    """A complete RPC reply is the acknowledgement; retire a lingering CLI client."""
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    events = queue.Queue()
    output = {'stdout': [], 'stderr': []}
    def collect(stream, name):
        try:
            for line in iter(stream.readline, b''):
                events.put((name, line))
        finally:
            events.put((name, None))
    threads = [threading.Thread(target=collect, args=(stream, name), daemon=True)
               for stream, name in ((proc.stdout, 'stdout'), (proc.stderr, 'stderr'))]
    for thread in threads:
        thread.start()
    deadline, closed, acknowledged = time.monotonic() + timeout, set(), False
    try:
        while len(closed) < 2:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            try:
                name, line = events.get(timeout=remaining)
            except queue.Empty as exc:
                raise subprocess.TimeoutExpired(argv, timeout) from exc
            if line is None:
                closed.add(name)
                continue
            output[name].append(line)
            if name == 'stdout':
                value = line.decode('ascii', 'replace').strip().removeprefix('=> ')
                if value.startswith(PREFIX):
                    try:
                        reply = json.loads(base64.b64decode(value[len(PREFIX):], validate=True).decode('utf-8'))
                        acknowledged = isinstance(reply, dict) and isinstance(reply.get('ok'), bool)
                    except (ValueError, UnicodeError):
                        pass
                if acknowledged:
                    break
        try:
            proc.wait(timeout=0.05 if acknowledged else max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            if not acknowledged:
                raise
            # The fixed RPC has finished before producing its reply. End only this client, never replay it.
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=1)
            returncode = 0
        else:
            returncode = proc.returncode
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=1)
        for thread in threads:
            thread.join(timeout=1)
        while not events.empty():
            name, line = events.get_nowait()
            if line is not None:
                output[name].append(line)
        proc.stdout.close()
        proc.stderr.close()
    return subprocess.CompletedProcess(argv, returncode, b''.join(output['stdout']), b''.join(output['stderr']))


class Vault:
    def __init__(self, name):
        self.name = name

    def rpc(self, op, **values):
        payload = base64.b64encode(json.dumps(dict(op=op, **values), ensure_ascii=True).encode()).decode()
        code = RPC.replace('PAYLOAD', payload)
        try:
            proc = run_rpc_cli(['obsidian', f'vault={self.name}', 'eval', f'code={code}'], timeout=60)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError('CLI 超时；先查询本次状态，不能盲目重放写入') from exc
        if proc.returncode:
            raise RuntimeError((proc.stderr or proc.stdout).decode('utf-8', 'replace').strip() or 'Obsidian CLI 不可用')
        # Obsidian awaits the eval value and prefixes it with '=> '; avoid asynchronous console capture.
        lines = [line.removeprefix('=> ') for line in proc.stdout.decode('ascii', 'replace').splitlines()]
        packets = [line[len(PREFIX):] for line in lines if line.startswith(PREFIX)]
        if len(packets) != 1:
            raise RuntimeError('Obsidian CLI 响应缺失或截断；先查询状态')
        try:
            result = json.loads(base64.b64decode(packets[0], validate=True).decode('utf-8'))
        except (ValueError, UnicodeError) as exc:
            raise RuntimeError('Obsidian CLI 响应编码无效') from exc
        if not result.get('ok'):
            raise RuntimeError(result.get('error', 'Vault API 失败'))
        return result['value']

    def read(self, path):
        return self.rpc('read', path=relative_path(path))

    def write(self, path, data, expected=None, binary=False):
        path = relative_path(path)
        if isinstance(data, str):
            data = data.encode('utf-8')
        token = uuid.uuid4().hex
        self.rpc('begin', id=token, path=path, bytes=len(data), sha=hashlib.sha256(data).hexdigest(), kind='binary' if binary else 'text', expected_sha=hashlib.sha256(expected.encode('utf-8')).hexdigest() if isinstance(expected, str) else None)
        payload = base64.b64encode(data).decode('ascii')
        try:
            for index, start in enumerate(range(0, len(payload), 4096)):
                self.rpc('chunk', id=token, index=index, data=payload[start:start + 4096])
            self.rpc('commit', id=token)
        except Exception:
            try:
                self.rpc('abort', id=token)
            except Exception:
                pass
            raise
        if binary:
            if self.rpc('binary_hash', path=path) != hashlib.sha256(data).hexdigest():
                raise RuntimeError('附件完整回读不一致')
        elif self.read(path) != data.decode('utf-8'):
            raise RuntimeError('正文完整回读不一致')

    def create_template(self, path, template):
        # Never retry this mutating command after an ambiguous timeout.
        try:
            p = subprocess.run(['obsidian', f'vault={self.name}', 'create', f'path={relative_path(path)}', f'template={template}', 'silent'], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError('模板创建超时，归属尚不确定；请查询状态，不自动重建') from exc
        if p.returncode or p.stdout.startswith(('Error', 'Vault not found')):
            raise RuntimeError(p.stderr or p.stdout or '模板创建失败')
        created = [line for line in p.stdout.splitlines() if line.startswith('Created: ')]
        if created != ['Created: ' + relative_path(path)]:
            raise RuntimeError('模板创建返回位置不一致；归属不确定，保留现状，不覆盖或删除')

    def templates(self):
        p = subprocess.run(['obsidian', f'vault={self.name}', 'templates'], capture_output=True, text=True, timeout=30)
        if p.returncode or p.stdout.startswith(('Error', 'Vault not found')):
            raise RuntimeError(p.stderr or p.stdout or '无法读取模板列表')
        return [x.strip() for x in p.stdout.splitlines() if x.strip()]
