#!/usr/bin/env bash
# register.sh — docker: 注册 work-server 命令
#
# work-server.sh 导出函数（work-server, restart-all 等）到 shell 环境。
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 输出 shell 代码到 stdout

set -euo pipefail
NAME="docker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — Docker work-server 工具
source ${SCRIPT_DIR}/work-server.sh

# work-server-scan — 扫描远程服务器容器，生成 tailscale SSH 别名
work-server-scan() {
  bash ${SCRIPT_DIR}/work-server-scan.sh "\$@"
}
CODE
}

playground_register_main "$@"
