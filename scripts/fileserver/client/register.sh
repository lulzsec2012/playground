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
source "${SCRIPT_DIR}/../../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — 文件服务器客户端（fs-up, fs-dl, fs-ls 等）
export PATH="\${PATH}:${SCRIPT_DIR}"
CODE
}

# 清理旧版 install-path.sh 的 marker block
cleanup_old_style() {
    local rc_file sed_i
    rc_file="$(playground_detect_rc)"
    [[ ! -f "$rc_file" ]] && return

    sed_i=("sed" "-i" "")
    [[ "$(uname)" != "Darwin" ]] && sed_i=("sed" "-i")

    if grep -q '# fs-tools PATH' "$rc_file" 2>/dev/null; then
        "${sed_i[@]}" '/# fs-tools PATH/{N;d;}' "$rc_file" 2>/dev/null || true
        echo "   ✓ 旧版 fileserver install-path.sh marker 已清理"
    fi
}

# 首次注册时从模板创建配置文件
playground_post_install() {
    local cfg_file template
    cfg_file="${SCRIPT_DIR}/fileserver.conf"
    template="${SCRIPT_DIR}/fileserver.conf.TEMPLATE"
    if [[ ! -f "$cfg_file" && -f "$template" ]]; then
        cp "$template" "$cfg_file"
        echo "   ✓ 从模板创建 ${cfg_file}"
        echo "   ⚠️  请编辑 ${cfg_file} 填入实际的服务器地址和凭据"
    fi
}

playground_register_main "$@"
