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

echo "== 4b. distill: collection 所属列表（采集时入口） =="
python3 - "$SBOX" <<'EOF'
import json, sys
from pathlib import Path
sbox = Path(sys.argv[1])
base = {"_type": "video", "id": "v9", "title": "T", "webpage_url": "https://x.com/v9",
        "duration": 60, "extractor_key": "Some"}
(sbox / "info_coll.json").write_text(json.dumps(dict(base, playlist_id="PL123", playlist_title="我的合集")))
(sbox / "info_self.json").write_text(json.dumps(dict(base, playlist_id="v9", playlist_title="多P自身")))
(sbox / "info_notitle.json").write_text(json.dumps(dict(base, playlist_id="PL456")))
EOF
for f in coll self notitle; do
  python3 "$META" distill "$SBOX/info_$f.json" --out "$SBOX/dist_$f.json"
done
cget() { python3 -c 'import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if v is None else v)' "$1" "$2"; }
check "collection 蒸馏 id/title"  "PL123|我的合集" "$(python3 -c 'import json;d=json.load(open("'$SBOX'/dist_coll.json"))["collection"];print(d["id"]+"|"+d["title"])')"
check "playlist_id==视频id 不算所属列表" "" "$(cget "$SBOX/dist_self.json" collection)"
check "无 playlist 字段则无所属列表"      "" "$(cget "$SBOX/dist_ch.json" collection)"
check "无 playlist_title 回退 id"       "PL456|PL456" "$(python3 -c 'import json;d=json.load(open("'$SBOX'/dist_notitle.json"))["collection"];print(d["id"]+"|"+d["title"])')"

