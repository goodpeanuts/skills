#!/usr/bin/env bash
# web-image · 安装脚本
#
#   curl -fsSL https://raw.githubusercontent.com/whyubel1eve/web-image-skill/main/install.sh | bash
#   ./install.sh                      # 装到默认位置
#   ./install.sh ~/my-agent/skills    # 装到指定目录
#
# 只做三件事：把仓库放到目标目录、检查依赖、渲染一张图自检。

set -euo pipefail

REPO="https://github.com/whyubel1eve/web-image-skill.git"
NAME="web-image"
BLUE=$'\033[34m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say() { printf "%s\n" "$*"; }

# ── 1. 决定装到哪 ───────────────────────────────────────────────
# 优先级：命令行参数 > WEB_IMAGE_DIR 环境变量 > 探测到的已有 agent 目录 > 当前目录
TARGET_PARENT="${1:-${WEB_IMAGE_DIR:-}}"

if [ -z "$TARGET_PARENT" ]; then
  # 只认已经存在的目录，探测不到就不猜——猜错会把文件装到没人读的地方
  for d in "$HOME/.claude/skills" "$HOME/.config/claude/skills"; do
    if [ -d "$d" ]; then TARGET_PARENT="$d"; break; fi
  done
fi

if [ -z "$TARGET_PARENT" ]; then
  TARGET_PARENT="$(pwd)"
  say "${YELLOW}没探测到已知的 agent 技能目录，装到当前目录。${OFF}"
  say "${DIM}如果你的 agent 有专门的技能/规则目录，用 ./install.sh <目录> 指定。${OFF}"
fi

DEST="$TARGET_PARENT/$NAME"
say "${BLUE}安装位置${OFF}  $DEST"

# ── 2. 取代码 ──────────────────────────────────────────────────
if [ -d "$DEST/.git" ]; then
  say "${DIM}已存在，拉取更新…${OFF}"
  git -C "$DEST" pull --ff-only -q
elif [ -e "$DEST" ]; then
  say "${YELLOW}$DEST 已存在且不是 git 仓库，请先移走或换个目录。${OFF}"; exit 1
else
  mkdir -p "$TARGET_PARENT"
  git clone -q --depth 1 "$REPO" "$DEST"
fi
say "${GREEN}✓${OFF} 代码就位"

# ── 3. 依赖检查 ────────────────────────────────────────────────
MISSING=0
if command -v node >/dev/null 2>&1; then
  say "${GREEN}✓${OFF} Node.js $(node -v)"
else
  say "${YELLOW}✗ 缺 Node.js${OFF} —— 批量出图和拼版脚本需要它。页内导出按钮不受影响。"
  MISSING=1
fi

CHROME=""
for p in "${CHROME_PATH:-}" \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
         "/usr/bin/google-chrome" "/usr/bin/chromium" "/usr/bin/chromium-browser"; do
  [ -n "${p:-}" ] && [ -x "$p" ] && { CHROME="$p"; break; }
done
if [ -n "$CHROME" ]; then
  say "${GREEN}✓${OFF} Chrome  ${DIM}${CHROME}${OFF}"
else
  say "${YELLOW}○ 没找到 Chrome${OFF} —— 精确出图通道不可用，但页面里的导出按钮照常可用"
  say "  ${DIM}装了 Chrome 后可用 CHROME_PATH 指定路径${OFF}"
fi

# ── 4. 自检：真渲染一张图 ──────────────────────────────────────
if [ -n "$CHROME" ] && command -v node >/dev/null 2>&1; then
  say ""
  say "${DIM}自检中：渲染一张样张…${OFF}"
  TMP="$(mktemp -d)"
  if node "$DEST/scripts/shot.mjs" "$DEST/examples/styles.html" --scale 1 --only swiss --out "$TMP" >/dev/null 2>&1 \
     && [ -f "$TMP/swiss@1x.png" ]; then
    say "${GREEN}✓${OFF} 出图正常  ${DIM}$(cd "$TMP" && ls -lh swiss@1x.png | awk '{print $5}')${OFF}"
  else
    say "${YELLOW}✗ 自检没通过${OFF} —— 手动跑一次看报错："
    say "  ${DIM}node $DEST/scripts/shot.mjs $DEST/examples/styles.html --only swiss${OFF}"
  fi
  rm -rf "$TMP"
fi

# ── 5. 告诉 agent 接下来读什么 ─────────────────────────────────
say ""
say "${GREEN}装好了。${OFF}"
say ""
say "下一步（给 agent 看的）："
say "  ${BLUE}1${OFF} 读 ${DEST}/SKILL.md —— 里面是流程和 references/ 的路由"
say "  ${BLUE}2${OFF} 需要时再按需读 references/ 下的四份参考"
say "  ${BLUE}3${OFF} 想看 32 套风格长什么样：open ${DEST}/examples/styles.html"
say ""
say "${DIM}用法举例：「帮我做张小红书封面，用中式水墨风格」${OFF}"
