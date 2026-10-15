#!/usr/bin/env node
/**
 * web-image · 拼版/画廊出图
 *
 * 把一组图片拼成一张排满的总览图。用 justified 算法让**每一列高度完全相等**，
 * 底部齐平没有空洞——CSS 的 column-count 做不到这一点，它的列平衡算法会在底部留下大块空白。
 *
 * 原理: ① 按高度降序贪心塞进当前最矮的列 → 各列高度已经接近
 *       ② 反解列宽 W_i 使所有列等高: 列高 T = A_i·W_i + G_i, 约束 ΣW_i = 可用宽
 *          ⇒ T = (AVAIL + Σ(G_i/A_i)) / Σ(1/A_i),  W_i = (T - G_i)/A_i
 *       列宽差异通常只有几个百分点, 肉眼看不出, 但底部会严丝合缝。
 *
 * 用法:
 *   node contact.mjs <图片...> [--cols 5] [--width 2400] [--gap 6] [--out sheet.png] [--label]
 *   node contact.mjs png/*.png --cols 6 --label
 */
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdtempSync, statSync, openSync, closeSync, unlinkSync } from 'node:fs';
import { resolve, dirname, join, basename, extname } from 'node:path';
import { tmpdir } from 'node:os';

const CHROME = [
  process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
].filter(Boolean).find((p) => existsSync(p));
if (!CHROME) { console.error('找不到 Chrome。设置 CHROME_PATH。'); process.exit(1); }

const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf('--' + n); return i === -1 ? d : argv[i + 1]; };
const has = (n) => argv.includes('--' + n);

// 带值的选项, 它们后面那个参数不是输入文件 —— 否则 `--out sheet.png` 会被当成一张待拼的图
const VALUED = ['cols', 'width', 'gap', 'bg', 'out'];
const taken = new Set();
for (const n of VALUED) { const i = argv.indexOf('--' + n); if (i > -1) taken.add(i + 1); }

const files = argv
  .filter((a, i) => !taken.has(i) && !a.startsWith('--') && /\.(png|jpe?g|webp)$/i.test(a))
  .map((f) => resolve(f));
for (const f of files) if (!existsSync(f)) { console.error('找不到文件: ' + f); process.exit(1); }
if (!files.length) { console.error('用法: node contact.mjs <图片...> [--cols 5] [--width 2400] [--out sheet.png]'); process.exit(1); }

const COLS = Number(flag('cols', 5));
const TOTAL = Number(flag('width', 2400));
const GAP = Number(flag('gap', 6));
const BG = flag('bg', '#141414');
const OUT = resolve(flag('out', join(dirname(files[0]), 'contact.png')));

/* 读图片尺寸: PNG 从 IHDR 取, JPEG 扫 SOF 段 */
function size(f) {
  const b = readFileSync(f);
  if (b[0] === 0x89 && b[1] === 0x50) return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc)
        return { h: b.readUInt16BE(i + 5), w: b.readUInt16BE(i + 7) };
      i += 2 + b.readUInt16BE(i + 2);
    }
  }
  return { w: 1, h: 1 };  // webp 等交给浏览器自己量, 这里按方图近似
}

const items = files.map((f) => { const s = size(f); return { f, ar: s.h / s.w, name: basename(f, extname(f)) }; });
const AVAIL = TOTAL - GAP * (COLS + 1);
const W0 = AVAIL / COLS;

// ① 贪心分列
const cols = Array.from({ length: COLS }, () => ({ h: 0, items: [] }));
[...items].sort((a, b) => b.ar - a.ar).forEach((it) => {
  const c = cols.reduce((m, c) => (c.h < m.h ? c : m));
  c.items.push(it); c.h += it.ar * W0 + GAP;
});

// ② 反解列宽 -> 所有列等高
const A = cols.map((c) => c.items.reduce((s, i) => s + i.ar, 0));
const G = cols.map((c) => (c.items.length - 1) * GAP);
const T = (AVAIL + G.reduce((s, g, i) => s + g / A[i], 0)) / A.reduce((s, a) => s + 1 / a, 0);
const W = A.map((a, i) => (T - G[i]) / a);

const label = has('label');
const html = `<!doctype html><meta charset="utf-8"><style>
body{margin:0;background:${BG};display:flex;gap:${GAP}px;padding:${GAP}px;align-items:flex-start}
.col{display:flex;flex-direction:column;gap:${GAP}px;flex:none}
figure{margin:0;position:relative}img{width:100%;display:block}
figcaption{position:absolute;left:0;bottom:0;background:#000;color:#0f0;padding:2px 6px;
 font:600 13px ui-monospace,monospace}
</style>` + cols.map((c, i) =>
  `<div class="col" style="width:${W[i].toFixed(2)}px">` + c.items.map((it) =>
    `<figure><img src="file://${it.f}">${label ? `<figcaption>${it.name}</figcaption>` : ''}</figure>`
  ).join('') + `</div>`).join('');

try { unlinkSync(OUT); } catch {}   // 同 shot.mjs：不删旧产物会立刻命中"已完成"
const profile = mkdtempSync(join(tmpdir(), 'wi-'));
const page = join(profile, 'sheet.html');
writeFileSync(page, html);
const H = Math.round(T + GAP * 2);

const fd = openSync(join(profile, 'chrome.log'), 'a');
const child = spawn(CHROME, [
  '--headless', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--allow-file-access-from-files', '--disable-background-networking',
  '--disable-component-update', '--no-service-autorun', '--disable-sync', '--metrics-recording-only',
  `--user-data-dir=${profile}`, `--window-size=${TOTAL},${H}`, `--screenshot=${OUT}`, `file://${page}`,
], { stdio: ['ignore', fd, fd] });

// Chrome 常因孙进程不退出, 轮询产物稳定即收工(同 shot.mjs)
let last = -1, stable = 0, waited = 0;
const tick = setInterval(() => {
  waited += 200;
  let s = -1; try { s = statSync(OUT).size; } catch {}
  if (s > 0 && s === last) stable++; else stable = 0;
  last = s;
  if (stable >= 2 || waited > 60000) {
    clearInterval(tick);
    try { child.kill('SIGKILL'); } catch {}
    try { closeSync(fd); } catch {}
    if (s > 0) {
      console.log(`✓ ${files.length} 张 → ${COLS} 列 · ${TOTAL}×${H} · 列高全等 ${T.toFixed(1)}`);
      console.log(`  列宽 ${W.map((w) => w.toFixed(0)).join(' / ')}  →  ${OUT}`);
    } else console.error('✗ 失败，日志:', join(profile, 'chrome.log'));
  }
}, 200);
