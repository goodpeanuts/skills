#!/usr/bin/env bash
# run_unit_tests.sh —— video-summarizer 离线单元测试（无需网络；需 python3，部分用例需 ffmpeg）
# 用法: bash scripts/tests/run_unit_tests.sh   （在任意目录均可运行）
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # 不在 skill 目录产生 __pycache__

SKILL=$(cd "$(dirname "$0")/../.." && pwd)
META="$SKILL/scripts/pipeline_meta.py"
SBOX=$(mktemp -d /tmp/vs-unit-XXXX)
trap 'rm -rf "$SBOX"' EXIT
pass=0 fail=0

ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; }
check(){ # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (期望 [$2] 实得 [$3])"; fi
}

echo "== 1. sanitize_component =="
check "非法字符→_"            "a_b_c"    "$(python3 "$META" sanitize 'a<b>c')"
check "保留名规避"            "_con"     "$(python3 "$META" sanitize 'con')"
check "空兜底"               "untitled" "$(python3 "$META" sanitize '   ._. ')"
check "结尾点剥离"            "abc"      "$(python3 "$META" sanitize 'abc.')"
check "unicode 保留"          "中文标题"   "$(python3 "$META" sanitize '中文标题')"
check "占位吸收空白"          "AC_DC"    "$(python3 "$META" sanitize 'AC / DC')"

echo "== 2. select_subtitle（中文读者默认偏好） =="
sel() { python3 -c '
import json, sys
sys.path.insert(0, "'"$SKILL"'/scripts")
from pipeline_meta import select_subtitle
info = json.loads(sys.argv[1])
print(json.dumps(select_subtitle(info, sys.argv[2]), ensure_ascii=False))' "$1" "${2:-}"; }
p2v() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["lang"]+"|"+d["source"])'; }
check "manual zh-Hans 最优"  "zh-Hans|manual"  "$(sel '{"subtitles":{"zh-Hans":[],"en":[]},"automatic_captions":{"zh":[]}}' | p2v)"
check "ai-zh 归 manual 且等价 zh" "ai-zh|manual"  "$(sel '{"subtitles":{"ai-zh":[],"en":[]}}' | p2v)"
check "auto 兜底（无 manual）"  "zh|auto"  "$(sel '{"automatic_captions":{"zh":[],"en":[]}}' | p2v)"
check "原语言插在 zh 系后 en 前" "ja|manual"  "$(sel '{"subtitles":{"ja":[],"en":[]},"language":"ja"}' | p2v)"
check "sub-pref 覆盖"        "en|manual"  "$(sel '{"subtitles":{"ja":[],"en":[]},"language":"ja"}' 'en' | p2v)"
check "danmaku 伪语言不参与"  "none|none"  "$(sel '{"subtitles":{"danmaku":[]}}' | p2v)"

echo "== 3. distill: 平台键消歧 / host / media_kind =="
python3 - "$SBOX" <<'EOF'
import json, sys
from pathlib import Path
sbox = Path(sys.argv[1])
base = {"_type": "video", "id": "clip001", "title": "Same Id Two Sites", "webpage_url": "",
        "duration": 60, "extractor_key": "Generic", "subtitles": {}, "automatic_captions": {}}
for name, host in (("a", "example-a.com"), ("b", "www.example-b.org")):
    d = dict(base, webpage_url=f"https://{host}:8443/videos/clip001.mp4")
    (sbox / f"info_{name}.json").write_text(json.dumps(d))
(sbox / "info_nourl.json").write_text(json.dumps(dict(base, webpage_url="", extractor_key="Generic")))
(sbox / "info_bili.json").write_text(json.dumps(dict(
    base, extractor_key="BiliBri", webpage_url="https://www.bilibili.com/video/BV14tTj6CEuM")))
(sbox / "info_audio.json").write_text(json.dumps(dict(base, webpage_url="https://pod.example.com/ep1.mp3", vcodec="none")))
(sbox / "info_audio2.json").write_text(json.dumps(dict(base, webpage_url="https://pod2.example.com/ep1",
    formats=[{"vcodec": "none", "acodec": "mp3"}])))
