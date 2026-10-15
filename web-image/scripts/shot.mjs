#!/usr/bin/env node
/**
 * web-image · 精确出图通道(本机 Chrome headless)
 *
 * 页面里的「导出」按钮走 SVG foreignObject, 少数 CSS 特性会失真(见 references/export.md);
 * 这个脚本让 Chrome 真正渲染再截图, 所见即所得, 适合出最终稿 / 批量出图 / CI。
 *
 * 用法:
 *   node shot.mjs <index.html> [--scale 2] [--out ./png] [--only board-1,board-3] [--jobs 3]
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, mkdtempSync, statSync, openSync, closeSync, unlinkSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
  '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
].filter(Boolean);

const chrome = CHROME_CANDIDATES.find((p) => existsSync(p));
if (!chrome) {
  console.error('找不到 Chrome。设置 CHROME_PATH, 或直接用页面里的「导出」按钮。');
  process.exit(1);
}

const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf('--' + n); return i === -1 ? d : argv[i + 1]; };

const VALUED = ['scale', 'out', 'only', 'jobs'];
const taken = new Set();
for (const n of VALUED) { const i = argv.indexOf('--' + n); if (i > -1) taken.add(i + 1); }
const file = argv.find((a, i) => !taken.has(i) && !a.startsWith('--') && /\.html?$/.test(a));
if (!file) { console.error('用法: node shot.mjs <index.html> [--scale 2] [--out ./png] [--only id1,id2]'); process.exit(1); }

const htmlPath = resolve(file);
const outDir = resolve(flag('out', join(dirname(htmlPath), 'png')));
const scale = Number(flag('scale', 2));
const jobs = Math.max(1, Number(flag('jobs', 3)));
const only = (flag('only', '') || '').split(',').filter(Boolean);
mkdirSync(outDir, { recursive: true });

// 从 HTML 抓出每张画板的 id / 真实尺寸 / 文件名
const html = readFileSync(htmlPath, 'utf8');
const boards = [];
for (const m of html.matchAll(/<section\b([^>]*\bclass="[^"]*\bwi-card\b[^"]*"[^>]*)>/g)) {
  const a = m[1];
  const get = (k) => (a.match(new RegExp(k + '="([^"]*)"')) || [])[1];
  const id = get('id'), w = +get('data-w'), h = +get('data-h');
  if (id && w && h) boards.push({ id, w, h, file: get('data-file') || id });
}
if (!boards.length) {
  console.error('没找到画板。每张图需要: <section class="wi-card" id=".." data-w=".." data-h="..">');
  process.exit(1);
}
const targets = only.length ? boards.filter((b) => only.includes(b.id) || only.includes(b.file)) : boards;

/* Chrome 写完 PNG 后常常因为拉起了 GoogleUpdater 之类的孙进程而迟迟不退出。
   所以不等它退出 —— 轮询产物文件, 大小稳定了就直接收工杀进程。 */
function shoot(b) {
  return new Promise((done) => {
    const out = join(outDir, `${b.file}@${scale}x.png`);
    // 必须先删掉旧产物：下面靠"文件大小稳定"判完成，旧文件在的话会立刻命中，
    // 于是每次微调后拿到的都是上一版的图。
    try { unlinkSync(out); } catch {}
    const profile = mkdtempSync(join(tmpdir(), 'wi-'));
    const fd = openSync(join(profile, 'chrome.log'), 'a');
    const child = spawn(chrome, [
      '--headless', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
      '--no-default-browser-check', '--disable-extensions', '--allow-file-access-from-files',
      '--disable-background-networking', '--disable-component-update', '--no-service-autorun',
      '--disable-sync', '--disable-default-apps', '--metrics-recording-only', '--mute-audio',
      `--user-data-dir=${profile}`,
      `--force-device-scale-factor=${scale}`,
      `--window-size=${b.w},${b.h}`,
      '--default-background-color=00000000',
      `--screenshot=${out}`,
      `file://${htmlPath}?shot=${b.id}`,
    ], { stdio: ['ignore', fd, fd] });

    let last = -1, stable = 0, waited = 0;
    const tick = setInterval(() => {
      waited += 200;
      let size = -1;
      try { size = statSync(out).size; } catch { /* 还没落地 */ }
      if (size > 0 && size === last) stable++; else stable = 0;
      last = size;
      if (stable >= 2 || waited > 30000) finish(size > 0);
    }, 200);

    function finish(okFlag) {
      clearInterval(tick);
      try { child.kill('SIGKILL'); } catch {}
      try { closeSync(fd); } catch {}
      if (okFlag) console.log(`✓ ${b.file}  ${b.w * scale}×${b.h * scale}  →  ${out}`);
      else console.error(`✗ ${b.file} 超时/失败 (日志: ${join(profile, 'chrome.log')})`);
      done(okFlag);
    }
    child.on('error', () => finish(false));
  });
}

const t0 = Date.now();
let ok = 0;
const queue = targets.slice();
await Promise.all(Array.from({ length: Math.min(jobs, queue.length) }, async () => {
  while (queue.length) if (await shoot(queue.shift())) ok++;
}));
console.log(`\n完成 ${ok}/${targets.length} 张 · ${((Date.now() - t0) / 1000).toFixed(1)}s → ${outDir}`);
process.exit(ok === targets.length ? 0 : 1);
