#!/usr/bin/env bash
# register.sh — fileserver: 注册客户端工具 PATH
#
# 替换旧的 install-path.sh。独立可运行。
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 输出 shell 代码到 stdout

set -euo pipefail

NAME="fileserver"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG_DIR="$HOME/.config/playground/registrations.d"
REG_FILE="${REG_DIR}/${NAME}.sh"

detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            [[ -f "${HOME}/.bash_profile" ]] && echo "${HOME}/.bash_profile" && return
            echo "${HOME}/.bashrc" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

gen_code() {
    cat <<CODE
# ${NAME} — 文件服务器客户端（fs-up, fs-dl, fs-ls 等）
export PATH="\${PATH}:${SCRIPT_DIR}"
CODE
}

cleanup_old_style() {
    local rc_file
    rc_file="$(detect_rc)"
    [[ ! -f "$rc_file" ]] && return

    local sed_i=("sed" "-i" "")
    [[ "$(uname)" != "Darwin" ]] && sed_i=("sed" "-i")

    if grep -q '# fs-tools PATH' "$rc_file" 2>/dev/null; then
        "${sed_i[@]}" '/# fs-tools PATH/{N;d;}' "$rc_file" 2>/dev/null || true
        echo "   ✓ 旧版 fileserver install-path.sh marker 已清理"
    fi
}

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

install() {
    mkdir -p "$REG_DIR"
    gen_code > "$REG_FILE"
    echo "   ✓ 写入 ${REG_FILE}"

    # 旧版 install-path.sh 还会创建 fileserver.conf（如果不存在）
    local cfg_file="${SCRIPT_DIR}/fileserver.conf"
    local template="${SCRIPT_DIR}/fileserver.conf.TEMPLATE"
    if [[ ! -f "$cfg_file" && -f "$template" ]]; then
        cp "$template" "$cfg_file"
        echo "   ✓ 从模板创建 ${cfg_file}"
        echo "   ⚠️  请编辑 ${cfg_file} 填入实际的服务器地址和凭据"
    fi

    cleanup_old_style
    ensure_rc_sources_reg_dir
    (set +u; source "$REG_FILE" 2>/dev/null) || true
    echo "   ✓ ${NAME} 已注册"
}

case "${1:-}" in
    --print|-p) gen_code ;;
    --help|-h)
        echo "用法: bash register.sh [--print]"
        exit 0
        ;;
    *) install ;;
esac
