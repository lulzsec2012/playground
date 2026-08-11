#!/usr/bin/env bash
# register.sh — proxy: 注册代理工具 PATH
#
# 替换旧的 install-path.sh。独立可运行。
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 输出 shell 代码到 stdout

set -euo pipefail
NAME="proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — 代理工具集
export PATH="\${PATH}:${SCRIPT_DIR}:${SCRIPT_DIR}/bin"
CODE
}

# 清理旧版 install-path.sh 的 marker block
cleanup_old_style() {
    local rc_file sed_i
    rc_file="$(playground_detect_rc)"
    [[ ! -f "$rc_file" ]] && return

    sed_i=("sed" "-i" "")
    [[ "$(uname)" != "Darwin" ]] && sed_i=("sed" "-i")

    if grep -q '# proxy-tools PATH' "$rc_file" 2>/dev/null; then
        # 移除 marker 行及紧随的 export PATH 行
        "${sed_i[@]}" '/# proxy-tools PATH/{N;d;}' "$rc_file" 2>/dev/null || true
        echo "   ✓ 旧版 proxy install-path.sh marker 已清理"
    fi
}

playground_register_main "$@"
