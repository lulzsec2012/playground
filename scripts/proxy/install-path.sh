#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="# proxy-tools PATH"

usage() {
    cat <<EOF
将 proxy 命令（fetch.sh, free.sh 等）加入 Shell PATH

用法: bash install-path.sh

示例:
  bash install-path.sh
  source ~/.zshrc
  fetch.sh --help
EOF
}

detect_shell_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash)
            [ -f "$HOME/.bash_profile" ] && echo "$HOME/.bash_profile" && return
            echo "$HOME/.bashrc"
            ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

RC_FILE=$(detect_shell_rc)
EXPORT_LINE="export PATH=\"\${PATH}:${SCRIPT_DIR}\""

if grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
    # 更新已有路径（可能 repo 搬家了）
    if grep -qF "$SCRIPT_DIR" "$RC_FILE" 2>/dev/null; then
        echo "PATH 已存在，无需操作"
    else
        # 目录不同，更新
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^export PATH=.*# proxy-tools PATH$|${EXPORT_LINE}  ${MARKER}|" "$RC_FILE"
        else
            sed -i "s|^export PATH=.*# proxy-tools PATH$|${EXPORT_LINE}  ${MARKER}|" "$RC_FILE"
        fi
        echo "PATH 已更新为: ${SCRIPT_DIR}"
    fi
else
    cat >> "$RC_FILE" <<EOF

${MARKER}
${EXPORT_LINE}
EOF
    echo "已将 PATH 注入 ${RC_FILE}"
fi

echo "运行以下命令立即生效:"
echo "  source ${RC_FILE}"
