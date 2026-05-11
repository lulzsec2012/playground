#!/bin/bash
# ============================================
# install_hermes.sh
# 在阿里云ECS上安装Hermes Agent v0.13.0
# 支持断点续装 — 已完成的步骤自动跳过
# 工作原理：手动 clone + uv 安装，绕过官方安装脚本的交互问题
# ============================================

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/opt/hermes}"
HERMES_REPO="https://github.com/NousResearch/hermes-agent.git"
HERMES_BIN_DIR="$HERMES_HOME/hermes-agent/venv/bin"

# 确保 PATH 包含常用工具目录
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

echo "============================================"
echo " Hermes Agent v0.13.0 安装脚本"
echo " 安装目录: $HERMES_HOME/hermes-agent"
echo "============================================"

# ------ 辅助函数 ------
die() { echo "❌ $*" >&2; exit 1; }
info() { echo ">>> $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }

# ====== 1. 检查/安装 uv ======
info "检查 uv..."
if command -v uv &>/dev/null; then
    ok "uv 已安装 ($(uv --version 2>/dev/null || echo ?))"
else
    info "正在安装 uv..."
    if curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/astral-sh/uv/main/install.sh | bash; then
        export PATH="$HOME/.local/bin:$PATH"
        ok "uv 安装成功"
    else
        info "ghproxy 下载失败，尝试官方源..."
        curl -fsSL https://astral.sh/uv/install.sh | bash
        export PATH="$HOME/.local/bin:$PATH"
        ok "uv 安装成功"
    fi
fi
command -v uv &>/dev/null || die "uv 安装失败"

# ====== 2. 配置镜像源 ======
info "配置 pip/npm/uv 镜像源..."
pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null || true
npm config set registry https://registry.npmmirror.com 2>/dev/null || true
mkdir -p ~/.config/uv
cat > ~/.config/uv/uv.toml << "UVEOF"
[[index]]
url = "https://pypi.tuna.tsinghua.edu.cn/simple/"
default = true
UVEOF
ok "镜像源配置完成"

# ====== 3. 克隆/更新仓库 ======
if [ -d "$HERMES_HOME/hermes-agent/.git" ]; then
    info "仓库已存在，更新中..."
    cd "$HERMES_HOME/hermes-agent"
    git pull --ff-only 2>&1 || warn "git pull 失败，沿用现有版本"
else
    info "克隆 Hermes 仓库..."
    mkdir -p "$HERMES_HOME"
    cd "$HERMES_HOME"
    git clone "$HERMES_REPO" || die "仓库克隆失败"
fi
ok "仓库就绪 ($(cd $HERMES_HOME/hermes-agent && git describe --tags 2>/dev/null || echo ?))"

# ====== 4. 创建虚拟环境 ======
if [ -f "$HERMES_HOME/hermes-agent/venv/bin/python" ]; then
    info "venv 已存在，跳过创建"
else
    info "创建 Python 3.11 虚拟环境..."
    cd "$HERMES_HOME/hermes-agent"
    uv venv --python 3.11 || die "venv 创建失败"
fi
ok "venv 就绪"

# ====== 5. 安装依赖 ======
info "安装 Python 依赖（使用清华镜像源，耗时较长）..."
cd "$HERMES_HOME/hermes-agent"
source venv/bin/activate

if uv pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple/ -e . 2>&1; then
    ok "依赖安装完成"
else
    warn "uv 安装失败，尝试 pip 安装..."
    pip install --index-url https://pypi.tuna.tsinghua.edu.cn/simple/ -e . || die "依赖安装失败"
fi

# ====== 6. 配置 PATH 和链接 ======
info "配置环境变量..."
if ! grep -q "hermes-agent/venv/bin" ~/.bashrc 2>/dev/null; then
    echo "export PATH=\"$HERMES_BIN_DIR:\$PATH\"" >> ~/.bashrc
fi
export PATH="$HERMES_BIN_DIR:$PATH"

if [ ! -L ~/.hermes ]; then
    ln -sf "$HERMES_HOME/hermes-agent" ~/.hermes
fi

# ====== 7. 验证安装 ======
echo ""
if command -v hermes &>/dev/null; then
    echo "============================================"
    echo "✅ Hermes Agent 安装成功！"
    echo "   版本:     $(hermes --version 2>/dev/null | head -1)"
    echo "   命令路径: $(which hermes)"
    echo "   安装目录: $HERMES_HOME/hermes-agent"
    echo ""
    echo "   重新登录后 hermes 命令会自动生效"
    echo "   或手动执行: source ~/.bashrc"
    echo "============================================"
    echo ""
    echo "💡 接下来配置聊天通道："
    echo "   bash ~/playground/scripts/hermes/setup_channels.sh"
else
    die "hermes 命令未找到，请检查 $HERMES_BIN_DIR"
fi