echo "== 4c. collection_lookup: 合集归属反查回填（season_lookup 能力位） =="
psea() { python3 -c '
import json, sys
sys.path.insert(0, "'"$SKILL"'/scripts")
from pipeline_meta import parse_ugc_season
c = parse_ugc_season(json.loads(sys.argv[1]))
print("" if c is None else c["id"]+"|"+c["title"])' "$1"; }
check "season_lookup 能力位声明"      "bilibili_ugc" "$(python3 "$META" capability bilibili season_lookup)"
check "season_lookup 未配置平台为空"    ""             "$(python3 "$META" capability someplatform season_lookup)"
check "ugc_season 解析 id/title"     "4295406|玩转服务器" "$(psea '{"code":0,"data":{"ugc_season":{"id":4295406,"title":"玩转服务器"}}}')"
check "视频不属于合集返回空"            ""             "$(psea '{"code":0,"data":{}}')"
check "API code!=0 返回空"           ""             "$(psea '{"code":-404,"message":"啥都木有"}')"
check "ugc_season 缺 id 返回空"       ""             "$(psea '{"code":0,"data":{"ugc_season":{"title":"x"}}}')"
python3 - "$SBOX" <<'EOF'
import json, sys
from pathlib import Path
sbox = Path(sys.argv[1])
(sbox / "payload_season.json").write_text(json.dumps(
    {"code": 0, "data": {"ugc_season": {"id": 4295406, "title": "玩转服务器"}}}))
(sbox / "payload_empty.json").write_text(json.dumps({"code": 0, "data": {}}))
(sbox / "dist_lookup.json").write_text(json.dumps(
    {"platform": "bilibili", "id": "BV1xx411c7mD", "collection": None}))
(sbox / "dist_entry.json").write_text(json.dumps(
    {"platform": "bilibili", "id": "BV1xx", "collection": {"id": "PL999", "title": "入口列表"}}))
(sbox / "dist_audio.json").write_text(json.dumps(
    {"platform": "bilibili", "id": "au99", "collection": None}))
(sbox / "dist_generic.json").write_text(json.dumps(
    {"platform": "generic_abcd1234", "id": "x1", "collection": None}))
EOF
python3 "$META" collection_lookup bilibili BV1xx411c7mD --distilled "$SBOX/dist_lookup.json" \
  --payload-file "$SBOX/payload_season.json" 2>/dev/null
check "反查回填 id/title"            "4295406|玩转服务器" "$(python3 -c 'import json;d=json.load(open("'$SBOX'/dist_lookup.json"))["collection"];print(d["id"]+"|"+d["title"])')"
python3 "$META" collection_lookup bilibili BV1xx411c7mD --distilled "$SBOX/dist_lookup.json" \
  --payload-file "$SBOX/payload_empty.json" 2>/dev/null
check "无合集时已回填值保持不动"         "4295406|玩转服务器" "$(python3 -c 'import json;d=json.load(open("'$SBOX'/dist_lookup.json"))["collection"];print(d["id"]+"|"+d["title"])')"
python3 "$META" collection_lookup bilibili BV1xx --distilled "$SBOX/dist_entry.json" \
  --payload-file "$SBOX/payload_season.json" 2>/dev/null
check "入口 collection 优先不覆盖"     "PL999|入口列表"    "$(python3 -c 'import json;d=json.load(open("'$SBOX'/dist_entry.json"))["collection"];print(d["id"]+"|"+d["title"])')"
python3 "$META" collection_lookup bilibili au99 --distilled "$SBOX/dist_audio.json" \
  --payload-file "$SBOX/payload_season.json" 2>/dev/null
check "非 bvid 静默跳过"             ""             "$(cget "$SBOX/dist_audio.json" collection)"
python3 "$META" collection_lookup generic_abcd1234 x1 --distilled "$SBOX/dist_generic.json" \
  --payload-file "$SBOX/payload_season.json" 2>/dev/null
check "未配置平台静默跳过"             ""             "$(cget "$SBOX/dist_generic.json" collection)"
python3 "$META" collection_lookup generic_abcd1234 x1 >/dev/null 2>&1
check "缺席路径 exit 0（不阻塞采集）"    "0"            "$?"

echo "== 5. cookie-platform / on-failure / capability（platforms.json 驱动，host 匹配） =="
check "bilibili 域名命中"    "bilibili" "$(python3 "$META" cookie-platform 'https://www.bilibili.com/video/BV1xx')"
check "裸域命中"            "bilibili" "$(python3 "$META" cookie-platform 'https://bilibili.com/')"
check "m. 子域命中"          "bilibili" "$(python3 "$META" cookie-platform 'https://m.bilibili.com/x')"
check "b23.tv 短链命中"     "bilibili" "$(python3 "$META" cookie-platform 'https://b23.tv/abc123')"
check "伪装参数不命中(H6)"   ""        "$(python3 "$META" cookie-platform 'https://evil.com/?ref=bilibili.com')"
check "后缀伪装域不命中"      ""        "$(python3 "$META" cookie-platform 'https://bilibili.community/x')"
check "前缀伪装域不命中"      ""        "$(python3 "$META" cookie-platform 'https://evilbilibili.com/x')"
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
  check "meta.json 含 $k" "yes" "$(python3 -c 'import json;print("yes" if "'$k'" in json.load(open("'$SBOX'/pkg/raw/meta.json")) else "no")')"
done
check "meta frames.extracted" "7" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/pkg/raw/meta.json"))["frames"]["extracted"])')"
check "meta.json 落位 raw/（目录根无残留）" "no" "$(python3 -c 'import os,sys;print("yes" if os.path.exists(sys.argv[1]) else "no")' "$SBOX/pkg/meta.json")"
mkdir -p "$SBOX/pkg2"
python3 "$META" finalize "$SBOX/dist_coll.json" --folder "$SBOX/pkg2" \
  --video-file "" --audio-file "raw/audio.mp3" \
  --subtitle-lang "zh" --subtitle-source "manual" --needs-whisper 0 \
  --has-danmaku 0 --has-comments 0 --frames-max 8 --frames-extracted 8 > "$SBOX/handoff2.json"
check "交接 JSON collection_id"   "PL123"    "$(python3 -c 'import json;print(json.load(open("'$SBOX'/handoff2.json"))["collection_id"])')"
check "交接 JSON collection_title" "我的合集" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/handoff2.json"))["collection_title"])')"
check "交接 JSON 无列表时 collection_id 空" "" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/handoff.json"))["collection_id"])')"
check "meta.json 含 collection（嵌套）" "PL123" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/pkg2/raw/meta.json"))["collection"]["id"])')"
check "meta.json 无列表时 collection=None" "None" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/pkg/raw/meta.json"))["collection"])')"

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
check "meta.json 同步回写 whisper" "whisper" "$(python3 -c 'import json;print(json.load(open("archive/demo/raw/meta.json"))["subtitle"]["source"])')"
cp -r "$SBOX/pkg2" archive/demo2; echo "# s" > archive/demo2/summary.md
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/demo2" > /dev/null
check "registry 条目含 collection" "PL123|我的合集" "$(python3 -c 'import json;c=json.load(open("archive/registry.json"))["videos"]["some"]["v9"]["collection"];print(c["id"]+"|"+c["title"])')"
check "registry 无列表条目 collection=None" "None" "$(python3 -c 'import json;print(json.load(open("archive/registry.json"))["videos"]["some"]["v1"]["collection"])')"
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

# 并发 finish: 6 进程各写不同条目，全部落盘不丢（锁内 fsync 的回归测试）
mkdir -p archive/conc
for i in 1 2 3 4 5 6; do
  cp -r archive/demo "archive/conc/v$i"; echo "# s" > "archive/conc/v$i/summary.md"
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
m["id"] = "conc" + sys.argv[2]; m["title"] = "c" + sys.argv[2]
json.dump(m, open(sys.argv[1], "w"), ensure_ascii=False)' "archive/conc/v$i/raw/meta.json" "$i"
done
for i in 1 2 3 4 5 6; do
  bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/conc/v$i" >/dev/null 2>&1 &
done
wait
n=$(python3 -c 'import json;print(len(json.load(open("archive/registry.json"))["videos"]["some"]))')
check "并发 finish 无丢失更新" "7" "$n"   # demo + 6 并发

echo "== 8. extract_frames 参数严格性 + 近重复帧剔除 =="
mkdir -p "$SBOX/frames"
if command -v ffmpeg >/dev/null; then
  ffmpeg -y -loglevel error -f lavfi -i testsrc2=duration=3:size=320x240:rate=10 \
    -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -c:a aac -shortest "$SBOX/t.mp4"
  ffmpeg -y -loglevel error -f lavfi -i color=c=red:size=320x240:duration=3:rate=10 \
    -c:v libx264 -pix_fmt yuv420p "$SBOX/static.mp4"
  bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --bogus x >/dev/null 2>&1 && rc=0 || rc=1
  check "未知参数报错退出" "1" "$rc"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --max 2 2>&1)
  check "机械抽帧正常" "yes" "$([[ "$out" == *"extracted=2"* ]] && echo yes)"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --at "1,2" 2>&1)
  check "agent 补帧正常" "yes" "$([[ "$out" == *"mode=agent"* ]] && echo yes)"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/frames" --at "abc,1" 2>&1)
  check "--at 非法时刻拒绝且不中断" "yes" "$([[ "$out" == *"非法时刻"* && "$out" == *"mode=agent"* ]] && echo yes)"
  mkdir -p "$SBOX/f_dedup" "$SBOX/f_nodedup"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/static.mp4" "$SBOX/f_dedup" --max 3 2>&1)
  check "静态源 3 帧去重为 1" "yes" "$([[ "$out" == *"extracted=1"* && "$out" == *"dedup_removed=2"* ]] && echo yes)"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/static.mp4" "$SBOX/f_nodedup" --max 3 --no-dedup 2>&1)
  check "--no-dedup 保留全部" "yes" "$([[ "$out" == *"extracted=3"* ]] && echo yes)"
  out=$(bash "$SKILL/scripts/extract_frames.sh" "$SBOX/t.mp4" "$SBOX/f_dedup" --max 3 2>&1)
  check "运动源不去重（阈值不误杀）" "yes" "$([[ "$out" == *"extracted=3"* ]] && echo yes)"
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
python3 - "$SKILL/scripts" <<'PYT'
import sys, urllib.error
from unittest import mock
sys.path.insert(0, sys.argv[1])
import audience
with mock.patch("urllib.request.urlopen",
                side_effect=urllib.error.HTTPError("u", 412, "blocked", None, None)):
    try:
        audience.http_json("https://x", "", "SESSDATA")
        raise SystemExit("应抛 AudienceError")
    except audience.AudienceError as e:
        assert "412" in str(e) and "风控" in str(e), str(e)
