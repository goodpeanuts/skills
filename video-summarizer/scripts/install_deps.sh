#!/bin/bash
# Install all dependencies for video-summarizer skill

set -e

echo "=========================================="
echo "Video Summarizer - Dependency Installer"
echo "=========================================="
echo ""

# ==========================================
# 1. uv (Python package manager)
# ==========================================
echo "[1/6] Checking uv..."
if ! command -v uv &> /dev/null; then
    echo "  Installing uv..."
    if [[ "$OSTYPE" == "darwin"* ]] || [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # Add uv to PATH for current session
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo "  Error: Unsupported OS. Please install uv manually:"
        echo "    https://docs.astral.sh/uv/getting-started/installation/"
        exit 1
    fi
    echo "  uv installed"
else
    echo "  uv: OK"
fi

# ==========================================
# 2. ffmpeg (required for audio processing)
# ==========================================
echo ""
echo "[2/6] Checking ffmpeg..."
if ! command -v ffmpeg &> /dev/null; then
    echo "  Installing ffmpeg..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            brew install ffmpeg
        else
            echo "  Error: Homebrew not found. Please install ffmpeg manually:"
            echo "    brew install ffmpeg"
            exit 1
        fi
    elif [[ -f /etc/debian_version ]]; then
        sudo apt-get update && sudo apt-get install -y ffmpeg
    elif [[ -f /etc/redhat-release ]]; then
        sudo dnf install -y ffmpeg
    else
        echo "  Error: Please install ffmpeg manually"
        exit 1
    fi
    echo "  ffmpeg installed"
else
    echo "  ffmpeg: OK"
fi

# Check ffprobe (included with ffmpeg)
if ! command -v ffprobe &> /dev/null; then
    echo "  Error: ffprobe not found (should be included with ffmpeg)"
    exit 1
else
    echo "  ffprobe: OK"
fi

# ==========================================
# 3. yt-dlp (required for video downloading)
# ==========================================
echo ""
echo "[3/6] Checking yt-dlp..."
if ! command -v yt-dlp &> /dev/null; then
    echo "  Installing yt-dlp with uv tool (persistent install)..."
    # 注意: 不能用 uvx 探测代替安装——uvx 是临时执行不落 PATH，rc=0 会短路掉
    # uv tool install，造成"安装成功"但 PATH 无 yt-dlp 的虚假成功
    uv tool install yt-dlp
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v yt-dlp &> /dev/null; then
        echo "  Error: uv tool install 完成但 yt-dlp 不在 PATH（检查 ~/.local/bin 是否入 PATH）"
        exit 1
    fi
    echo "  yt-dlp installed"
else
    echo "  yt-dlp: OK"
fi

# ==========================================
# 4. faster-whisper (managed by uv)
# ==========================================
echo ""
echo "[4/6] faster-whisper (说明性检查，无安装动作)"
echo "  由 uv 在首次运行转写脚本时按需安装（parallel_transcribe.py 的 PEP 723 内联依赖）"

# ==========================================
# 5. JS runtime (yt-dlp YouTube 等平台需要，deno 为默认支持项)
# ==========================================
echo ""
echo "[5/6] Checking JS runtime (deno)..."
if ! command -v deno &> /dev/null; then
    echo "  Warning: deno not found. YouTube extraction requires a JS runtime."
    echo "    Install:  brew install deno   (or pass --js-runtimes node to yt-dlp)"
    echo "    Other platforms work without it."
else
    echo "  deno: $(deno --version 2>&1 | head -1)"
fi

# ==========================================
# 6. Python (check version)
# ==========================================
echo ""
echo "[6/6] Checking Python..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
    echo "  Python: $PYTHON_VERSION"

    # Check if version >= 3.8
    MAJOR=$(echo $PYTHON_VERSION | cut -d'.' -f1)
    MINOR=$(echo $PYTHON_VERSION | cut -d'.' -f2)
    if [[ $MAJOR -lt 3 ]] || [[ $MAJOR -eq 3 && $MINOR -lt 8 ]]; then
        echo "  Warning: Python 3.8+ recommended (current: $PYTHON_VERSION)"
    fi
else
    echo "  Error: Python 3 not found"
    exit 1
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "All dependencies installed successfully!"
echo "=========================================="
echo ""
echo "Installed tools:"
echo "  - uv: $(uv --version 2>&1)"
echo "  - ffmpeg: $(ffmpeg -version 2>&1 | head -1 | cut -d' ' -f3)"
echo "  - yt-dlp: $(yt-dlp --version 2>&1 || echo 'will be installed on first use')"
echo "  - faster-whisper: managed by uv (auto-installed)"
echo "  - deno: $(deno --version 2>&1 | head -1 || echo 'missing (YouTube only; brew install deno)')"
echo "  - Python: $PYTHON_VERSION"
echo ""
echo "You can now use the video-summarizer skill!"
echo "Python dependencies will be automatically managed by uv."
