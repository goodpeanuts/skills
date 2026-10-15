# 视觉系统

生成图片的难点从来不是"排得下"，是"值得被看"。**每张图先选一个方向，然后把它做到底**，不要混搭。

## 一、风格

风格库独立在 **`styles.md`**（32 套，每套带签名手法和可复制 token）。
先在那里选定一套，再回到本文按下面的规则实现。

## 二、字体（导出安全）

页内导出走 SVG，**外链 webfont 不会生效**。默认只用系统字体栈：

```css
--sans:"PingFang SC","Hiragino Sans GB","Microsoft YaHei",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
--serif:"Songti SC","Source Han Serif SC",Georgia,"Times New Roman",serif;
--mono:"SF Mono",ui-monospace,"JetBrains Mono",Menlo,Consolas,monospace;
--round:"PingFang SC","Yuanti SC","Hiragino Maru Gothic ProN",sans-serif;
```

要用特殊字体，二选一：
- 把字体 base64 塞进 `<style id="export-fonts">` 的 `@font-face`（导出引擎会写进 SVG）；
- 或者只用 `scripts/shot.mjs`（Chrome 渲染，webfont 正常）。

## 三、中文排版


- **字距随字号反向变化**：大标题 `-.02em ~ -.05em`，正文 `0`，小号眉标 `.15em~.22em` + 大写。
  字号越大越要收紧，越小越要放开——这是"看起来专业"和"看起来是默认值"的分界线。
- 行高：大标题 `.98~1.1`，正文 `1.6~1.75`。
- 每行 CJK **12~18 字**。**中文标题一律手动 `<br>` 断句**，断在语义处。
- ⚠️ 别用 `max-width:16ch` 控制中文折行：`ch` 是字符 "0" 的宽度，一个汉字约占 2ch，
  算出来的行长会差一倍，很容易把标题折出孤字。中文要限宽就用 `px`，或者干脆手动断行。
- 中文标点占一个全角宽，行首/行尾出现逗号句号时视觉上会空一块——断行时把标点留在上一行末尾。
- 标题末尾不加句号。中英混排时英文单独一行往往更好看。
- 中文不要用斜体，不要用假粗（靠 `font-weight` 而不是 `text-stroke`）。

## 四、构图

- **边距**：短边 × 6%~9%，四边一致；打印稿另加出血。
- **一个焦点**：一张图只有一个"最大的东西"。第二层要小到只有它的 1/3。
- **字号阶梯拉开**：相邻层级至少 1.6 倍，主标题与最小字 **≥ 5 倍**。中庸的字号差是廉价感的头号来源。
- **不对称**：主体压左或压下，别所有东西居中。居中构图只在头像/徽章类用。
- **出血元素**：让一个大字、大圆、粗线**跑出画板**，张力立刻不一样。
- **三段式**：眉标（小、弱） / 主体（大、强） / 落款（小、弱）——分列画板的上、中、下，中间用 `margin:auto` 撑开。
- **留白 ≥ 35%**（极简主题 ≥ 55%）。宁可少说一句。

用工作台顶部的「构图网格」按钮检查对齐。


## 五、高级感技法

"高级"不是形容词，是下面这些具体决定的总和。

**层次**
- 用**明度差 4~8%** 的色块分层，而不是加阴影。深色主题用 `rgba(255,255,255,.04~.08)` 提亮。
- 真要阴影，用三层递进而不是一层大模糊：
  `0 1px 2px rgba(0,0,0,.05), 0 4px 12px rgba(0,0,0,.04), 0 12px 32px rgba(0,0,0,.03)`
- 分隔线用 `rgba` 的 hairline（`1px solid rgba(0,0,0,.08)`），不要用纯灰色值——纯色线在任何底色上都显脏。

**光学对齐**（肉眼对齐 ≠ 数值对齐）
- 圆形、三角形在视觉上比同尺寸方形小，要放大 3~8%。
- 行首的引号、括号、破折号要**negative margin 拉出边界**，否则那一行看起来是缩进的。
- 大字号标题的左边缘，要比正文再往左推 2~4px，因为字形本身带左侧空隙。

**颜色纪律**
- 一张图里强调色**只出现一次**。出现第二次，它就不再是强调色了。
- 低饱和底色 + 一个高饱和重音，比五个中饱和颜色高级。
- 渐变**必须叠一层噪点**（opacity ≥ .3）消除色带，否则在大面积上一定会出现条纹。

