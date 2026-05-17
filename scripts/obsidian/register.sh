#!/usr/bin/env bash
# register.sh — 注册 obsidian CLI 工具到 shell 环境
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 打印注册代码
#
# 注册内容:
#   - obsidian-export → PATH (cargo bin)
#   - open -a Obsidian → alias ob

set -euo pipefail

NAME="obsidian"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG_DIR="$HOME/.config/playground/registrations.d"
REG_FILE="${REG_DIR}/${NAME}.sh"

# ── Shell RC 检测 ─────────────────────────────────────────────────────────
detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            [[ -f "${HOME}/.bash_profile" ]] && echo "${HOME}/.bash_profile" && return
            echo "${HOME}/.bashrc" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

# ── 生成注册代码 ──────────────────────────────────────────────────────────
gen_code() {
    cat <<CODE
# ${NAME} — Obsidian CLI 工具
export PATH="\${PATH}:\${HOME}/.cargo/bin"
alias ob='open -a Obsidian'
CODE
}

# ── 确保 rc 文件加载 registrations.d/ ────────────────────────────────────
ensure_rc_sources_reg_dir() {
    local rc_file
    rc_file="$(detect_rc)"
    local line='[ -d "$HOME/.config/playground/registrations.d" ] && for f in "$HOME/.config/playground/registrations.d/"*.sh; do [ -f "$f" ] && . "$f" 2>/dev/null; done || true'

    if grep -qxF "$line" "$rc_file" 2>/dev/null; then
        return 0
    fi
    echo "" >> "$rc_file"
    echo "# Playground scripts registration" >> "$rc_file"
    echo "$line" >> "$rc_file"
}

# ── 安装 ──────────────────────────────────────────────────────────────────
install() {
    mkdir -p "$REG_DIR"
    gen_code > "$REG_FILE"
    echo "   ✓ 写入 ${REG_FILE}"
    ensure_rc_sources_reg_dir
    source "$REG_FILE" 2>/dev/null || true
    echo "   ✓ ${NAME} 已注册"
}

# ── 主流程 ────────────────────────────────────────────────────────────────
case "${1:-}" in
    --print|-p) gen_code ;;
    --help|-h)
        echo "用法: bash register.sh [--print]"
        exit 0 ;;
    *) install ;;
esac