(sbox / "info_video.json").write_text(json.dumps(dict(base, webpage_url="https://v.example.com/v1", vcodec="h264")))
EOF
for f in a b nourl bili audio audio2 video; do
  python3 "$META" distill "$SBOX/info_$f.json" --out "$SBOX/dist_$f.json"
done
dget() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
pa=$(dget "$SBOX/dist_a.json" platform); pb=$(dget "$SBOX/dist_b.json" platform)
check "generic 站 A 键形如 generic_<hash8>" "yes" "$([[ "$pa" =~ ^generic_[0-9a-f]{8}$ ]] && echo yes)"
check "generic 站 B 键不同"               "yes" "$([[ "$pa" != "$pb" ]] && echo yes)"
check "generic 无 URL 兜底可算"            "yes" "$([[ "$(dget "$SBOX/dist_nourl.json" platform)" =~ ^generic_[0-9a-f]{8}$ ]] && echo yes)"
check "非 generic 平台键不受影响"           "bilibri" "$(dget "$SBOX/dist_bili.json" platform)"
check "host 字段（剥 www/端口）"            "example-a.com" "$(dget "$SBOX/dist_a.json" host)"
check "media_kind: vcodec=none"            "audio" "$(dget "$SBOX/dist_audio.json" media_kind)"
check "media_kind: formats 全 none"        "audio" "$(dget "$SBOX/dist_audio2.json" media_kind)"
check "media_kind: 视频"                   "video" "$(dget "$SBOX/dist_video.json" media_kind)"

echo "== 4. distill: chapters end_time / upload_date / playlist =="
python3 - "$SBOX" <<'EOF'
import json, sys
from pathlib import Path
sbox = Path(sys.argv[1])
d = {"_type": "video", "id": "v1", "title": "T", "webpage_url": "https://x.com/v1",
     "duration": 90, "extractor_key": "Some", "upload_date": "20260801",
     "uploader_id": "uid-1", "chapters": [{"start_time": 0, "end_time": 45, "title": "A"},
                                           {"start_time": 45, "end_time": 90, "title": "B"}]}
(sbox / "info_ch.json").write_text(json.dumps(d))
(sbox / "info_pl.json").write_text(json.dumps({"_type": "playlist", "entries": []}))
EOF
python3 "$META" distill "$SBOX/info_ch.json" --out "$SBOX/dist_ch.json"
python3 "$META" distill "$SBOX/info_pl.json" --out "$SBOX/dist_pl.json"
check "chapter 保留 end_time"  "45" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/dist_ch.json"))["chapters"][0]["end_time"])')"
check "upload_date 蒸馏"       "20260801" "$(dget "$SBOX/dist_ch.json" upload_date)"
check "uploader_id 蒸馏"       "uid-1" "$(dget "$SBOX/dist_ch.json" uploader_id)"
check "playlist 识别"          "True" "$(dget "$SBOX/dist_pl.json" is_playlist)"

echo "== 5. cookie-platform / on-failure / capability（platforms.json 驱动，host 匹配） =="
check "bilibili 域名命中"    "bilibili" "$(python3 "$META" cookie-platform 'https://www.bilibili.com/video/BV1xx')"
check "m. 子域命中"          "bilibili" "$(python3 "$META" cookie-platform 'https://m.bilibili.com/x')"
check "b23.tv 短链命中"     "bilibili" "$(python3 "$META" cookie-platform 'https://b23.tv/abc123')"
check "伪装参数不命中(H6)"   ""        "$(python3 "$META" cookie-platform 'https://evil.com/?ref=bilibili.com')"
check "youtube 不命中"      ""        "$(python3 "$META" cookie-platform 'https://www.youtube.com/watch?v=x')"
check "bilibili 失败策略"    "degrade" "$(python3 "$META" cookie-on-failure 'https://www.bilibili.com/video/BV1xx')"
check "未配置平台无失败策略(空)" ""       "$(python3 "$META" cookie-on-failure 'https://www.youtube.com/watch?v=x')"
check "bilibili 弹幕能力"    "bilibili_xml" "$(python3 "$META" capability bilibili danmaku)"
check "bilibili 评论方式"    "bilibili_api" "$(python3 "$META" capability bilibili comments)"
check "youtube 弹幕能力缺失"  ""        "$(python3 "$META" capability youtube danmaku)"

