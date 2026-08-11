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
source "${SCRIPT_DIR}/../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — 安全的 sudo 替代（通过微信 OTP 授权）
export PATH="\${PATH}:${CLIENT_DIR}"
alias sudo='pesudo'
CODE
}

# 清理旧版 set_alias.sh 的 marker block
cleanup_old_style() {
    local rc_file sed_i
    rc_file="$(playground_detect_rc)"
    [[ ! -f "$rc_file" ]] && return

    sed_i=("sed" "-i" "")
    [[ "$(uname)" != "Darwin" ]] && sed_i=("sed" "-i")

    if grep -q '# >>> pesudo >>>' "$rc_file" 2>/dev/null; then
        "${sed_i[@]}" '/^# >>> pesudo >>>$/,/^# <<< pesudo <<<$/d' "$rc_file" 2>/dev/null || true
        echo "   ✓ 旧版 set_alias.sh marker 已清理"
    fi
}

playground_register_main "$@"
