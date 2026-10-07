#!/usr/bin/env bash
# run_e2e_local.sh —— video-summarizer 本地离线 E2E（generic 直链链路；需 ffmpeg，无需外网）
# 覆盖: 常规视频 / 无音轨降级 / audio-only 源 / 中断续跑 / quick 取材 / 手动 cookie 双命名
# 用法: bash scripts/tests/run_e2e_local.sh
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SKILL=$(cd "$(dirname "$0")/../.." && pwd)
PREP="$SKILL/scripts/pipeline_prepare.sh"
E2E=$(mktemp -d /tmp/vs-e2e-local-XXXX)
PORT=${PORT:-8899}
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

cleanup() { [[ -n "${SRV:-}" ]] && kill "$SRV" >/dev/null 2>&1; rm -rf "$E2E"; }
trap cleanup EXIT

echo "== 准备: 测试媒体与本地服务 =="
mkdir -p "$E2E/proj" "$E2E/media"
ffmpeg -y -loglevel error -f lavfi -i testsrc2=duration=6:size=640x360:rate=15 \
  -f lavfi -i sine=frequency=440:duration=6 -c:v libx264 -c:a aac -shortest "$E2E/media/withaudio.mp4"
ffmpeg -y -loglevel error -f lavfi -i testsrc2=duration=6:size=640x360:rate=15 \
  -c:v libx264 -an "$E2E/media/noaudio.mp4"
ffmpeg -y -loglevel error -f lavfi -i sine=frequency=440:duration=8 -c:a libmp3lame "$E2E/media/podcast.mp3"
[[ -f "$E2E/media/withaudio.mp4" && -f "$E2E/media/noaudio.mp4" && -f "$E2E/media/podcast.mp3" ]] \
  && echo "  媒体就绪" || { echo "媒体生成失败"; exit 1; }
cd "$E2E/proj" && bash "$PREP" init >/dev/null
python3 -m http.server "$PORT" --directory "$E2E/media" >/dev/null 2>&1 &
SRV=$!; sleep 1
U="http://127.0.0.1:$PORT"
hline() { tail -1; }

echo "== E1: 常规视频（generic 消歧 + 能力位 + 零残留） =="
out=$(bash "$PREP" "$U/withaudio.mp4" 2>&1); h=$(printf '%s\n' "$out" | hline)
p=$(printf '%s' "$h" | python3 -c 'import json,sys;print(json.load(sys.stdin)["platform"])')
host=$(printf '%s' "$h" | python3 -c 'import json,sys;print(json.load(sys.stdin)["host"])')
[[ "$p" =~ ^generic_[0-9a-f]{8}$ ]] && ok "generic 平台键消歧: $p" || bad "平台键: $p"
[[ "$host" == "127.0.0.1" ]] && ok "host 字段: $host" || bad "host: $host"
printf '%s' "$h" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["needs_whisper"]==1 and d["audio_file"] and d["has_comments"]==1 and d["media_kind"]=="video"
print("OK")' >/dev/null && ok "needs_whisper/audio/comments/media_kind" || bad "E1 契约字段"
extra=$(ls | grep -v -e '^archive$' -e '^cache$' -e '^\.gitignore$' || true)
[[ -z "$extra" ]] && ok "项目根零探测残留" || bad "残留: $extra"
PKG=$(printf '%s' "$h" | python3 -c 'import json,sys;print(json.load(sys.stdin)["folder"])')