echo "== 6. finalize: meta.json 与交接 JSON 契约字段 =="
mkdir -p "$SBOX/pkg"
python3 "$META" finalize "$SBOX/dist_ch.json" --folder "$SBOX/pkg" \
  --video-file "raw/video.mp4" --audio-file "raw/audio.mp3" \
  --subtitle-lang "none" --subtitle-source "none" --needs-whisper 1 \
  --has-danmaku 1 --has-comments 0 --frames-max 8 --frames-extracted 7 \
  --uploader-id "uid-1" --upload-date "20260801" --account "测试账号" > "$SBOX/handoff.json"
for k in uploader_id upload_date account needs_whisper has_danmaku has_comments host media_kind; do
  check "交接 JSON 含 $k" "yes" "$(python3 -c 'import json;print("yes" if "'$k'" in json.load(open("'$SBOX'/handoff.json")) else "no")')"
done
for k in uploader_id upload_date account needs_whisper capabilities frames host media_kind; do
  check "meta.json 含 $k" "yes" "$(python3 -c 'import json;print("yes" if "'$k'" in json.load(open("'$SBOX'/pkg/meta.json")) else "no")')"
done
check "meta frames.extracted" "7" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/pkg/meta.json"))["frames"]["extracted"])')"

echo "== 7. finish: meta 装配 + 终态回写 + registry 损坏备份 + 字段补齐 =="
PROJ="$SBOX/proj"; mkdir -p "$PROJ/archive"
cp -r "$SBOX/pkg" "$PROJ/archive/demo"
echo "# summary" > "$PROJ/archive/demo/summary.md"
cd "$PROJ"
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/demo" \
  --subtitle-lang "zh" --subtitle-source "whisper" > /dev/null
check "registry 条目生成" "yes" "$(python3 -c 'import json;print("yes" if json.load(open("archive/registry.json"))["videos"]["some"]["v1"] else "no")')"
check "registry 字幕终态=whisper" "whisper" "$(python3 -c 'import json;print(json.load(open("archive/registry.json"))["videos"]["some"]["v1"]["subtitle_source"])')"
check "registry 含 upload_date" "20260801" "$(python3 -c 'import json;print(json.load(open("archive/registry.json"))["videos"]["some"]["v1"]["upload_date"])')"
check "registry 含 uploader_id" "uid-1" "$(python3 -c 'import json;print(json.load(open("archive/registry.json"))["videos"]["some"]["v1"]["uploader_id"])')"
check "registry 含 host" "x.com" "$(python3 -c 'import json;print(json.load(open("archive/registry.json"))["videos"]["some"]["v1"]["host"])')"
check "meta.json 同步回写 whisper" "whisper" "$(python3 -c 'import json;print(json.load(open("archive/demo/meta.json"))["subtitle"]["source"])')"
echo "{corrupted" > archive/registry.json
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/demo" > /dev/null 2>&1
backup=$(ls archive/registry.json.corrupt-* 2>/dev/null | head -1)
check "损坏 registry 有备份" "yes" "$([[ -n "$backup" ]] && echo yes)"
check "重建后条目有效"       "yes" "$(python3 -c 'import json;print("yes" if json.load(open("archive/registry.json"))["videos"]["some"]["v1"] else "no")')"
rm archive/demo/summary.md
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/demo" >/dev/null 2>&1 && rc=0 || rc=1
check "缺 summary.md 拒写" "1" "$rc"
bash "$SKILL/scripts/pipeline_prepare.sh" finish --platform x --id y --title t --folder archive/demo >/dev/null 2>&1 && rc=0 || rc=1
check "旧接口参数被拒" "1" "$rc"