print("OK")
PYT
rc=$?; [[ $rc -eq 0 ]] && { pass=$((pass+1)); echo "  ✓ HTTP 412 包装为 AudienceError（含风控提示）"; } || bad "audience HTTP 异常包装"

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
hint=$(SKILL="$SKILL" python3 <<'PYT'
import os, sys
sys.path.insert(0, os.path.join(os.environ["SKILL"], "scripts"))
from ensure_cookies import MANUAL_HINT
print(MANUAL_HINT.format(platform="p"))
PYT
)
[[ -n "$hint" ]] && ok "MANUAL_HINT 可导入且非空" || bad "MANUAL_HINT 导入失败"
check "MANUAL_HINT 声明无需手写 cookies.json" "yes" "$(python3 -c 'import sys; print("yes" if "无需手写" in sys.argv[1] else "no")' "$hint")"

# install_deps 反短路守卫: 不得用 uvx 探测代替持久安装
grep -q 'uvx --from yt-dlp' "$SKILL/scripts/install_deps.sh" && rc=1 || rc=0
check "install_deps 无 uvx 短路" "0" "$rc"
grep -q 'command -v yt-dlp' "$SKILL/scripts/install_deps.sh" && rc=0 || rc=1
check "install_deps 安装后复核 PATH" "0" "$rc"

echo "== 12. 审计盲区补充: 弹幕解析 / netscape 解析 / SRT 时间戳 / extractor-args / 3.9 兼容守卫 =="
python3 - "$SKILL/scripts" "$SBOX" <<'PYT'
import json, sys
from pathlib import Path
scripts, sbox = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import audience, ensure_cookies
from parallel_transcribe import format_srt_timestamp

