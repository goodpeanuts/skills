#!/usr/bin/env bash
# Real yt-dlp/ffmpeg loopback E2E; no external videos, credentials, or ASR model calls.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SKILL=$(cd "$(dirname "$0")/../.." && pwd)
PREP="$SKILL/scripts/pipeline_prepare.sh"
E2E=$(mktemp -d /tmp/vs-e2e-local-XXXX)
PORT=${PORT:-$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")}
cleanup() { if [[ -n "${SRV:-}" ]]; then kill "$SRV" 2>/dev/null || true; fi; rm -rf "$E2E"; }
trap cleanup EXIT
mkdir -p "$E2E/proj" "$E2E/media"
ffmpeg -y -loglevel error -f lavfi -i testsrc2=duration=6:size=640x360:rate=15 \
  -f lavfi -i sine=frequency=440:duration=6 -c:v libx264 -c:a aac -shortest "$E2E/media/clip.mp4"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$E2E/media" > "$E2E/server.log" 2>&1 &
SRV=$!
sleep 1
kill -0 "$SRV"
cd "$E2E/proj"
U="http://127.0.0.1:$PORT/clip.mp4"
json_get() { python3 -c 'import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
prepare() { bash "$PREP" "$@" 2> "$E2E/prepare.err" | tail -1; }
publish() {
  python3 - "$1" <<'PY'
import json,sys
from pathlib import Path
h=json.loads(sys.argv[1]);folder=Path(h['folder'])
# Test subtitle fixture substitutes for an ASR call on the synthetic sine-wave source.
sub=folder/'raw/subtitle.srt'
if not sub.exists():sub.write_text('1\n00:00:00,000 --> 00:00:05,000\n本地测试字幕内容\n')
text='# 本地视频测试\n\n> generic · fixture · 时长 6秒 · [原片]('+h['url']+') · 总结于 2026-10-20 · test-model · test-harness\n\n'
if h['mode']=='quick':text+='基于字幕及文本资料生成，未分析画面。\n\n'
text+='## TL;DR\n本地合成媒体用于验证素材复用和两个模式独立归档。\n'
Path(h['summary_output']).write_text(text)
Path(h['evidence_output']).write_text('# 来源底稿\n本地媒体和明确的测试字幕夹具。')
PY
  bash "$PREP" finish --folder "$(json_get "$1" folder)" --mode "$(json_get "$1" mode)" \
    --run-id "$(json_get "$1" run_id)" --agent-model test-model --harness test-harness --subtitle-lang zh --subtitle-source asr
}
q=$(prepare quick "$U")
f=$(json_get "$q" folder)
[[ ! -d "$f/evidence/frames" && ! -f "$f/raw/video.mp4" ]]
publish "$q"
sub_stamp=$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).stat().st_mtime_ns)' "$f/raw/subtitle.srt")
d=$(prepare "$U")
[[ "$(json_get "$d" folder)" == "$f" && -f "$f/raw/video.mp4" ]]
[[ -n "$(find "$f/evidence/frames" -name '*.jpg' -print -quit)" ]]
publish "$d"
video_stamp=$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).stat().st_mtime_ns)' "$f/raw/video.mp4")
if bash "$PREP" quick "$U" > "$E2E/rejected.out" 2>&1; then echo 'FAIL: overwrite without confirmation'; exit 1; fi
q2=$(prepare quick "$U" --force)
publish "$q2"
python3 - "$f" "$sub_stamp" "$video_stamp" <<'PY'
import json,sys
from pathlib import Path
f=Path(sys.argv[1]);m=json.loads((f/'raw/meta.json').read_text())
assert (f/'raw/subtitle.srt').stat().st_mtime_ns==int(sys.argv[2])
assert (f/'raw/video.mp4').stat().st_mtime_ns==int(sys.argv[3])
assert set(m['summaries'])=={'quick','deep'}
assert (f/'brief.md').is_file() and (f/'summary.md').is_file()
assert not list(f.rglob('*.stale')) and not list(f.rglob('*.bak'))
print('PASS: real media, stable reuse, mode coexistence, overwrite confirmation')
PY
bash "$PREP" verify --folder "$f"
