#!/usr/bin/env bash
# register-lib.sh — register.sh 公共框架
#
# 各模块 register.sh 只保留 gen_code()（及可选的 cleanup_old_style() /
# playground_post_install()），其余样板逻辑（detect_rc / ensure_rc_sources_reg_dir /
# install / 主流程分支）统一由本库提供，避免多份重复代码。
#
# 模块使用约定（source 本库之前）:
#   NAME        — 模块名（决定 ~/.config/playground/registrations.d/<NAME>.sh）
#   SCRIPT_DIR  — 模块脚本目录（绝对路径）
#
# 模块必须定义 gen_code()：输出注册 shell 代码到 stdout。
# 可选定义:
#   cleanup_old_style()         — 清理旧版注册残留（rc 文件里的旧 marker）
#   playground_post_install()   — 注册完成后额外动作（如从模板创建配置文件）
#
# 主流程: playground_register_main "$@"

set -euo pipefail

# ── Shell RC 检测 ──────────────────────────────────────────────────────────
playground_detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            [[ -f "${HOME}/.bash_profile" ]] && echo "${HOME}/.bash_profile" && return
            echo "${HOME}/.bashrc" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

# ── 确保 rc 文件加载 registrations.d/ ────────────────────────────────────
playground_ensure_rc_sources_reg_dir() {
    local rc_file line
    rc_file="$(playground_detect_rc)"
    [[ -z "$rc_file" || ! -f "$rc_file" ]] && return
    line='[ -d "$HOME/.config/playground/registrations.d" ] && for f in "$HOME/.config/playground/registrations.d/"*.sh; do [ -f "$f" ] && . "$f" 2>/dev/null; done || true'

    if grep -qxF "$line" "$rc_file" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "# Playground scripts registration"
        echo "$line"
    } >> "$rc_file"
}

# ── 安装（默认） ───────────────────────────────────────────────────────────
playground_install() {
    local reg_dir reg_file
    reg_dir="$HOME/.config/playground/registrations.d"
    reg_file="${reg_dir}/${NAME}.sh"

    mkdir -p "$reg_dir"
    gen_code > "$reg_file"
    echo "   ✓ 写入 ${reg_file}"

    if declare -F cleanup_old_style >/dev/null 2>&1; then
        cleanup_old_style
    fi
    playground_ensure_rc_sources_reg_dir

    # 立即生效
    (set +u; source "$reg_file" 2>/dev/null) || true
    echo "   ✓ ${NAME} 已注册"

    if declare -F playground_post_install >/dev/null 2>&1; then
        playground_post_install
    fi
}

# ── 主流程 ─────────────────────────────────────────────────────────────────
playground_register_main() {
    case "${1:-}" in
        --print | -p)
            gen_code
            ;;
        --help | -h)
            echo "用法: bash register.sh [--print]"
            echo "  注册 ${NAME} 命令到 shell 环境"
            exit 0
            ;;
        *)
            playground_install
            ;;
    esac
}
