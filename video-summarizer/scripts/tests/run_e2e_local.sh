#!/usr/bin/env bash
# run_e2e_local.sh —— video-summarizer 本地离线 E2E（generic 直链链路；需 ffmpeg，无需外网）
# 覆盖: 常规视频 / 无音轨降级 / audio-only 源 / 中断续跑 / quick 取材 / 手动 cookie 双命名
# 用法: bash scripts/tests/run_e2e_local.sh
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SKILL=$(cd "$(dirname "$0")/../.." && pwd)
PREP="$SKILL/scripts/pipeline_prepare.sh"
E2E=$(mktemp -d /tmp/vs-e2e-local-XXXX)
PORT=${PORT:-$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")}
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
vf=$(printf '%s' "$h" | python3 -c 'import json,sys;print(json.load(sys.stdin)["video_file"])')
[[ -f "$vf" ]] && ok "video_file 原值即项目根相对路径（可直接消费）" || bad "video_file 不可达: $vf"
[[ -f "$p/$vf" ]] && bad "video_file 疑似 folder 内相对路径（会被双重前缀）" || ok "无双重前缀歧义"
PKG=$(printf '%s' "$h" | python3 -c 'import json,sys;print(json.load(sys.stdin)["folder"])')

echo "== E2: 中断续跑（删除 registry 模拟认知阶段中断） =="
echo '{"videos":{}}' > archive/registry.json
mt_before=$(stat -f '%m' "$PKG/raw/video.mp4")
out=$(bash "$PREP" "$U/withaudio.mp4" 2>&1); rc=$?
h2=$(printf '%s\n' "$out" | grep '^{' | tail -1)
[[ $rc -eq 0 ]] && ok "续跑 exit=0" || bad "续跑 exit=$rc"
[[ "$h2" == "$h" ]] && ok "续跑交接 JSON 与首次一致" || bad "交接 JSON 不一致"
printf '%s\n' "$out" | grep -q "续跑" && ok "续跑提示出现" || bad "无续跑提示"
mt_after=$(stat -f '%m' "$PKG/raw/video.mp4")
[[ "$mt_before" == "$mt_after" ]] && ok "未重采（媒体 mtime 未变）" || bad "媒体被重新下载"

CURM=$(date +%Y-%m)
echo "== E2b: 跨月中断续跑（目录挪到 2020-01，registry 仍空） =="
mkdir -p "$(dirname "${PKG/$CURM/2020-01}")"
mv "$PKG" "${PKG/$CURM/2020-01}"
out=$(bash "$PREP" "$U/withaudio.mp4" 2>&1); rc=$?
h2b=$(printf '%s\n' "$out" | grep '^{' | tail -1)
[[ $rc -eq 0 ]] && ok "跨月续跑 exit=0" || bad "跨月续跑 exit=$rc"
python3 - "$h" "$h2b" <<'PYT'
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
a.pop("folder"); b.pop("folder")   # folder 指向 2020-01 属预期差异
assert a == b, (a, b)
assert "/2020-01/" in json.loads(sys.argv[2])["folder"]
print("OK")
PYT
[[ $? -eq 0 ]] && ok "跨月续跑交接 JSON 一致（folder 指向 2020-01）" || bad "跨月交接 JSON 不一致"
PKG="${PKG/$CURM/2020-01}"
n2026=$(find "archive/$CURM" -maxdepth 2 -name 'withaudio_*' 2>/dev/null | wc -l | tr -d ' ')
[[ -f "$PKG/raw/video.mp4" && "$n2026" == "0" ]] && ok "复用 2020-01 原目录（无孤儿）" || bad "跨月孤儿目录"
mv "$PKG" "${PKG/2020-01/$CURM}"; PKG="${PKG/2020-01/$CURM}"

echo "== E4: quick 取材（项目内零写入 + 无字幕备音频） =="
before=$(find . -type f | sort | md5)
mkdir -p "$E2E/qtmp"
out=$(bash "$PREP" quick "$U/withaudio.mp4" --tmp "$E2E/qtmp" 2>&1); rc=$?
q=$(printf '%s\n' "$out" | hline)
[[ $rc -eq 0 ]] && ok "quick exit=0" || bad "quick exit=$rc"
printf '%s' "$q" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["mode"]=="quick" and d["needs_whisper"]==1 and d["audio_file"] and not d["subtitle_file"]
assert d["registry_hit"] == "", d["registry_hit"]  # 此时尚无 finish, 应 MISS
print("OK")' >/dev/null && ok "quick JSON: MISS + audio 备好 + 无字幕" || bad "quick JSON 异常: $q"
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
echo "== E3b: 悬空 SKIP（归档目录被删）自愈 =="
rm -rf "$PKG"
out=$(bash "$PREP" "$U/withaudio.mp4" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "悬空条目自愈 exit=0（重采新目录）" || bad "悬空 exit=$rc"
printf '%s\n' "$out" | grep -q "按未总结重新采集" && ok "悬空告警出现" || bad "无悬空告警"
PKG=$(printf '%s\n' "$out" | grep '^{' | tail -1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["folder"])')
[[ -f "$PKG/summary.md" ]] || echo "# s" > "$PKG/summary.md"   # 自愈重采不含认知产物，补齐以便后续

echo "== E7: 手动 cookie 双命名（host 命名对 generic 生效） =="
hostfile="cache/_127.0.0.1.cookies.txt"
mkdir -p cache
printf '# Netscape HTTP Cookie File\n.127.0.0.1\tTRUE\t/\tTRUE\t2147483647\tsession\tmanual-host-cookie\n' > "$hostfile"
STALE_DIR=$(ls -d archive/*/generic_*/withaudio_withaudio 2>/dev/null | head -1)
echo "# 旧总结" > "$STALE_DIR/summary.md"; echo "# 旧底稿" > "$STALE_DIR/evidence/evidence.md"
out=$(bash "$PREP" "$U/withaudio.mp4" --force 2>&1)
printf '%s\n' "$out" | grep -q "使用手动 Cookie: $hostfile" && ok "host 命名 cookie 被发现并触发重探" || bad "host 命名未生效"
[[ -f "$hostfile" ]] && ok "手动 cookie 文件未被修改" || bad "手动文件消失"
[[ -f "$STALE_DIR/summary.md.stale" && -f "$STALE_DIR/evidence.md.stale" ]] \
  && ok "--force 旧认知产物改名 .stale" || bad "--force 未改名旧产物"
[[ -f "$STALE_DIR/summary.md" ]] && bad "--force 后 summary.md 应不存在（等认知阶段重写）" || ok "--force 后旧 summary 已让位"
# 旧布局混合态：顶层 evidence.md 遗留 + 新位 evidence/evidence.md，--force 须都留痕且不互撞
echo "# 旧布局底稿" > "$STALE_DIR/evidence.md"; echo "# 新位底稿" > "$STALE_DIR/evidence/evidence.md"
bash "$PREP" "$U/withaudio.mp4" --force >/dev/null 2>&1
[[ -f "$STALE_DIR/evidence.md.stale" && ! -f "$STALE_DIR/evidence.md" ]] \
  && ok "--force 旧布局顶层 evidence.md 留痕并清位" || bad "--force 旧布局处理失效: $(ls "$STALE_DIR" | tr '\n' ' ')"
grep -q 'archive/\*\*/\*.stale' .gitignore && ok ".gitignore 托管 .stale" || bad ".stale 未进托管块"
# --force 后认知阶段重写 + finish 复位为已总结态（E8/E9 测 HIT 语义的前提）
echo "# 重写总结" > "$STALE_DIR/summary.md"
bash "$PREP" finish --folder "$STALE_DIR" >/dev/null

echo "== E8: lookup 零写入 + 命中 =="
before=$(find . -type f | sort | md5)
out=$(bash "$PREP" lookup "$U/withaudio.mp4" 2>&1)
[[ "$out" == HIT\ * ]] && ok "lookup HIT" || bad "lookup: $out"
out=$(bash "$PREP" lookup "$U/podcast.mp3" 2>&1)
[[ "$out" == MISS\ * ]] && ok "lookup MISS（podcast 未 finish）" || bad "lookup MISS: $out"
after=$(find . -type f | sort | md5)
[[ "$before" == "$after" ]] && ok "lookup 零写入" || bad "lookup 写了文件"

echo "== E9: quick 缺省 --tmp 与 init 幂等 =="
q=$(bash "$PREP" quick "$U/withaudio.mp4" 2>&1 | grep '^{' | tail -1)
tmpv=$(printf '%s' "$q" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tmp"])')
[[ "$tmpv" == /tmp/* ]] && ok "quick 缺省 tmp 落系统临时目录" || bad "quick tmp: $tmpv"
printf '%s' "$q" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["subtitle_lang"]=="archived" and not d["subtitle_file"] and not d["audio_file"], d
print("OK")' >/dev/null && ok "quick 命中 registry 免取材（零下载）" || bad "quick 命中仍取材: $q"
rm -rf "$tmpv"
g1=$(md5 -q .gitignore); bash "$PREP" init >/dev/null; g2=$(md5 -q .gitignore)
[[ "$g1" == "$g2" ]] && ok "init 幂等（.gitignore 不变）" || bad "init 改动了 .gitignore"

echo "== E10: quick 对悬空 registry 条目按 MISS 取材 =="
PKGDIR=$(ls -d archive/*/generic_*/withaudio_withaudio | head -1)
rm -rf "$PKGDIR"
q=$(bash "$PREP" quick "$U/withaudio.mp4" --tmp "$E2E/qtmp2" 2>&1 | grep '^{' | tail -1)
printf '%s' "$q" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d["registry_hit"] == "" and d["audio_file"], d
print("OK")' >/dev/null && ok "quick 悬空条目按 MISS 取材（备好音频）" || bad "quick 悬空: $q"
rm -rf "$E2E/qtmp2"
out=$(bash "$PREP" lookup "$U/withaudio.mp4" 2>&1)
[[ "$out" == *MISS* ]] && ok "lookup 悬空条目按 MISS 处理" || bad "lookup 悬空: $out"

echo "== E11: 交接 JSON 携带 finish 强制提醒 + verify 闸门 =="
# E11a: 机械阶段交接 JSON 必须含 must_run_finish=true（漏 finish 事故的程序化防线）
# 用 podcast（E8 后仍未 finish）——withaudio 在 E7 已 finish，registry 有旧条目
out=$(bash "$PREP" "$U/podcast.mp3" 2>&1) || true
h11=$(printf '%s\n' "$out" | grep '^{' | tail -1)
printf '%s' "$h11" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert d.get("must_run_finish") is True, d
print("OK")' >/dev/null && ok "交接 JSON 含 must_run_finish=true" || bad "must_run_finish 缺失: $h11"
F11=$(printf '%s' "$h11" | python3 -c 'import json,sys;print(json.load(sys.stdin)["folder"])')
# E11b: 漏 finish 状态下 verify 必须 FAIL 并点名 registry
echo "# s" > "$F11/summary.md"; echo "# e" > "$F11/evidence/evidence.md"
out=$(bash "$PREP" verify --folder "$F11" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"registry"* ]] && ok "verify FAIL: 漏 finish 被点名" || bad "verify 漏检: $out"
# E11c: finish 后 verify 转 PASS（单归档验收; 全仓模式会扫到 E5/E6 故意未完成的归档）
bash "$PREP" finish --folder "$F11" >/dev/null
out=$(bash "$PREP" verify --folder "$F11" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == PASS* ]] && ok "verify PASS: finish 后单归档验收通过" || bad "verify 误报: $out"

echo ""
echo "===== E2E 结果: pass=$pass fail=$fail ====="
[[ $fail -eq 0 ]]
