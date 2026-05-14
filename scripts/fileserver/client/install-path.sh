#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
将文件服务器客户端命令注入 Shell PATH

用法: bash install-path.sh

将 client 目录（fs-up、fs-dl、fs-ls、fs-share、fs-rm、fs-health 等）加入 Shell 的 PATH。
脚本会自动检测当前 shell（zsh/bash）并写入对应的 rc 文件。

示例:
  bash install-path.sh
  source ~/.zshrc   # 重新加载配置
  fs-ls              # 验证是否生效
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

MARKER="# fs-tools PATH"

detect_shell_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash)
            [ -f "$HOME/.bash_profile" ] && echo "$HOME/.bash_profile" && return
            echo "$HOME/.bashrc"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

RC_FILE=$(detect_shell_rc)

if grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
    echo "PATH 已存在于 ${RC_FILE}，无需重复操作"
    echo "如需重新加载: source ${RC_FILE}"
    exit 0
fi

cat >> "$RC_FILE" <<EOF

${MARKER}
export PATH="\${PATH}:${SCRIPT_DIR}"
EOF

echo "已将 PATH 注入 ${RC_FILE}"
echo "运行以下命令立即生效:"
echo "  source ${RC_FILE}"

CFG_FILE="${SCRIPT_DIR}/fileserver.conf"
TEMPLATE_FILE="${SCRIPT_DIR}/fileserver.conf.TEMPLATE"
if [ ! -f "$CFG_FILE" ] && [ -f "$TEMPLATE_FILE" ]; then
    echo ""
    echo "⚠️  未检测到 fileserver.conf"
    echo "   自动复制模板中..."
    cp "$TEMPLATE_FILE" "$CFG_FILE"
    echo "   已创建: ${CFG_FILE}"
    echo "   请编辑此文件，填入实际的服务器地址和凭据:"
    echo "   FS_HOST / FS_PORT / FS_USER / FS_PASS"
    echo "   FS_SSH_HOST / FS_SSH_PORT / FS_SSH_USER"
    echo "   编辑完成后即可使用 fs-up / fs-dl / fs-ls 等命令"
fi
