/* web-image · 工作台交互: 等比预览 / 单张导出 / 批量导出 / 复制到剪贴板 / 出图模式 */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const q = new URLSearchParams(location.search);

  const toast = (msg, ms = 2200) => {
    let t = $('.wi-toast');
    if (!t) { t = document.createElement('div'); t.className = 'wi-toast'; document.body.appendChild(t); }
    t.textContent = msg; t.dataset.show = '1';
    clearTimeout(t._t); t._t = setTimeout(() => (t.dataset.show = '0'), ms);
  };

  const cards = () => $$('.wi-card');
  const boardOf = (card) => $('.board', card);
  const sizeOf = (card) => ({ w: +card.dataset.w, h: +card.dataset.h });
  const slug = (card) => (card.dataset.file || card.id || 'image').replace(/[^\w一-龥-]+/g, '-');

  /* ---------- 预览缩放: 画板保持真实像素, 用 transform 缩到可视宽度 ---------- */
  let zoom = 0;                       // 0 = 自适应
  function layout() {
    const avail = Math.min(window.innerWidth - 56, 1100);
    cards().forEach((card) => {
      const { w, h } = sizeOf(card);
      const frame = $('.wi-frame', card);
      const board = boardOf(card);
      const s = zoom || Math.min(1, avail / w);
      board.style.transform = `scale(${s})`;
      frame.style.width = Math.round(w * s) + 'px';
      frame.style.height = Math.round(h * s) + 'px';
      const pct = $('.wi-zoom', card);
      if (pct) pct.textContent = Math.round(s * 100) + '%';
    });
  }

  /* ---------- 导出 ---------- */
  async function exportCard(card, scale, action) {
    const board = boardOf(card);
    const { w, h } = sizeOf(card);
    const warn = WebImage.preflight(board);
    if (warn.length) toast('⚠ ' + warn[0], 5000);
    const prev = board.style.transform;
    board.style.transform = 'none';                 // 快照前回到 1:1
    try {
      const blob = await WebImage.toBlob(board, { width: w, height: h, scale });
      if (!blob) throw new Error('canvas 编码失败');
      if (action === 'copy') {
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
        toast('已复制到剪贴板 · ' + w * scale + '×' + h * scale);
      } else {
        WebImage.saveBlob(blob, `${slug(card)}@${scale}x.png`);
        toast('已导出 ' + slug(card) + ' · ' + w * scale + '×' + h * scale);
      }
    } catch (e) {
      toast('导出失败: ' + e.message, 6000);
      console.error(e);
    } finally {
      board.style.transform = prev;
    }
  }

  async function exportAll(scale) {
    const list = cards();
    for (let i = 0; i < list.length; i++) {
      toast(`导出中 ${i + 1}/${list.length}…`, 1200);
      await exportCard(list[i], scale, 'save');
      await new Promise((r) => setTimeout(r, 260));   // 给浏览器下载队列留空隙
    }
    toast('全部导出完成 · 共 ' + list.length + ' 张');
  }

  /* ---------- 每张卡片的操作条 ---------- */
  function decorate() {
    cards().forEach((card) => {
      const { w, h } = sizeOf(card);
      // 画板永远是真实像素, 预览时只靠 transform 缩放, 绝不改它的布局尺寸
      const board = boardOf(card);
      board.style.width = w + 'px';
      board.style.height = h + 'px';
      const head = $('.wi-head', card);
      if (head && !$('.wi-spec', head)) {
        const spec = document.createElement('span');
        spec.className = 'wi-spec';
        spec.textContent = `${w}×${h} · ${ratio(w, h)}`;
        head.insertBefore(spec, head.querySelector('.wi-use'));
      }
      if (head && !$('.wi-acts', head)) {
        const acts = document.createElement('span');
        acts.className = 'wi-acts';
        acts.innerHTML =
          '<button class="wi-btn" data-act="save" data-scale="2">导出 2x</button>' +
          '<button class="wi-btn" data-act="save" data-scale="1">1x</button>' +
          '<button class="wi-btn" data-act="copy" data-scale="2">复制</button>';
        head.appendChild(acts);
      }
    });
  }

  function ratio(w, h) {
    const g = (a, b) => (b ? g(b, a % b) : a);
    const d = g(w, h);
    let rw = w / d, rh = h / d;
    if (rw > 24 || rh > 24) { const k = rw / rh; return k.toFixed(2) + ':1'; }
    return rw + ':' + rh;
  }

  document.addEventListener('click', (e) => {
    const btn = e.target.closest('button');
    if (!btn) return;
    const card = btn.closest('.wi-card');
    if (card && btn.dataset.act) return void exportCard(card, +btn.dataset.scale, btn.dataset.act);
    switch (btn.dataset.all) {
      case '2': case '1': return void exportAll(+btn.dataset.all);
      case 'grid':
        document.body.dataset.grid = document.body.dataset.grid === '1' ? '0' : '1';
        btn.dataset.on = document.body.dataset.grid; return;
      case 'zoom':
        zoom = zoom === 0 ? 1 : zoom === 1 ? .5 : 0;
        btn.textContent = zoom === 0 ? '缩放: 自适应' : '缩放: ' + zoom * 100 + '%';
        layout(); return;
    }
  });

  /* ---------- Chrome headless 出图模式 ?shot=<id> ---------- */
  function shotMode(id) {
    const card = document.getElementById(id) || cards()[+id];
    if (!card) { document.title = 'WI_ERR_NO_BOARD'; return; }
    document.body.dataset.shot = '1';
    cards().forEach((c) => { if (c !== card) c.hidden = true; });
    const { w, h } = sizeOf(card);
    const frame = $('.wi-frame', card);
    frame.style.width = w + 'px'; frame.style.height = h + 'px';
    boardOf(card).style.transform = 'none';
    document.documentElement.style.width = w + 'px';
    document.documentElement.style.height = h + 'px';
    document.title = 'WI_READY';
  }

  function boot() {
    decorate();
    const shot = q.get('shot');
    if (shot !== null) return shotMode(shot);
    layout();
    window.addEventListener('resize', layout);
    // 字体加载完再量一次, 避免首屏尺寸抖动
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(layout);
    const n = cards().length;
    const info = $('.wi-note');
    if (info) info.textContent = `${n} 张画板 · 导出为真实像素 PNG`;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
