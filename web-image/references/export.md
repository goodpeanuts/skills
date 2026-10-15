# 导出机制与排错

## 两条通道

| | 页内按钮（默认） | `scripts/shot.mjs` |
|---|---|---|
| 原理 | 克隆节点 → 内联 computed style → SVG `<foreignObject>` → canvas → PNG | 本机 Chrome headless 真实渲染后截图 |
| 依赖 | 无，纯浏览器 | 本机装了 Chrome/Chromium/Edge |
| 速度 | 单张即时 | 约 1.5s/张，默认 3 个并发 |
| 保真 | 99% 场景一致，少数 CSS 特性失真 | 所见即所得 |
| 适合 | 边调边看、随手导一张、复制到剪贴板 | 出最终稿、批量、CI、用了 webfont/外链图 |

两条通道读的是**同一份 HTML**，画板不用改。

```bash
node $SKILL/scripts/shot.mjs out/index.html --scale 2
node $SKILL/scripts/shot.mjs out/index.html --only xhs-cover --scale 3
node $SKILL/scripts/shot.mjs out/index.html --out ./png --jobs 4
```

## 拼版

出完图要拼成一张总览（作品集、系列合集、风格对比）：
```bash
node $SKILL/scripts/contact.mjs out/png/*.png --cols 5 --label
```
justified 打包，各列高度完全相等，底部不留空洞。选项：`--cols` `--width` `--gap` `--bg` `--out` `--label`。

## 页内导出的硬限制

设计时避开这些，页内导出就不会出问题：

| 不支持 | 替代做法 |
|---|---|
| 外链图片（http/https） | 转成 data URI（见下方「把本地图片嵌进画板」），或改用 CSS 渐变/内联 SVG |
| 外链 webfont（Google Fonts / `<link>`） | 用系统字体栈；或把字体 base64 放进 `<style id="export-fonts">` 的 `@font-face` |
| `backdrop-filter` | 用半透明底色 + 一层单独的模糊装饰元素 |
| iframe / video / 外部 SVG 文件 | 内联 `<svg>` 元素本身 |
| 滚动容器的隐藏部分 | 画板里不要出现滚动，内容超了就减内容 |

支持得很好的：CSS 渐变、`filter`、`mix-blend-mode`、`clip-path`、`mask`、伪元素 `::before/::after`、内联 SVG、emoji、`transform`、阴影、`data:` URI 图片、`<canvas>`（自动转成图）。

导出前引擎会自动做一次体检，发现外链图片或外链字体会在页面上弹提示。

## 把本地图片嵌进画板

封面里放作品缩略图、产品图、案例截图时，图片必须内嵌成 data URI。三步：

```bash
# 1. 统一按【高度】缩放 —— 别用 -Z，它限制的是最长边，横图的高度会不够，2x 导出就糊了
sips -s format jpeg -s formatOptions 82 --resampleHeight 400 in.png --out t.jpg

# 2. 转 base64（macOS）
base64 -i t.jpg | tr -d '\n'
```
3. 写成 `<img src="data:image/jpeg;base64,……">`。

**尺寸**：缩略图的像素高度要 ≥ 显示高度 × 2（导出 2x 时才不糊）。
**格式**：照片和渐变用 JPEG（体积约为 PNG 的 1/5）；纯色块、线稿、半调网点用 PNG——
JPEG 会在这类高频细节上产生噪点。
**体积**：base64 比原文件大约 34%。十来张缩略图控制在 300KB 以内，页面照样秒开。

### 一排缩略图铺满宽度

统一高度、宽度按各自画幅比例，正好填满一行——同时也直观展示了「支持多种画幅」：

```
H = (可用宽 - 间距总和) / Σ(w_i / h_i)
```

CSS 只需要 `display:flex; gap:14px` + `img{height:H;width:auto}`，宽度会自动正确。
浅色图在白底上会糊边，加 `outline:1px solid rgba(0,0,0,.09); outline-offset:-1px`
（用 outline 不用 border，不影响布局计算）。

## 排错

| 现象 | 原因 | 解法 |
|---|---|---|
| 导出的图是空白/透明 | 画板里有跨域图片污染了 canvas | 把图片转 data URI；或用 `shot.mjs` |
| 字体变成了默认黑体 | 用了外链 webfont | 换系统字体栈，或内嵌 base64，或用 `shot.mjs` |
| 布局跟预览不一样 | 快照时画板尺寸没定好 | 确认 `.wi-card` 上有 `data-w`/`data-h`，并且没有手改 `.board` 的 width/height |
| 图片底部一截空白 | 内容高度小于画板高度且背景色在子元素上 | 背景色写在 `.board` 上，或给内容 `height:100%` |
| 玻璃/毛玻璃效果丢失 | `backdrop-filter` 不被渲染 | 见上表 |
| `shot.mjs` 报找不到 Chrome | 非默认安装路径 | `CHROME_PATH=/path/to/chrome node shot.mjs ...` |
| `shot.mjs` 某张超时 | 画板里有无限动画或超大资源 | 去掉动画（静态图不需要），或减小画板 |
| **改了 HTML 但出图没变** | 脚本靠"产物文件大小稳定"判完成，旧文件还在就会立刻命中 | 已在脚本里修复（每次出图前先删旧产物）。若自建流程要注意这一点 |
| 复制到剪贴板没反应 | 浏览器要求安全上下文 | 用 `file://` 或 `http://localhost` 打开；改用「导出」按钮下载 |

## 工作台里的开关

- **缩放**：自适应 / 100% / 50%。看细节切 100%，看信息流效果切 50% 再眯眼。
- **构图网格**：叠加 12 栏 + 40px 基线，检查对齐用。**只是预览层，不会被导出。**
- **导出 2x / 1x**：屏幕用图选 2x，打印稿画板本身已是 300dpi 像素故选 1x。
- **复制**：直接进系统剪贴板，可以粘进微信/飞书/Figma。

## 画板契约

`shot.mjs` 和工作台都靠这几个属性识别画板，不要改：

```html
<section class="wi-card" id="唯一id" data-w="1200" data-h="630" data-file="导出文件名">
  <div class="wi-head">
    <span class="wi-name">画板名</span>
    <span class="wi-use">用于: 说明这张图发到哪</span>
  </div>
  <div class="wi-frame">
    <div class="board 主题类名">…画面…</div>
  </div>
</section>
```

- `data-w` / `data-h`：**真实导出像素**，必填。
- `.board` 的宽高由脚本按 `data-w/h` 设置，**不要在 CSS 里给 `.board` 写 width/height**。
- 预览缩放靠 `transform: scale()`，不影响内部布局计算。