# 弹幕峰值/高频（纯离线）
xml = sbox + "/d.xml"
rows = []
for t, txt in [(1.0, "前排"), (2.0, "前排"), (3.0, "哈哈"), (100.0, "高能"), (101.0, "高能"), (101.5, "名场面"), (102.0, "高能")]:
    rows.append(f'<d p="{t},1,25,16777215,0,0,0,0">{txt}</d>')
Path(xml).write_text("<i>" + "".join(rows) + "</i>")
d = audience.parse_danmaku(xml, 200)
assert d["total"] == 7 and d["peaks"], d
assert d["peaks"][0]["t"] == 100 and d["peaks"][0]["count"] == 4, d["peaks"][0]  # 100/101/101.5/102 四条
assert any(x["text"] == "高能" and x["count"] == 3 for x in d["top_repeated"]), d["top_repeated"]
print("parse_danmaku: total/峰值窗口/高频 ✓")

# netscape 解析（域过滤 + wanted 过滤 + 缺关键键报错）
ns = sbox + "/c.txt"
Path(ns).write_text(
    "# Netscape HTTP Cookie File\n"
    ".bilibili.com\tTRUE\t/\tTRUE\t2147483647\tSESSDATA\tok\n"
    ".bilibili.com\tTRUE\t/\tTRUE\t2147483647\tbuvid3\tv3\n"
    ".evil.com\tTRUE\t/\tTRUE\t2147483647\tSESSDATA\tbad\n"
    ".evilbilibili.com\tTRUE\t/\tTRUE\t2147483647\tSESSDATA\tbad2\n"
    "www.bilibili.com\tTRUE\t/\tTRUE\t2147483647\tbuvid4\tv4\n"
    ".bilibili.com\tTRUE\t/\tTRUE\t2147483647\tjunk\tx\n")
e = ensure_cookies.parse_netscape_file("bilibili", Path(ns))
assert e["cookies"] == {"SESSDATA": "ok", "buvid3": "v3", "buvid4": "v4"}, e
Path(sbox + "/bad.txt").write_text(".other.com\tTRUE\t/\tTRUE\t1\tfoo\tbar\n")
try:
    ensure_cookies.parse_netscape_file("bilibili", Path(sbox + "/bad.txt"))
    raise SystemExit("应报缺 SESSDATA")
except ensure_cookies.CookieError:
    pass
print("parse_netscape_file: 域/wanted 过滤 + 缺键报错 ✓")

# SRT 时间戳毫秒进位边界
assert format_srt_timestamp(1.9996) == "00:00:02,000", format_srt_timestamp(1.9996)
assert format_srt_timestamp(3661.5) == "01:01:01,500", format_srt_timestamp(3661.5)
print("format_srt_timestamp: 进位边界 ✓")
PYT
rc=$?; [[ $rc -eq 0 ]] && { pass=$((pass+1)); echo "  ✓ 弹幕/netscape/SRT 解析"; } || bad "解析函数组"

# extractor-args: 源码级断言（逗号四元组）+ 可用时用真实 yt-dlp 解析器验证
src=$(grep -o 'max_comments=[0-9,]*' "$SKILL/scripts/pipeline_prepare.sh" | head -1)
check "extractor-args 为逗号四元组" "max_comments=60,15,5,10" "$src"
YTDLP_PY=""
_y=$(command -v yt-dlp 2>/dev/null || true)
if [[ -n "$_y" ]]; then
  _shebang=$(head -1 "$_y" | sed 's/^#!//')
  [[ -x "$_shebang" ]] && YTDLP_PY=$_shebang
