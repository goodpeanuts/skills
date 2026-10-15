/* web-image · 零依赖导出引擎
 * 原理: 克隆节点 -> 内联全部 computed style -> 塞进 SVG <foreignObject> -> 画到 canvas -> PNG
 * 因此: 不能有跨域图片 / 未内嵌的 webfont / backdrop-filter。详见 references/export.md
 */
(() => {
  'use strict';

  // ---------- 默认样式表(按标签名缓存), 用于只写“与默认值不同”的属性, 让 SVG 体积可控 ----------
  const defCache = new Map();
  let sandbox = null;
  function sandboxDoc() {
    if (!sandbox) {
      sandbox = document.createElement('iframe');
      sandbox.style.cssText = 'position:fixed;width:0;height:0;border:0;opacity:0;pointer-events:none';
      document.body.appendChild(sandbox);
      sandbox.contentDocument.write('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
      sandbox.contentDocument.close();
    }
    return sandbox.contentDocument;
  }
  function defaultsFor(tag) {
    if (defCache.has(tag)) return defCache.get(tag);
    const doc = sandboxDoc();
    const el = doc.createElement(tag);
    doc.body.appendChild(el);
    const cs = doc.defaultView.getComputedStyle(el);
    const map = Object.create(null);
    for (let i = 0; i < cs.length; i++) map[cs[i]] = cs.getPropertyValue(cs[i]);
    el.remove();
    defCache.set(tag, map);
    return map;
  }

  const SKIP = new Set(['SCRIPT', 'NOSCRIPT', 'TEMPLATE', 'LINK', 'META']);
  let pseudoCss = '';
  let uid = 0;

  function inlineStyle(src, dst) {
    const cs = getComputedStyle(src);
    const def = defaultsFor(src.tagName.toLowerCase());
    let css = '';
    for (let i = 0; i < cs.length; i++) {
      const p = cs[i];
      const v = cs.getPropertyValue(p);
      if (!v) continue;
      if (def[p] === v) continue;
      css += p + ':' + v + ';';
    }
    // 根节点由调用方定位, 去掉可能的外边距/变换
    if (css) dst.setAttribute('style', css);

    for (const pe of ['::before', '::after']) {
      const ps = getComputedStyle(src, pe);
      const content = ps.getPropertyValue('content');
      if (!content || content === 'none' || content === 'normal') continue;
      const cls = 'wi' + uid++;
      dst.classList.add(cls);
      let pcss = '';
      for (let i = 0; i < ps.length; i++) {
        const p = ps[i];
        pcss += p + ':' + ps.getPropertyValue(p) + ';';
      }
      pseudoCss += '.' + cls + pe + '{' + pcss + 'content:' + content + ';}';
    }
  }

  function cloneDeep(src) {
    if (src.nodeType === Node.TEXT_NODE) return src.cloneNode(false);
    if (src.nodeType !== Node.ELEMENT_NODE) return null;
    if (SKIP.has(src.tagName)) return null;
    if (src.dataset && src.dataset.exportIgnore !== undefined) return null;

    // canvas -> img(dataURL), 保证图表类内容能被截取
    if (src.tagName === 'CANVAS') {
      const img = document.createElement('img');
      try { img.src = src.toDataURL(); } catch (e) { /* tainted, 放弃 */ }
      img.width = src.width; img.height = src.height;
      inlineStyle(src, img);
      return img;
    }

    const dst = src.cloneNode(false);
    if (src.tagName === 'IMG' && dst.src && !/^data:/.test(dst.getAttribute('src') || '')) {
      dst.setAttribute('data-wi-external', '1'); // 由 preflight 提前告警
    }
    if (/^(INPUT|TEXTAREA)$/.test(src.tagName)) dst.setAttribute('value', src.value);

    inlineStyle(src, dst);

    // 滚动位置无法在静态快照里还原, 直接展平
    const kids = src.childNodes;
    for (let i = 0; i < kids.length; i++) {
      const c = cloneDeep(kids[i]);
      if (c) dst.appendChild(c);
    }
    return dst;
  }

  function escapeXml(s) {
    return s.replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]));
  }

  function buildSvg(node, w, h) {
    pseudoCss = ''; uid = 0;
    const clone = cloneDeep(node);
    clone.style.margin = '0';
    clone.style.transform = 'none';
    clone.style.width = w + 'px';
    clone.style.height = h + 'px';
    clone.setAttribute('xmlns', 'http://www.w3.org/1999/xhtml');

    const fontStyle = document.getElementById('export-fonts');
    const fontCss = fontStyle ? fontStyle.textContent : '';

    const body = new XMLSerializer().serializeToString(clone);
    const css = fontCss + pseudoCss;
    const style = css ? '<style>' + escapeXml(css) + '</style>' : '';
    return '<svg xmlns="http://www.w3.org/2000/svg" width="' + w + '" height="' + h +
      '" viewBox="0 0 ' + w + ' ' + h + '">' + style +
      '<foreignObject x="0" y="0" width="' + w + '" height="' + h + '">' + body +
      '</foreignObject></svg>';
  }

  async function toCanvas(node, opts) {
    const w = opts.width, h = opts.height, scale = opts.scale || 2;
    const svg = buildSvg(node, w, h);
    const url = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    const img = new Image();
    img.decoding = 'sync';
    img.src = url;
    await img.decode().catch(() => new Promise((res, rej) => {
      img.onload = res; img.onerror = () => rej(new Error('SVG 渲染失败: 多半是跨域图片或未内嵌的字体'));
    }));
    const c = document.createElement('canvas');
    c.width = Math.round(w * scale);
    c.height = Math.round(h * scale);
    const ctx = c.getContext('2d');
    ctx.imageSmoothingQuality = 'high';
    if (opts.background) { ctx.fillStyle = opts.background; ctx.fillRect(0, 0, c.width, c.height); }
    ctx.drawImage(img, 0, 0, c.width, c.height);
    return c;
  }

  async function toBlob(node, opts) {
    const c = await toCanvas(node, opts);
    return new Promise((res) => c.toBlob(res, opts.type || 'image/png', opts.quality || 0.95));
  }

  function saveBlob(blob, filename) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
  }

  // 导出前体检: 把注定失败的东西提前指出来
  function preflight(node) {
    const bad = [];
    node.querySelectorAll('img').forEach((im) => {
      const src = im.getAttribute('src') || '';
      if (src && !/^data:/.test(src)) bad.push('外链图片 ' + src.slice(0, 60) + '(需转成 data URI)');
    });
    const usedFonts = new Set();
    node.querySelectorAll('*').forEach((el) => {
      const cs = getComputedStyle(el);
      if (cs.backdropFilter && cs.backdropFilter !== 'none') bad.push('backdrop-filter 不会被渲染(改用半透明背景+blur伪层)');
      usedFonts.add(cs.fontFamily);
    });
    if (!document.getElementById('export-fonts')) {
      document.querySelectorAll('link[rel="stylesheet"][href*="font"]').forEach(() => {
        bad.push('外链 webfont 不会生效, 请用系统字体栈或把字体 base64 内嵌到 <style id="export-fonts">');
      });
    }
    return [...new Set(bad)];
  }

  window.WebImage = { toCanvas, toBlob, saveBlob, preflight, buildSvg };
})();