**数字与符号**
- 数字用 `font-variant-numeric: tabular-nums`，否则并排的数字不对齐。
- 日期、编号、尺寸这类"元信息"一律用等宽字 + 字距 + 降低透明度，把它们压成背景。

**有机形**
- 不规则形状（墨迹、水渍、云、颗粒边缘）**不要用 `border-radius` + `blur` 硬凑**——那只会得到一个模糊的椭圆。
  用 SVG 的 `feTurbulence` + `feDisplacementMap` 把规整形状的边缘打散，见第六章配方。

**布局**
- **能用流式布局就不要用绝对定位**。绝对定位手算坐标在中文字体的 ascent/descent 下极易撞车，
  而且改一个字号就要重算全部坐标。绝对定位只留给真正独立于文档流的装饰（背景形状、角标、印章）。
- 一组信息（时间 + 地点 + 主办方）要**成组对齐**，不要各自居中。

## 六、纹理与有机形（复制即用）

```css
/* 噪点：铺在最上层，opacity .3~.6，mix-blend-mode:overlay */
.grain{position:absolute;inset:0;pointer-events:none;opacity:.45;mix-blend-mode:overlay;
 background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='140'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3'/></filter><rect width='140' height='140' filter='url(%23n)' opacity='.55'/></svg>");}

/* 细竖网格 */
background:repeating-linear-gradient(to right,rgba(20,20,20,.055) 0 1px,transparent 1px 100%) 0 0/60px 100%;

/* 点阵 */
background:radial-gradient(rgba(0,0,0,.14) 1.2px,transparent 1.2px) 0 0/22px 22px;

/* 光晕（深色主题用，只放一处） */
background:radial-gradient(60% 50% at 25% 20%,rgba(110,168,255,.28),transparent 70%);

/* 斜条纹 */
background:repeating-linear-gradient(45deg,#111 0 8px,transparent 8px 16px);

/* 高亮词（比 linear-gradient 底纹更稳，不会因行高错位） */
mark{background:#fff;color:#111;padding:0 10px;margin-left:-10px;}
```

```html
<!-- 有机形/墨迹/毛边：湍流位移。scale 越大边缘越碎，配合小幅 blur 才柔和。
     多层用不同 seed 和 baseFrequency，避免所有层边缘同形。 -->
<svg viewBox="0 0 600 460" xmlns="http://www.w3.org/2000/svg">
 <defs><filter id="edge" x="-25%" y="-25%" width="150%" height="150%">
  <feTurbulence type="fractalNoise" baseFrequency="0.013" numOctaves="4" seed="11" result="n"/>
  <feDisplacementMap in="SourceGraphic" in2="n" scale="46" xChannelSelector="R" yChannelSelector="G"/>
  <feGaussianBlur stdDeviation="7"/>
 </filter></defs>
 <ellipse cx="272" cy="262" rx="218" ry="158" fill="#1a1a18" opacity=".15" filter="url(#edge)"/>
 <ellipse cx="205" cy="336" rx="94"  ry="70"  fill="#0b0b09" opacity=".62" filter="url(#edge)"/>
</svg>
```
> 两条导出通道都已验证支持 SVG 滤镜、`mix-blend-mode`、`writing-mode` 竖排。

⚠️ `backdrop-filter` 在页内导出时**不会被渲染**。要玻璃效果就用半透明底色 + 一层模糊的装饰元素代替，或改走 `shot.mjs`。

## 七、别做这些（AI 味清单）

禁止：
- 全屏紫→蓝 45° 渐变；渐变文字 + 发光描边
- 玻璃拟态卡片堆叠、`border-radius:24px` + 大柔光阴影三件套
- 所有元素水平垂直居中、三等分卡片并排
- 用 emoji 当装饰（✨🚀💡）、"赋能/闭环/提升效率"式空话
- 装饰性的抽象几何小圆点撒在角落
- 每个层级都用同一个字重

要有：
- 一处刻意的不对称
- 一个明确的字体反差（衬线 vs 等宽 / 900 vs 300）
- 一个不安全的颜色（不是紫蓝）
- 一个可复用的识别元素（色带 / 徽章 / 编号 / 角标）
- 真实文案。宁可写"上周踩的三个坑"，不要写"深度解析核心要点"。
