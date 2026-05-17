#!/usr/bin/env bash
# install.sh — 安装 pesudo 客户端到本机
#
# 用法:
#   bash client/install.sh              # 安装到当前机器
#   bash client/install.sh --uninstall  # 卸载
#   bash client/install.sh --help       # 帮助

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${HOME}/.local/bin"
PESUDO_DIR="${HOME}/.pesudo"
RC_FILE="${HOME}/.zshrc"

[[ -f "${RC_FILE}" ]] || RC_FILE="${HOME}/.bashrc"
[[ -f "${RC_FILE}" ]] || RC_FILE="${HOME}/.profile"

source_if_exists() {
    [[ -f "$1" ]] && source "$1" || true
}
source_if_exists "${PROJECT_DIR}/lib/lib-format.sh"

if ! command -v info >/dev/null 2>&1; then
    ok()    { echo -e "  \033[0;32m✓\033[0m $*"; }
    info()  { echo -e "\033[0;36m$*\033[0m"; }
    warn()  { echo -e "  \033[1;33m⚠\033[0m $*"; }
    die()   { echo -e "\033[0;31m❌ $*\033[0m" >&2; exit 1; }
fi

usage() {
    cat >&2 <<EOF
用法: bash client/install.sh [options]

安装 pesudo 客户端到本机。

选项:
  --uninstall   移除 pesudo（别名 + 脚本）
  --help        显示此帮助

说明:
  1. 复制 pesudo 命令到 ~/.local/bin/
  2. 配置 ~/.pesudo/config
  3. 注入 sudo 别名到 shell rc 文件
  4. 安装后需先执行 pesudo-register 注册本机
EOF
    exit 0
}

do_install() {
    section "Pesudo 客户端安装"

    # Step 0: 确保源脚本有执行权限（修复 git 丢失 +x 的情况）
    chmod +x "${SCRIPT_DIR}/pesudo" "${SCRIPT_DIR}/pesudo-register" 2>/dev/null || true

    # Step 1: 创建目录
    info "Step 1: 创建目录"
    mkdir -p "$INSTALL_DIR" "$PESUDO_DIR"
    ok "目录已创建"

    # Step 2: 复制脚本
    info "Step 2: 复制客户端脚本"
    cp "${SCRIPT_DIR}/pesudo"          "${INSTALL_DIR}/pesudo"
    cp "${SCRIPT_DIR}/pesudo-lib.sh"   "${INSTALL_DIR}/pesudo-lib.sh"
    cp "${SCRIPT_DIR}/pesudo-register" "${INSTALL_DIR}/pesudo-register"
    chmod +x "${INSTALL_DIR}/pesudo" "${INSTALL_DIR}/pesudo-register"
    ok "脚本已安装到 ${INSTALL_DIR}"

    # Step 3: 复制配置模板
    info "Step 3: 初始化配置"
    if [[ ! -f "${PESUDO_DIR}/config" ]]; then
        cp "${SCRIPT_DIR}/pesudo.conf.TEMPLATE" "${PESUDO_DIR}/config"
        ok "配置模板已创建: ${PESUDO_DIR}/config"
        warn "编辑 ${PESUDO_DIR}/config 查看配置选项"
    else
        info "配置已存在，跳过"
    fi

    # Step 4: 注入 PATH 和 sudo 别名
    info "Step 4: 配置 PATH 和 sudo 别名"
    local marker_start="# >>> pesudo >>>"
    local marker_end="# <<< pesudo <<<"
    local rc_content="
${marker_start}
export PATH=\"\${PATH}:${INSTALL_DIR}\"
alias sudo='pesudo'
${marker_end}"

    if grep -qF "$marker_start" "$RC_FILE" 2>/dev/null; then
        info "PATH 和别名已存在 ${RC_FILE}，跳过"
    else
        echo "$rc_content" >> "$RC_FILE"
        ok "已添加 PATH 和别名到 ${RC_FILE}"
    fi

    # Step 5: 验证
    info "Step 5: 验证安装"
    if command -v pesudo &>/dev/null; then
        ok "pesudo 命令可用"
    else
        warn "请执行以下命令使 PATH 生效:"
        warn "  source ${RC_FILE}"
    fi

    echo ""
    info "══════════════════════════════════════"
    info "  安装完成！"
    info ""
    info "  下一步: 注册本机到授权服务器"
    info "     pesudo-register"
    info ""
    info "  注册成功后可按提示安装 sudo 别名，"
    info "  或从其他机器注册本机:"
    info "     pesudo-register \${USER}@\$(hostname)"
    info "══════════════════════════════════════"
}

do_uninstall() {
    section "Pesudo 卸载"

    local marker_start="# >>> pesudo >>>"
    local marker_end="# <<< pesudo <<<"

    # 移除别名
    if grep -qF "$marker_start" "$RC_FILE" 2>/dev/null; then
        sed -i "/${marker_start}/,/${marker_end}/d" "$RC_FILE"
        ok "已移除别名 (${RC_FILE})"
    fi

    # 删除脚本
    rm -f "${INSTALL_DIR}/pesudo" "${INSTALL_DIR}/pesudo-lib.sh" "${INSTALL_DIR}/pesudo-register"
    ok "已删除客户端脚本 (${INSTALL_DIR})"

    # 可选保留配置目录
    warn "配置目录保留: ${PESUDO_DIR}（如需删除执行 rm -rf ${PESUDO_DIR}）"

    echo ""
    info "卸载完成，执行以下命令使改动生效:"
    info "  source ${RC_FILE}"
}

main() {
    case "${1:-install}" in
        --uninstall|-u) do_uninstall ;;
        --help|-h) usage ;;
        *) do_install ;;
    esac
}

main "$@"
