#!/usr/bin/env bash
set -e

# ============================================
# OpenCode + 插件安装脚本
# 在开发容器内执行: bash scripts/opencode/oc-install.sh
# ============================================

echo "========================================"
echo "  OpenCode Environment Setup"
echo "========================================"

# ---------- 1. 安装 opencode CLI（官方安装方式，无需 sudo）----------
echo ""
echo "[1/7] Installing opencode CLI..."
if command -v opencode &>/dev/null; then
    echo "  opencode already installed: $(opencode --version)"
else
    echo "  通过官方脚本安装到 \$HOME/.opencode/bin/ ..."
    if curl -fsSL https://opencode.ai/install | bash; then
        # 官方脚本会修改 PATH，立即加载以便后续步骤使用
        export PATH="$HOME/.opencode/bin:$PATH"
        echo "  opencode installed: $(opencode --version)"
    else
        echo "  ⚠️  官方安装失败，降级到 npm..."
        if command -v npm &>/dev/null; then
            npm install -g opencode
            echo "  opencode installed: $(opencode --version)"
        else
            echo "  ❌ npm 也不可用，请手动安装 opencode" >&2
            exit 1
        fi
    fi
fi

# ---------- 2. 安装 bun ----------
echo ""
echo "[2/7] Installing bun..."
if command -v bun &>/dev/null; then
    echo "  bun already installed: $(bun --version)"
else
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    echo "  bun installed: $(bun --version)"
fi

# ---------- 3. 安装 oh-my-opencode ----------
echo ""
echo "[3/7] Installing oh-my-opencode plugin..."
if [ -d "$HOME/.config/opencode/plugins/oh-my-opencode" ] || npm ls -g oh-my-opencode &>/dev/null; then
    echo "  oh-my-opencode already installed"
else
    npm install -g oh-my-opencode
    echo "  oh-my-opencode installed"
    echo "  配置指南: https://raw.githubusercontent.com/code-yeongyu/oh-my-opencode/refs/heads/master/docs/guide/installation.md"
fi

# ---------- 4. 安装 openspec ----------
echo ""
echo "[4/7] Installing openspec..."
if command -v openspec &>/dev/null; then
    echo "  openspec already installed: $(openspec --version 2>/dev/null || echo 'ok')"
else
    npm install -g @fission-ai/openspec@latest
    echo "  openspec installed"
    echo "  在项目目录执行 'openspec init' 初始化"
fi

# ---------- 5. 安装 superpowers（14 个核心技能）----------
echo ""
echo "[5/7] Installing superpowers skills..."
if [ -d "$HOME/.opencode/skills/obra/superpowers" ]; then
    echo "  superpowers already installed"
else
    npx skills add obra/superpowers -y
    echo "  superpowers installed"
fi

# ---------- 6. 安装 planning-with-files ----------
echo ""
echo "[6/7] Installing planning-with-files..."
if [ -d "$HOME/.opencode/skills/OthmanAdi/planning-with-files" ]; then
    echo "  planning-with-files already installed"
else
    npx skills add OthmanAdi/planning-with-files -y
    echo "  planning-with-files installed"
fi

# ---------- 7. 安装 opencode-conversation-analysis ----------
echo ""
echo "[7/7] Installing opencode-conversation-analysis..."
if [ -d "$HOME/.opencode/skills/connorads/opencode-conversation-analysis" ]; then
    echo "  opencode-conversation-analysis already installed"
else
    npx skills add https://github.com/connorads/opencode-conversation-analysis
    echo "  opencode-conversation-analysis installed"
fi

# ---------- 额外工具 ----------
echo ""
echo "--- Optional tools ---"

# opencode-agent-optimizer
if command -v opencode-agent-optimizer &>/dev/null; then
    echo "  opencode-agent-optimizer already installed"
else
    echo "  Installing opencode-agent-optimizer..."
    npm install -g opencode-agent-optimizer
    echo "  opencode-agent-optimizer installed"
    echo "  用法: opencode-agent-optimizer summary"
    echo "        opencode-agent-optimizer suggest --all"
    echo "        opencode-agent-optimizer install"
fi

# opencode-analytics
if command -v opencode-analytics &>/dev/null; then
    echo "  opencode-analytics already installed"
else
    echo "  Installing opencode-analytics..."
    npm install -g opencode-analytics
    echo "  opencode-analytics installed"
    echo "  启动: opencode-analytics --port 3456 --no-open &"
    echo "  访问: http://<容器IP>:3456"
fi

# opencode-multi（需要 Rust toolchain）
if command -v opencode-multi &>/dev/null; then
    echo "  opencode-multi already installed: $(opencode-multi --version 2>/dev/null || echo 'ok')"
else
    if command -v cargo &>/dev/null; then
        echo "  Installing opencode-multi (cargo install)..."
        cargo install opencode-multi
        echo "  opencode-multi installed"
    else
        echo "  ⚠️  cargo 未安装，跳过 opencode-multi"
        echo "    安装 Rust: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    fi
fi

echo ""
echo "========================================"
echo "  OpenCode Environment Setup Complete!"
echo "========================================"
echo ""
echo "下一步:"
echo "  1. 配置 opencode.json (复制 ~/.config/opencode/opencode.json)"
echo "  2. source ~/.bashrc 或新开终端"
echo "  3. 运行 opencode 开始使用"