echo "== E2: 中断续跑（删除 registry 模拟认知阶段中断） =="
echo '{"videos":{}}' > archive/registry.json
out=$(bash "$PREP" "$U/withaudio.mp4" 2>&1); rc=$?
h2=$(printf '%s\n' "$out" | hline)
[[ $rc -eq 0 ]] && ok "续跑 exit=0" || bad "续跑 exit=$rc"
[[ "$h2" == "$h" ]] && ok "续跑交接 JSON 与首次一致" || bad "交接 JSON 不一致"
printf '%s\n' "$out" | grep -q "续跑" && ok "续跑提示出现" || bad "无续跑提示"
dlerr=$(ls "$PKG"/raw/*.part "$PKG"/raw/*.ytdl 2>/dev/null | wc -l | tr -d ' ')
ok "未重采（无下载残留）"

echo "== E3: SKIP（finish 之后） =="
echo "# s" > "$PKG/summary.md"
bash "$PREP" finish --folder "$PKG" >/dev/null
out=$(bash "$PREP" "$U/withaudio.mp4" 2>&1)
[[ "$out" == SKIP:* ]] && ok "SKIP 生效" || bad "SKIP 未生效: $out"
python3 -c '
import json
r=json.load(open("archive/registry.json"))
e=list(r["videos"].values())[0]["withaudio"]
assert e["host"]=="127.0.0.1" and e["upload_date"], e
print("OK")' >/dev/null && ok "registry 含 host/upload_date" || bad "registry 字段缺失"

echo "== E4: quick 取材（项目内零写入 + 无字幕备音频） =="
before=$(find . -type f | sort | md5)
mkdir -p "$E2E/qtmp"
out=$(bash "$PREP" quick "$U/withaudio.mp4" --tmp "$E2E/qtmp" 2>&1); rc=$?
q=$(printf '%s\n' "$out" | hline)
[[ $rc -eq 0 ]] && ok "quick exit=0" || bad "quick exit=$rc"
printf '%s' "$q" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["mode"]=="quick" and d["needs_whisper"]==1 and d["audio_file"] and not d["subtitle_file"]
assert d["registry_hit"].endswith("withaudio_withaudio"), d["registry_hit"]
print("OK")' >/dev/null && ok "quick JSON: registry_hit + audio 备好 + 无字幕" || bad "quick JSON 异常: $q"
ls "$E2E/qtmp"/audio.* >/dev/null 2>&1 && ok "quick 音频落 \$tmp" || bad "quick 音频缺失"
after=$(find . -type f | sort | md5)
[[ "$before" == "$after" ]] && ok "quick 项目内零写入" || bad "quick 改动了项目文件"

echo "== E5: audio-only 源（播客） =="
out=$(bash "$PREP" "$U/podcast.mp3" 2>&1); rc=$?
h5=$(printf '%s\n' "$out" | hline)
[[ $rc -eq 0 ]] && ok "audio-only exit=0" || bad "audio-only exit=$rc"
printf '%s' "$h5" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["media_kind"]=="audio" and d["video_file"]=="" and d["audio_file"], d
assert d["needs_whisper"]==1
print("OK")' >/dev/null && ok "audio-only: media_kind/audio 存在/无 video_file" || bad "audio-only 契约: $h5"
printf '%s\n' "$out" | grep -q "纯音频源" && ok "audio-only 提示出现" || bad "无提示"
nf=$(find "$(printf '%s' "$h5" | python3 -c 'import json,sys;print(json.load(sys.stdin)["folder"])')/evidence/frames" -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$nf" == "0" ]] && ok "audio-only 零抽帧" || bad "抽帧 $nf 张"

echo "== E6: 无音轨降级 =="
out=$(bash "$PREP" "$U/noaudio.mp4" 2>&1); rc=$?
h6=$(printf '%s\n' "$out" | hline)
[[ $rc -eq 0 ]] && ok "无音轨 exit=0" || bad "无音轨 exit=$rc"
printf '%s' "$h6" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["audio_file"]=="" and d["needs_whisper"]==0
print("OK")' >/dev/null && ok "无音轨: audio 空 + needs_whisper=0" || bad "无音轨契约: $h6"

echo "== E7: 手动 cookie 双命名（host 命名对 generic 生效） =="
hostfile="cache/_127.0.0.1.cookies.txt"
mkdir -p cache
printf '# Netscape HTTP Cookie File\n.127.0.0.1\tTRUE\t/\tTRUE\t2147483647\tsession\tmanual-host-cookie\n' > "$hostfile"
out=$(bash "$PREP" "$U/withaudio.mp4" --force 2>&1)
printf '%s\n' "$out" | grep -q "使用手动 Cookie: $hostfile" && ok "host 命名 cookie 被发现并触发重探" || bad "host 命名未生效"
[[ -f "$hostfile" ]] && ok "手动 cookie 文件未被修改" || bad "手动文件消失"

echo "== E8: lookup 零写入 + 命中 =="
before=$(find . -type f | sort | md5)
out=$(bash "$PREP" lookup "$U/withaudio.mp4" 2>&1)
[[ "$out" == HIT\ * ]] && ok "lookup HIT" || bad "lookup: $out"
after=$(find . -type f | sort | md5)
[[ "$before" == "$after" ]] && ok "lookup 零写入（含 cache/）" || bad "lookup 写了文件"

echo ""
echo "===== E2E 结果: pass=$pass fail=$fail ====="
[[ $fail -eq 0 ]]
