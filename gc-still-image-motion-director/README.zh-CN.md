# GC 静态图片动态导演

[English](README.md) · **简体中文**

这是一个 Codex Skill：读取真实静态图片，判断它适合明显运动、微动，还是应该保持静止，然后输出一条克制、可直接复制的图生视频 Prompt，同时尽量避免文字、纸张、边框和版式漂移。

可调用名称为 `gc-still-image-motion-director`。

这个 Skill 负责动态判断和 Prompt 编写，不负责生成最终视频。

## 它能做什么

这个 Skill 会：

- 先读取真实图片，再决定如何运动；
- 区分画面中实际可见的内容和动态建议；
- 最多选择一个主动作和一个具有物理关联的伴随动作；
- 明确锁定文字、数字、纸张、边框、网格和构图；
- 在 `motion`、`micro-motion`、`static` 三种判断中做选择；
- 根据用户指定的图生视频平台调整最终 Prompt；
- 针对文字变化、纸张呼吸、镜头漂移和版式变形重写失败的 Prompt。

它不会默认套用镜头推进、图层漂浮、纸张呼吸、通用粒子或无依据的视差效果。

## 案例

下面只保留两组案例，用来说明 `motion` 和 `micro-motion` 的区别。

每组案例都由用户提供原图，并要求 Codex 调用本 Skill。Codex 读取图片后生成下面展示的中文 Seedance 2.0 Prompt，再将该 Prompt 提交给 Seedance 2.0，生成对应的结果视频。这里展示的是真实生成结果；生成具有随机性，实际返回的视频不一定百分之百遵守每一条锁定要求。

### `motion` — CHOICE

<img src="examples/choice-butterfly.jpg" width="360" alt="蝴蝶位于蓝色矩形旁的 CHOICE 编辑海报">

蝴蝶停留在原有视觉区域内，完成一次有边界的振翅。蓝色矩形、信封线稿、标题、中文文案、纸张纹理和整体构图保持固定。

[查看 4 秒 MP4 结果](examples/choice-butterfly.mp4)

源文件已经验证为真实匹配的 Apple Live Photo 图片与视频配对。为了方便浏览器查看，本仓库只公开无音频的 MP4 副本，不上传 Live Photo 文件包。

<details>
<summary>查看本次生成使用的 Seedance 2.0 Prompt</summary>

```text
固定镜头，保持原图构图、纸张质感和全部排版完全不变。

只让蓝色矩形左上方现有的白色线稿蝴蝶缓慢完成一次振翅：双翼从当前展开状态向内收拢约8至10度，再平稳展开回到原始角度。蝴蝶身体和落点基本不动，整体位移不超过蓝色矩形宽度的1%，最后完全停稳。

蓝色矩形、信封线稿、信封折线、中央火漆印、三个浅蓝圆点、CHOICE及其倒影、中文“命运偶尔借一只蝴蝶，改写人的选择。”、四周日期、编号、档案文字、边线、折痕、污点和纸张纹理全部固定。

禁止蝴蝶飞走、持续扇翅、增加或减少翅膀，禁止蝴蝶复制或变形成真实昆虫，禁止信封打开、移动或变形，禁止火漆印旋转，禁止圆点漂浮，禁止文字变化、纸张呼吸和镜头移动。
4秒，先停留约0.6秒，只完成一次缓慢振翅，最后恢复静止。
```

</details>

### `micro-motion` — 今天适合走得慢一点

<img src="examples/walk-slowly.png" width="360" alt="包含草地和云朵照片窗口的极简编辑海报">

动态只发生在两个照片窗口内部：左侧草地与光影轻微变化，右侧云朵缓慢变化。路径文字、中文标题、纸张纹理、间距和整体版式保持固定。

[查看 4 秒 MP4 结果](examples/walk-slowly.mp4)

<details>
<summary>查看本次生成使用的 Seedance 2.0 Prompt</summary>

```text
固定镜头，完整保持原图的纵向海报构图、留白和编辑排版。

前1秒画面保持静止。随后只让右侧云朵照片框内部的白云缓慢向右漂移，位移不超过该照片框宽度的3%，云朵形状、体积和边缘保持稳定，不生成新的云朵。

同时，左侧草地照片框内部受到同一阵轻微微风影响，少量草叶只摆动2–3度，斑驳阳光在草地表面产生非常缓慢、细微的明暗变化。所有动态必须严格限制在两个矩形照片框内部，最后1秒逐渐稳定下来。

绿色曲线、绿色圆点、“walk slowly today with the wind”全部单词、右侧浅灰英文诗句、中文标题、日期、署名、照片框边界、旧纸颜色、纸张纤维、颗粒、污点和大面积留白完全固定。

禁止文字改写、字母闪烁、绿色曲线变形、圆点移动、照片框漂移或变形；禁止云朵快速移动、翻滚或新增；禁止草地大幅摇晃；禁止纸张呼吸、纹理漂浮、全画面曝光变化、镜头推近、平移、缩放、旋转、景深变化和视差。

4秒，极度克制、安静，像一阵微风只经过照片里的草地和云，海报本身始终保持静止。
```

</details>

## 安装

直接把公开仓库克隆到 Codex Skills 目录：

```bash
git clone https://github.com/LiamGvchi/gc-still-image-motion-director.git \
  ~/.codex/skills/gc-still-image-motion-director
```

如果没有立即出现，请重启 Codex。

## 使用方法

分析单张图片：

```text
用 $gc-still-image-motion-director 分析这张海报应该怎么动，
锁住文字和纸张，并给我一条可复制的图生视频 Prompt。
```

分析一组图片：

```text
用 $gc-still-image-motion-director 分析这个图片文件夹，
分别判断哪些适合动、哪些只适合微动、哪些应该保持静止。
```

修复失败结果：

```text
用 $gc-still-image-motion-director 重写这条 Prompt：
上一版出现了文字变化、纸张呼吸和镜头漂移。
```

## 输出内容

针对每张图片，这个 Skill 可以输出：

1. 真实可见的画面观察；
2. `motion`、`micro-motion` 或 `static` 判断；
3. 一个有明确范围的主动作，以及可选的关联动作；
4. 必须保持固定的元素列表；
5. 可直接复制的图生视频 Prompt；
6. 最主要的失败风险。

未指定平台和时长时，默认输出克制的 4 秒动态方案。

## 仓库结构

- `SKILL.md`：核心流程和输出规范
- `references/motion-decision-framework.md`：动态适配度、幅度、时长和构图规则
- `references/prompt-construction.md`：Prompt 顺序、固定项、禁止项和失败修复方法
- `agents/openai.yaml`：Codex 界面元数据
- `evals/evals.json`：代表性的触发与不触发测试用例
- `examples/`：两组分别展示 `motion` 与 `micro-motion` 的原图和结果
- `LICENSE`：MIT 开源许可证

本仓库只发布这一个独立 Skill，不包含私人备份、无关用户素材、平台凭证，也不会声称案例视频由 Skill 自己生成。

## 兼容性声明

本项目为独立项目，与即梦及其他图生视频平台不存在隶属、合作或官方背书关系。产品名称仅用于描述兼容性。

平台行为可能发生变化。本 Skill 不会声称支持未经公开说明的控制能力；无法确定平台行为时，会输出平台中立的 Prompt。

## 相关 Skill

如需生成克制的极简 zine 风格纸感海报，可查看 [GC Minimal Zine Poster](https://github.com/LiamGvchi/gc-minimal-zine-poster)。

## 开源许可证

MIT，详见 `LICENSE`。
