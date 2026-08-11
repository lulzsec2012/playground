#!/usr/bin/env bash
# register.sh — newapi: 注册 new-api 管理命令到 shell
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 打印注册代码

set -euo pipefail
NAME="newapi"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 基础设施地址（gitignored: scripts/data/hosts.cfg）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
    for _d in "$SCRIPT_DIR/../data" "$SCRIPT_DIR/../../data"; do
        [[ -f "$_d/hosts.cfg" ]] && {
            HOSTS_CFG="$_d/hosts.cfg"
            break
        }
    done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
ALIYUN_IP="${ALIYUN_IP:-}"
SSH_USER="${SSH_USER:-}"

source "${SCRIPT_DIR}/../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — new-api LLM 网关 (阿里云, IP 见 scripts/data/hosts.cfg)
NEWAPI_ECS="${SSH_USER}@${ALIYUN_IP}"
alias newapi-ctrl='docker exec -it new-api /app/new-api'
alias newapi-status='ssh \${NEWAPI_ECS} "docker ps --filter name=new-api --format \"{{.Names}} {{.Status}}\""'
alias newapi-logs='ssh \${NEWAPI_ECS} "docker logs --tail 50 new-api"'
alias newapi-restart='ssh \${NEWAPI_ECS} "docker restart new-api"'
CODE
}

playground_register_main "$@"
