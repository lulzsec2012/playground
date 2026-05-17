#!/usr/bin/env bash
# ============================================================================
# Obsidian 跨平台安装脚本
# 支持: macOS (GUI + CLI) / Linux (CLI only, headless)
# ============================================================================
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $1"; }
error() { echo -e "${RED}  [ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}  >>>${NC} ${BOLD}$1${NC}"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }
skip()  { echo -e "${YELLOW}  -${NC} $1 (已存在, 跳过)"; }

# ── 检测平台 ──────────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
CLI_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --cli-only) CLI_ONLY=true ;;
    --help|-h)
      echo "用法: bash install.sh [--cli-only]"
      echo "  --cli-only    只装 CLI 工具 (适合 headless Linux)"
      exit 0 ;;
  esac
done

echo -e "${BOLD}Obsidian 安装脚本 — ${OS} ${ARCH}${NC}"
$CLI_ONLY && echo "  模式: CLI only (无 GUI)"

# ============================================================================
# Phase 1: 系统依赖
# ============================================================================
step "系统依赖"

case "$OS" in
  Darwin)
    if ! command -v brew &>/dev/null; then
      info "安装 Homebrew..."
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
      ok "Homebrew $(brew --version | head -1)"
    fi
    ;;
  Linux)
    if command -v apt-get &>/dev/null; then
      info "安装编译依赖 (build-essential, pkg-config, libssl-dev)..."
      sudo apt-get update -qq && sudo apt-get install -y -qq build-essential pkg-config libssl-dev curl
    elif command -v yum &>/dev/null; then
      info "安装编译依赖..."
      sudo yum install -y gcc gcc-c++ make openssl-devel curl
    fi
    ;;
esac

# ============================================================================
# Phase 2: 安装 Rust / Cargo (如果缺失, obsidian-export 需要)
# ============================================================================
step "Rust 工具链"

if command -v cargo &>/dev/null; then
  skip "cargo $(cargo --version | cut -d' ' -f2)"
else
  info "安装 Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
  ok "Rust 已安装"
fi

# ============================================================================
# Phase 3: 安装 CLI 工具 (跨平台)
# ============================================================================
step "CLI 工具"

install_cargo_tool() {
  local name="$1" pkg="${2:-$1}"
  if command -v "$name" &>/dev/null; then
    skip "$name ($($name --version 2>/dev/null | head -1))"
  else
    info "安装 $name..."
    cargo install "$pkg"
    ok "$name 已安装"
  fi
}

install_cargo_tool "obsidian-export" "obsidian-export"

# 可选: 安装 obsidian-vault-stats（提供 vault 统计功能）
if command -v obsidian-vault-stats &>/dev/null; then
  skip "obsidian-vault-stats"
else
  info "安装 obsidian-vault-stats..."
  cargo install obsidian-vault-stats 2>/dev/null && ok "obsidian-vault-stats 已安装" || warn "obsidian-vault-stats 跳过 (非必需)"
fi

# ============================================================================
# Phase 4: 安装 Obsidian GUI (仅 macOS)
# ============================================================================
if ! $CLI_ONLY; then
  step "Obsidian GUI"

  case "$OS" in
    Darwin)
      if brew list --cask obsidian &>/dev/null 2>&1; then
        skip "Obsidian (brew cask)"
      else
        info "安装 Obsidian (brew install --cask obsidian)..."
        brew install --cask obsidian
        ok "Obsidian 已安装"
      fi
      ;;
    Linux)
      if command -v obsidian &>/dev/null; then
        skip "Obsidian"
      else
        info "Linux 桌面版 Obsidian 安装方式:"
        echo "   Flatpak: flatpak install flathub md.obsidian.Obsidian"
        echo "   Snap:    sudo snap install obsidian"
        echo "   .deb:    下载 https://obsidian.md/download 安装"
        echo ""
        warn "当前环境可能是 headless, 跳过 GUI 安装"
        echo "   使用 --cli-only 可静默跳过"
      fi
      ;;
  esac
fi

# ============================================================================
# 完成
# ============================================================================
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Obsidian 安装完成${NC}"
echo ""
echo "  CLI 工具:"
echo "    obsidian-export     — vault → 标准 Markdown 导出"
echo "    obsidian-vault-stats — vault 统计分析"
echo ""

if [[ "$OS" == "Darwin" ]] && ! $CLI_ONLY; then
  echo "  GUI: 已安装, 启动: open -a Obsidian"
fi
echo ""
echo "  下一步:"
echo "    bash setup-vault.sh /path/to/vault    # 初始化 vault"
echo "    bash register.sh                      # 注册 CLI 到 PATH"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
