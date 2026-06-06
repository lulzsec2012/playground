#!/usr/bin/env bash
# install_tools.sh — 安装常用小工具
#
# 工具列表:
#   trzsz      (trz / tsz)    类似 rz/sz 的文件传输工具，兼容 tmux
#   trzsz-ssh  (tssh)         增强版 SSH 客户端，支持 trzsz 自动传输
#   gitu                      终端 Git 客户端（类 Magit TUI）
#
# 用法:
#   bash install_tools.sh              # 全量安装
#   bash install_tools.sh --dry-run    # 预览要安装的工具
#   bash install_tools.sh --help       # 帮助

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ====== 颜色输出 ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# ====== 检测已有工具 ======
tool_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ====== 安装 trzsz（服务端） ======
install_trzsz() {
    echo ""
    echo "========================================"
    echo "  trzsz (trz / tsz)"
    echo "========================================"

    if tool_exists trz; then
        local ver
        ver=$(trz --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "?")
        ok "trzsz 已安装 (v$ver)"
        return 0
    fi

    info "正在通过 pip 安装 trzsz..."
    if pip install trzsz; then
        ok "trzsz 安装成功"
    else
        warn "pip 安装失败，尝试使用 --user 安装（无需 sudo）..."
        pip install --user trzsz || {
            error "trzsz 安装失败"
            return 1
        }
    fi
}

# ====== 安装 trzsz-ssh (tssh) ======
install_trzsz_ssh() {
    echo ""
    echo "========================================"
    echo "  trzsz-ssh (tssh)"
    echo "========================================"

    if tool_exists tssh; then
        local ver
        ver=$(tssh --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "?")
        ok "tssh 已安装 (v$ver)"
        return 0
    fi

    # 检测系统包管理器
    if command -v apt >/dev/null 2>&1; then
        info "通过 PPA 安装 tssh（需 sudo）..."
        if sudo apt update -qq && sudo apt install -y software-properties-common; then
            sudo add-apt-repository -y ppa:trzsz/ppa && sudo apt update -qq && sudo apt install -y tssh && {
                ok "tssh 安装成功（PPA）"
                return 0
            }
        fi
        warn "PPA 安装失败，尝试下载 GitHub Release..."
    fi

    # 降级方案：从 GitHub Release 下载 Linux x86_64 tar.gz
    info "正在从 GitHub Releases 下载 tssh..."

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    local tssh_url="https://github.com/trzsz/trzsz-ssh/releases/latest/download/tssh_linux_x86_64.tar.gz"

    if curl -fsSL -o "$tmpdir/tssh.tar.gz" "$tssh_url" 2>/dev/null; then
        tar -xzf "$tmpdir/tssh.tar.gz" -C "$tmpdir"
        # 解压后目录名类似 tssh_linux_x86_64/
        local tssh_bin
        tssh_bin=$(find "$tmpdir" -name 'tssh' -type f 2>/dev/null | head -1)
        if [[ -n "$tssh_bin" ]]; then
            sudo cp "$tssh_bin" /usr/local/bin/tssh
            sudo chmod 755 /usr/local/bin/tssh
            ok "tssh 安装成功（GitHub Release）"
            return 0
        fi
    fi

    error "tssh 安装失败，请手动下载: https://github.com/trzsz/trzsz-ssh/releases"
    return 1
}

# ====== 安装 gitu ======
install_gitu() {
    echo ""
    echo "========================================"
    echo "  gitu — TUI Git Client"
    echo "========================================"

    if tool_exists gitu; then
        local ver
        ver=$(gitu --version 2>&1 | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "?")
        ok "gitu 已安装 (v$ver)"
        return 0
    fi

    if command -v cargo >/dev/null 2>&1; then
        info "正在通过 cargo 安装 gitu（编译可能需要几分钟）..."
        cargo install gitu --locked || {
            error "gitu 安装失败"
            return 1
        }
        ok "gitu 安装成功"
        # 确保 cargo bin 在 PATH 中
        local cargo_bin="$HOME/.cargo/bin"
        if [[ -d "$cargo_bin" && ":$PATH:" != *":$cargo_bin:"* ]]; then
            warn "请将 $cargo_bin 添加到 PATH:  export PATH=\"$cargo_bin:\$PATH\""
        fi
    else
        error "需要安装 Rust/Cargo: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        return 1
    fi
}

# ====== 主流程 ======
main() {
    echo "========================================"
    echo "  小工具安装脚本"
    echo "========================================"
    echo ""

    local dry_run=false
    case "${1:-}" in
        --dry-run|-n)
            dry_run=true
            ;;
        --help|-h)
            echo "用法: bash install_tools.sh [--dry-run]"
            echo ""
            echo "安装常用小工具:"
            echo "  • trzsz      — 文件传输（trz/tsz）"
            echo "  • trzsz-ssh  — 增强 SSH 客户端（tssh）"
            echo "  • gitu       — 终端 Git 客户端"
            exit 0
            ;;
    esac

    if $dry_run; then
        info "预览模式，已安装的工具将被跳过:"
        for tool in trz tssh gitu; do
            if tool_exists "$tool"; then
                ok "$tool → 已安装"
            else
                info "$tool → 待安装"
            fi
        done
        echo ""
        echo "运行 bash install_tools.sh 执行安装"
        exit 0
    fi

    install_trzsz
    install_trzsz_ssh
    install_gitu

    echo ""
    echo "========================================"
    echo "  安装完成"
    echo "========================================"
    echo ""
    echo "  已安装的工具:"
    for tool in trz tssh gitu; do
        if tool_exists "$tool"; then
            local v
            v=$("$tool" --version 2>&1 | head -1)
            ok "$tool → $v"
        else
            warn "$tool → 未安装"
        fi
    done
}

main "$@"