echo "== 8. extract_frames 参数严格性 =="
mkdir -p "$SBOX/frames"
if command -v ffmpeg >/dev/null; then
  ffmpeg -y -loglevel error -f lavfi -i testsrc2=duration=3:size=320x240:rate=10 \
    -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -c:a aac -shortest "$SBOX/t.mp4"
  bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --bogus x >/dev/null 2>&1 && rc=0 || rc=1
  check "未知参数报错退出" "1" "$rc"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --max 2 2>&1)
  check "机械抽帧正常" "yes" "$([[ "$out" == *"extracted=2"* ]] && echo yes)"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --at "1,2" 2>&1)
  check "agent 补帧正常" "yes" "$([[ "$out" == *"mode=agent"* ]] && echo yes)"
else
  echo "  （跳过：无 ffmpeg）"
fi

echo "== 9. audience.py 配置读取 + 异常面 =="
python3 -c "
import sys; sys.path.insert(0, '$SKILL/scripts')
import audience
name, ua = audience.bili_cookie_cfg()
assert name == 'SESSDATA' and ua.startswith('Mozilla/5.0'), (name, ua)
print('  ✓ bili_cookie_cfg 从 platforms.json 读取')
" && pass=$((pass+1)) || bad "audience 配置读取"
python3 -c "
import sys, urllib.error; sys.path.insert(0, '$SKILL/scripts')
import audience
class R(urllib.error.HTTPError):
    def __init__(self): pass
try:
    raise urllib.error.HTTPError('u', 412, 'blocked', None, None)
except urllib.error.HTTPError as e:
    try:
        audience.http_json.__wrapped__ if False else None
    except Exception:
        pass
# 直接验证包装: 手动触发 HTTPError 路径
import io
from unittest import mock
with mock.patch('urllib.request.urlopen', side_effect=urllib.error.HTTPError('u', 412, 'blocked', None, None)):
    try:
        audience.http_json('https://x', '', 'SESSDATA')
        raise SystemExit('应抛 AudienceError')
    except audience.AudienceError as e:
        assert '412' in str(e) and '风控' in str(e), str(e)
print('  ✓ HTTP 412 包装为 AudienceError（含风控提示）')
" && pass=$((pass+1)) || bad "audience HTTP 异常包装"

echo "== 10. parallel_transcribe: m4a 分片容器跟随输入 =="
if command -v ffmpeg >/dev/null; then
  python3 -c "
import sys, os, tempfile
sys.path.insert(0, '$SKILL/scripts')
import parallel_transcribe as pt
d = tempfile.mkdtemp()
src = os.path.join(d, 'a.m4a')
os.system(f'ffmpeg -y -loglevel error -f lavfi -i sine=duration=6 -c:a aac {src}')
chunks = pt.split_audio(src, [3.0], d)
exts = {os.path.splitext(c)[1] for c, _ in chunks}
assert exts == {'.m4a'}, exts
assert all(os.path.getsize(c) > 0 for c, _ in chunks)
print('  ✓ m4a 输入分片为 .m4a（不再进 mp3 容器崩溃）')
" && pass=$((pass+1)) || bad "m4a 分片"
else
  echo "  （跳过：无 ffmpeg）"
fi

echo "== 11. ensure_cookies: 手动提示与缓存目录参数 =="
out=$(python3 "$SKILL/scripts/ensure_cookies.py" status --platform notconfigured 2>&1)
check "未配置平台 status 不崩" "yes" "$(python3 -c 'import json,sys;print("yes" if json.loads(sys.argv[1]).get("configured") is False else "no")' "$out")"
hint=$(python3 -c 'import sys; sys.path.insert(0, "'"'"'$SKILL/scripts'"'"'"); from ensure_cookies import MANUAL_HINT; print(MANUAL_HINT.format(platform="p"))')
check "MANUAL_HINT 不再要求手写 cookies.json" "no" "$(python3 -c 'import sys; print("yes" if "cookies.json" in sys.argv[1] and "无需手写" not in sys.argv[1] else "no")' "$hint")"

echo ""
echo "===== 结果: pass=$pass fail=$fail ====="
[[ $fail -eq 0 ]]