fi
if [[ -n "$YTDLP_PY" ]]; then
  parsed=$("$YTDLP_PY" -c '
from yt_dlp.options import create_parser
opts, _ = create_parser().parse_args(["--extractor-args", "youtube:max_comments=60,15,5,10", "U"])
print(opts.extractor_args["youtube"]["max_comments"])')
  check "yt-dlp 解析器确认四元组" "['60', '15', '5', '10']" "$parsed"
fi

# 3.9 兼容守卫: 四个脚本必须带 future annotations
total=$(ls "$SKILL"/scripts/*.py | wc -l | tr -d ' ')
n=$(grep -l "from __future__ import annotations" "$SKILL"/scripts/*.py | wc -l | tr -d ' ')
check "PEP604 兼容守卫（全部 py）" "$total" "$n"

# ---------- verify: 交付完整性验收（沙箱场景） ----------
PREP="$SKILL/scripts/pipeline_prepare.sh"
VDIR=$(mktemp -d /tmp/vs-verify-XXXX)
mk_archive() { # $1=folder相对路径 → 造一个最小完整归档（meta/summary/evidence）
  mkdir -p "$VDIR/$1/raw" "$VDIR/$1/evidence/frames"
  printf '{"platform":"bilibili","id":"BV1xx","title":"t"}' > "$VDIR/$1/raw/meta.json"
  echo "# s" > "$VDIR/$1/summary.md"
  echo "# e" > "$VDIR/$1/evidence/evidence.md"
}
(
  cd "$VDIR" && bash "$PREP" init >/dev/null
  mk_archive() { mkdir -p "$VDIR/$1/raw" "$VDIR/$1/evidence/frames"
    printf '{"platform":"bilibili","id":"BV1xx","title":"t"}' > "$VDIR/$1/raw/meta.json"
    echo "# s" > "$VDIR/$1/summary.md"; echo "# e" > "$VDIR/$1/evidence/evidence.md"; }
  mk_archive "archive/2026-10/bilibili/BV1xx_t"
  # 场景1: 漏 finish（无 registry.json）→ FAIL 且点名 registry
  out=$(bash "$PREP" verify 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"registry 不存在"* ]] && echo "  ✓ verify FAIL: 无 registry.json（漏 finish）被点名" \
    || { echo "  ✗ verify 未抓到漏 finish"; fail=$((fail+1)); pass=$((pass-1)); }
) ; pass=$((pass+1))
rm -rf "$VDIR"

# verify PASS 场景（复用真实归档布局的最小沙箱）
VDIR2=$(mktemp -d /tmp/vs-verify2-XXXX)
(
  cd "$VDIR2" && bash "$PREP" init >/dev/null
  mkdir -p "archive/2026-10/bilibili/BV1xx_t/raw" "archive/2026-10/bilibili/BV1xx_t/evidence/frames"
  printf '{"platform":"bilibili","id":"BV1xx","title":"t","url":"u","duration":10,"subtitle":{"selected":"ai-zh","source":"manual"}}' > "archive/2026-10/bilibili/BV1xx_t/raw/meta.json"
  printf '# s\n![0:01 画面：测试](evidence/frames/00-00-01.jpg)\n' > "archive/2026-10/bilibili/BV1xx_t/summary.md"
  echo "# e" > "archive/2026-10/bilibili/BV1xx_t/evidence/evidence.md"
  printf 'x' > "archive/2026-10/bilibili/BV1xx_t/evidence/frames/00-00-01.jpg"
  bash "$PREP" finish --folder "archive/2026-10/bilibili/BV1xx_t" >/dev/null
  out=$(bash "$PREP" verify 2>&1); rc=$?
  [[ $rc -eq 0 && "$out" == PASS* ]] && echo "  ✓ verify PASS: 完整归档+帧图+registry" \
    || { echo "  ✗ verify 误报完整归档: $out"; fail=$((fail+1)); pass=$((pass-1)); }
  # 场景3: 帧插图断链 → FAIL
  rm "archive/2026-10/bilibili/BV1xx_t/evidence/frames/00-00-01.jpg"
  out=$(bash "$PREP" verify 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"帧插图断链"* ]] && echo "  ✓ verify FAIL: 帧插图断链被点名" \
    || { echo "  ✗ verify 未抓到断链"; fail=$((fail+1)); pass=$((pass-1)); }
  # 场景4: 行文时间戳 → FAIL
  printf 'x' > "archive/2026-10/bilibili/BV1xx_t/evidence/frames/00-00-01.jpg"
  printf '# s\n正文缀时间戳（0:18–0:25）违规\n' > "archive/2026-10/bilibili/BV1xx_t/summary.md"
  out=$(bash "$PREP" verify 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"行文时间戳"* ]] && echo "  ✓ verify FAIL: 行文时间戳被点名" \
    || { echo "  ✗ verify 未抓到行文时间戳"; fail=$((fail+1)); pass=$((pass-1)); }
) ; pass=$((pass+1))
rm -rf "$VDIR2"

# must_run_finish 注入断言（源码级）
mrf=$(grep -c "must_run_finish" "$SKILL/scripts/pipeline_meta.py")
check "交接 JSON 含 must_run_finish 字段" "1" "$mrf"

# ---------- 多P视频支持 ----------
echo "== 13. multipage_lookup: 多P探测 + collection 三级回填（payload 注入，离线） =="
python3 - "$SBOX" <<'EOF'
import json, sys
from pathlib import Path
sbox = Path(sys.argv[1])
pages = [{"page": i, "part": f"讲座 {i}", "duration": 2800 + i, "cid": 1000 + i} for i in range(1, 21)]
(sbox / "mp_payload_multi.json").write_text(json.dumps(
    {"code": 0, "data": {"bvid": "BV1mpTESTxx", "title": "测试课程", "videos": 20, "pages": pages}}))
(sbox / "mp_payload_single.json").write_text(json.dumps(
    {"code": 0, "data": {"bvid": "BV1mpTESTxx", "title": "单P视频", "videos": 1,
                         "pages": [{"page": 1, "part": "p1", "duration": 100}]}}))
(sbox / "mp_payload_season.json").write_text(json.dumps(
    {"code": 0, "data": {"bvid": "BV1mpTESTxx", "title": "T", "videos": 2,
                         "pages": [{"page": 1}, {"page": 2}],
                         "ugc_season": {"id": 42, "title": "某合集"}}}))
for name, coll in (("mp_d_p2", None), ("mp_d_entry", {"id": "PL9", "title": "入口列表"})):
    (sbox / f"{name}.json").write_text(json.dumps(
        {"platform": "bilibili", "id": "BV1mpTESTxx_p2", "collection": coll}))
EOF
mpget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=d.get(sys.argv[2]);print("" if v is None else v)' "$1" "$2"; }
python3 "$META" multipage_lookup bilibili BV1mpTESTxx_p2 --distilled "$SBOX/mp_d_p2.json" \
  --webpage-url 'https://www.bilibili.com/video/BV1mpTESTxx?p=2' \
  --payload-file "$SBOX/mp_payload_multi.json" > "$SBOX/mp_out.json" 2>/dev/null
check "多P: is_multipage/page_count" "True|20" "$(mpget "$SBOX/mp_out.json" is_multipage)|$(mpget "$SBOX/mp_out.json" page_count)"
check "多P: part/explicit_p" "2|True" "$(mpget "$SBOX/mp_out.json" part)|$(mpget "$SBOX/mp_out.json" explicit_p)"
check "多P: collection=父BV回退" "BV1mpTESTxx|测试课程" \
  "$(python3 -c 'import json;d=json.load(open("'$SBOX'/mp_out.json"))["collection"];print(d["id"]+"|"+d["title"])')"
check "多P: distilled 写回父BV（P0 修复）" "BV1mpTESTxx" \
  "$(python3 -c 'import json;print(json.load(open("'$SBOX'/mp_d_p2.json"))["collection"]["id"])')"
check "多P: course.safe_dir=父BV_主标题" "BV1mpTESTxx_测试课程" \
  "$(python3 -c 'import json;print(json.load(open("'$SBOX'/mp_out.json"))["course"]["safe_dir"])')"
check "多P: 分P清单含 p20" "20" \
  "$(python3 -c 'import json;print(json.load(open("'$SBOX'/mp_out.json"))["pages"][-1]["p"])')"
python3 "$META" multipage_lookup bilibili BV1mpTESTxx --webpage-url 'https://www.bilibili.com/video/BV1mpTESTxx/' \
  --payload-file "$SBOX/mp_payload_single.json" > "$SBOX/mp_out1.json" 2>/dev/null
check "单P: is_multipage=false/course=None" "False|" "$(mpget "$SBOX/mp_out1.json" is_multipage)|$(mpget "$SBOX/mp_out1.json" course)"
python3 "$META" multipage_lookup bilibili BV1mpTESTxx_p1 --distilled "$SBOX/mp_d_entry.json" \
  --payload-file "$SBOX/mp_payload_multi.json" > "$SBOX/mp_out2.json" 2>/dev/null
check "入口 collection 优先不覆盖" "PL9|入口列表" \
  "$(python3 -c 'import json;d=json.load(open("'$SBOX'/mp_out2.json"))["collection"];print(d["id"]+"|"+d["title"])')"
python3 "$META" multipage_lookup bilibili BV1mpTESTxx_p1 \
  --payload-file "$SBOX/mp_payload_season.json" > "$SBOX/mp_out3.json" 2>/dev/null
check "season 优先于父BV回退" "42|某合集" \
  "$(python3 -c 'import json;d=json.load(open("'$SBOX'/mp_out3.json"))["collection"];print(d["id"]+"|"+d["title"])')"
mpout=$(python3 "$META" multipage_lookup generic_ab12cd34 x1 --payload-file "$SBOX/mp_payload_multi.json" 2>/dev/null)
check "未配置平台静默 is_multipage=false" "False" "$(mpget <(echo "$mpout") is_multipage)"
mpout=$(python3 "$META" multipage_lookup bilibili au12345678 --payload-file "$SBOX/mp_payload_multi.json" 2>/dev/null)
check "非 BV id 静默跳过" "False" "$(mpget <(echo "$mpout") is_multipage)"

echo "== 14. finalize 双形态: 多P后缀命名 vs 单P旧命名 =="
python3 - "$SBOX" <<'EOF'
import json, sys
from pathlib import Path
sbox = Path(sys.argv[1])
for p in (1, 2):
    info = {"_type": "video", "id": f"BV1mpTESTxx_p{p}", "title": f"测试课程 p0{p} 讲座 {p}",
            "webpage_url": f"https://www.bilibili.com/video/BV1mpTESTxx?p={p}",
            "duration": 2634, "extractor_key": "BiliBili", "subtitles": {}, "automatic_captions": {}}
    (sbox / f"info_mp{p}.json").write_text(json.dumps(info))
EOF
for p in 1 2; do
  python3 "$META" distill "$SBOX/info_mp$p.json" --out "$SBOX/dist_mp$p.json"
  python3 - "$SBOX/dist_mp$p.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["collection"] = {"id": "BV1mpTESTxx", "title": "测试课程"}
p.write_text(json.dumps(d, ensure_ascii=False))
PY
done
rm -rf "$SBOX/pkgmp"
python3 "$META" finalize "$SBOX/dist_mp1.json" --folder "$SBOX/pkgmp" \
  --video-file "raw/video_01.mp4" --audio-file "raw/audio_01.mp3" \
  --subtitle-lang ai-zh --subtitle-source manual --needs-whisper 0 \
  --has-danmaku 1 --has-comments 1 --frames-max 8 --frames-extracted 8 \
  --part 1 --is-multipage 1 --course-page-count 20 > "$SBOX/handoff_mp1.json"
check "多P handoff: part/is_multipage/summary_file" "1|1|summary_01.md" \
  "$(python3 -c 'import json;h=json.load(open("'$SBOX'/handoff_mp1.json"));print("%s|%s|%s"%(h["part"],h["is_multipage"],h["summary_file"]))')"
check "多P meta 落位 meta_01.json" "yes" "$([[ -f "$SBOX/pkgmp/raw/meta_01.json" ]] && echo yes)"
check "多P meta 无旧名残留"       "no"  "$([[ -f "$SBOX/pkgmp/raw/meta.json" ]] && echo yes || echo no)"
check "多P meta 含 course_page_count" "20" "$(python3 -c 'import json;print(json.load(open("'$SBOX'/pkgmp/raw/meta_01.json"))["course_page_count"])')"
rm -rf "$SBOX/pkgsg"
python3 "$META" finalize "$SBOX/dist_ch.json" --folder "$SBOX/pkgsg" \
  --video-file "raw/video.mp4" --audio-file "" \
  --subtitle-lang none --subtitle-source none --needs-whisper 1 \
  --has-danmaku 0 --has-comments 0 --frames-max 8 --frames-extracted 7 > "$SBOX/handoff_sg.json"
check "单P handoff: part=None/is_multipage=0/summary.md" "None|0|summary.md" \
  "$(python3 -c 'import json;h=json.load(open("'$SBOX'/handoff_sg.json"));print("%s|%s|%s"%(h["part"],h["is_multipage"],h["summary_file"]))')"
check "单P meta 仍落 meta.json" "yes" "$([[ -f "$SBOX/pkgsg/raw/meta.json" ]] && echo yes)"

echo "== 15. finish --part: 多P registry 条目 + summary 门槛 + 多P目录必带 --part =="
PROJ_MP="$SBOX/proj_mp"; mkdir -p "$PROJ_MP/archive"
cp -r "$SBOX/pkgmp" "$PROJ_MP/archive/course"
cd "$PROJ_MP"
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/course" >/dev/null 2>&1 && rc=0 || rc=1
check "多P目录缺 --part 被拒" "1" "$rc"
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/course" --part 1 >/dev/null 2>&1 && rc=0 || rc=1
check "缺 summary_01.md 拒写" "1" "$rc"
echo "# s1" > "archive/course/summary_01.md"
bash "$SKILL/scripts/pipeline_prepare.sh" finish --folder "archive/course" --part 1 \
  --subtitle-source whisper >/dev/null
check "registry 逐P键登记" "yes" "$(python3 -c 'import json;print("yes" if json.load(open("archive/registry.json"))["videos"]["bilibili"]["BV1mpTESTxx_p1"] else "no")')"
check "registry 条目 part/summary_file" "1|summary_01.md" \
  "$(python3 -c 'import json;e=json.load(open("archive/registry.json"))["videos"]["bilibili"]["BV1mpTESTxx_p1"];print("%s|%s"%(e["part"],e["summary_file"]))')"
check "registry 条目 collection=父BV" "BV1mpTESTxx" \
  "$(python3 -c 'import json;print(json.load(open("archive/registry.json"))["videos"]["bilibili"]["BV1mpTESTxx_p1"]["collection"]["id"])')"
check "whisper 终态回写 meta_01.json" "whisper" \
  "$(python3 -c 'import json;print(json.load(open("archive/course/raw/meta_01.json"))["subtitle"]["source"])')"

echo "== 16. verify 双形态: 多P课程目录（部分完成合法 + 逐P产物检查） =="
VDIR_MP=$(mktemp -d /tmp/vs-verifymp-XXXX)
(
  cd "$VDIR_MP" || exit 9
  f=0
  bash "$PREP" init >/dev/null
  F="archive/2026-10/bilibili/BV1mpTESTxx_测试课程"
  mkdir -p "$F/raw" "$F/evidence/frames/p01" "$F/evidence/frames/p02"
  for p in 1 2; do
    python3 "$SKILL/scripts/pipeline_meta.py" finalize "$SBOX/dist_mp$p.json" --folder "$F" \
      --video-file "raw/video_0$p.mp4" --audio-file "" \
      --subtitle-lang ai-zh --subtitle-source manual --needs-whisper 0 \
      --has-danmaku 1 --has-comments 1 --frames-max 8 --frames-extracted 8 \
      --part $p --is-multipage 1 --course-page-count 20 >/dev/null
  done
  printf '# s1\n![0:01 画面：测试](evidence/frames/p01/00-00-01.jpg)\n' > "$F/summary_01.md"
  printf '# s2\n' > "$F/summary_02.md"
  echo "# e1" > "$F/evidence/evidence_01.md"; echo "# e2" > "$F/evidence/evidence_02.md"
  printf 'x' > "$F/evidence/frames/p01/00-00-01.jpg"
  bash "$PREP" finish --folder "$F" --part 1 >/dev/null
  bash "$PREP" finish --folder "$F" --part 2 >/dev/null
  out=$(bash "$PREP" verify --folder "$F" 2>&1); rc=$?
  if [[ $rc -eq 0 && "$out" == *"PASS"* ]]; then echo "  ✓ verify PASS: 双P完整课程目录"
  else echo "  ✗ verify 误报多P目录: $out"; f=$((f+1)); fi
  if [[ "$out" == *"2/20 P 已总结"* ]]; then echo "  ✓ 课程完成度信息行（2/20）"
  else echo "  ✗ 缺完成度信息行: $out"; f=$((f+1)); fi
  rm "$F/summary_02.md"
  out=$(bash "$PREP" verify --folder "$F" 2>&1); rc=$?
  if [[ $rc -ne 0 && "$out" == *"summary_02.md 缺失"* ]]; then echo "  ✓ verify FAIL: 逐P summary 缺失被点名"
  else echo "  ✗ verify 未抓到 summary_02.md 缺失: $out"; f=$((f+1)); fi
  printf '# s2\n' > "$F/summary_02.md"; rm "$F/evidence/frames/p01/00-00-01.jpg"
  out=$(bash "$PREP" verify --folder "$F" 2>&1); rc=$?
  if [[ $rc -ne 0 && "$out" == *"frames/p01/00-00-01.jpg"* ]]; then echo "  ✓ verify FAIL: 多P帧断链（pNN 路径）被点名"
  else echo "  ✗ verify 未抓到 pNN 断链: $out"; f=$((f+1)); fi
  printf 'x' > "$F/evidence/frames/p01/00-00-01.jpg"; echo "stale" > "$F/summary_01.md.stale"
  out=$(bash "$PREP" verify --folder "$F" 2>&1); rc=$?
  if [[ $rc -ne 0 && "$out" == *".stale 残留: summary_01.md.stale"* ]]; then echo "  ✓ verify FAIL: 后缀 .stale 残留被点名"
  else echo "  ✗ verify 未抓到后缀 .stale: $out"; f=$((f+1)); fi
  exit $f
)
vrc=$?
if [[ $vrc -eq 0 ]]; then pass=$((pass+1)); else fail=$((fail+vrc)); echo "  ✗ verify 双形态沙箱共 $vrc 项失败"; fi
rm -rf "$VDIR_MP"

echo "== 17. init gitignore: 多P产物忽略规则模式化 =="
VDIR_GI=$(mktemp -d /tmp/vs-gi-XXXX)
(
  cd "$VDIR_GI" || exit 9
  f=0
  bash "$PREP" init >/dev/null
  grep -q 'archive/\*\*/evidence/danmaku_\*\.xml' .gitignore && echo "  ✓ danmaku_*.xml 忽略规则" \
    || { echo "  ✗ 缺 danmaku_* 忽略规则"; f=$((f+1)); }
  grep -q 'archive/\*\*/raw/video_\*' .gitignore && echo "  ✓ video_* 忽略规则" \
    || { echo "  ✗ 缺 video_* 忽略规则"; f=$((f+1)); }
  g1=$(md5 -q .gitignore); bash "$PREP" init >/dev/null; g2=$(md5 -q .gitignore)
  if [[ "$g1" == "$g2" ]]; then echo "  ✓ init 幂等（新模式追加后重复 init 不变）"
  else echo "  ✗ init 不幂等"; f=$((f+1)); fi
  exit $f
)
grc=$?
if [[ $grc -eq 0 ]]; then pass=$((pass+1)); else fail=$((fail+grc)); echo "  ✗ gitignore 沙箱共 $grc 项失败"; fi
rm -rf "$VDIR_GI"

echo ""
echo "===== 结果: pass=$pass fail=$fail ====="
[[ $fail -eq 0 ]]
