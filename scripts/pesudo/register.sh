#!/usr/bin/env bash
# register.sh — pesudo: 注册 sudo → pesudo 别名和 PATH
#
# 替换旧的 set_alias.sh。每个 register.sh 独立可运行。
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 输出 shell 代码到 stdout
#   bash register.sh --help       # 显示帮助

set -euo pipefail

NAME="pesudo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="${SCRIPT_DIR}/client"
REG_DIR="$HOME/.config/playground/registrations.d"
REG_FILE="${REG_DIR}/${NAME}.sh"

# ====== Shell RC 检测 ======
detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            [[ -f "${HOME}/.bash_profile" ]] && echo "${HOME}/.bash_profile" && return
            echo "${HOME}/.bashrc" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

# ====== 生成 shell 注册代码 ======
gen_code() {
    cat <<CODE
# ${NAME} — 安全的 sudo 替代（通过微信 OTP 授权）
export PATH="\${PATH}:${CLIENT_DIR}"
alias sudo='pesudo'
CODE
}

# ====== 清理旧版 set_alias.sh 的 marker block ======
cleanup_old_style() {
    local rc_file
    rc_file="$(detect_rc)"
    [[ ! -f "$rc_file" ]] && return

    local sed_i=("sed" "-i" "")
    [[ "$(uname)" != "Darwin" ]] && sed_i=("sed" "-i")

    if grep -q '# >>> pesudo >>>' "$rc_file" 2>/dev/null; then
        "${sed_i[@]}" '/^# >>> pesudo >>>$/,/^# <<< pesudo <<<$/d' "$rc_file" 2>/dev/null || true
        echo "   ✓ 旧版 set_alias.sh marker 已清理"
    fi
}

# ====== 确保 rc 文件加载 registrations.d/ ======
ensure_rc_sources_reg_dir() {
    local rc_file
    rc_file="$(detect_rc)"
    [[ -z "$rc_file" || ! -f "$rc_file" ]] && return
    local line='[ -d "$HOME/.config/playground/registrations.d" ] && for f in "$HOME/.config/playground/registrations.d/"*.sh; do [ -f "$f" ] && . "$f" 2>/dev/null; done || true'

    if grep -qxF "$line" "$rc_file" 2>/dev/null; then
        return 0
    fi
    echo "" >> "$rc_file"
    echo "# Playground scripts registration" >> "$rc_file"
    echo "$line" >> "$rc_file"
}

# ====== 安装（默认） ======
install() {
    mkdir -p "$REG_DIR"
    gen_code > "$REG_FILE"
    echo "   ✓ 写入 ${REG_FILE}"

    cleanup_old_style
    ensure_rc_sources_reg_dir

    # 立即生效
    (set +u; source "$REG_FILE" 2>/dev/null) || true
    echo "   ✓ ${NAME} 已注册"
}

# ====== 主流程 ======
case "${1:-}" in
    --print|-p)
        gen_code
        ;;
    --help|-h)
        echo "用法: bash register.sh [--print]"
        echo "  注册 ${NAME} 命令到 shell 环境"
        exit 0
        ;;
    *)
        install
        ;;
esac
