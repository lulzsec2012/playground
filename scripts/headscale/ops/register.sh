#!/usr/bin/env bash
# register.sh — 注册 headscale 常用命令到 shell 环境
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 打印注册代码

set -euo pipefail
NAME="headscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 基础设施地址（gitignored: scripts/data/hosts.cfg, 模板 hosts.cfg.example）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
    for _d in "$SCRIPT_DIR/../../data" "$SCRIPT_DIR/../data"; do
        [[ -f "$_d/hosts.cfg" ]] && {
            HOSTS_CFG="$_d/hosts.cfg"
            break
        }
    done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
TENCENT_IP="${TENCENT_IP:-}"
ALIYUN_IP="${ALIYUN_IP:-}"
COMPANY_IP="${COMPANY_IP:-}"
DEV_HOST_IP="${DEV_HOST_IP:-}"
DEV_HOST2_IP="${DEV_HOST2_IP:-}"
DEV_CONTAINER_IP="${DEV_CONTAINER_IP:-}"
NAS_IP="${NAS_IP:-}"
SSH_USER="${SSH_USER:-}"

source "${SCRIPT_DIR}/../../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — headscale 自建控制面（控制服务器在腾讯云 ECS ${TENCENT_IP}）
HS_ECS="${SSH_USER}@${TENCENT_IP}"
alias hs-ctrl='ssh \${HS_ECS} sudo headscale'
alias hs-nodes='ssh \${HS_ECS} sudo headscale nodes list'
alias hs-users='ssh \${HS_ECS} sudo headscale users list'
alias hs-keys='ssh \${HS_ECS} sudo headscale preauthkeys list'
alias hs-join='sudo bash ${SCRIPT_DIR}/../nodes/join-client.sh'
alias hs-status='tailscale status'
# headscale 链路 SSH（经 NAS SOCKS5 跳板）— 替代失效的旧 tailscale alias
alias ssh-210-hs='ssh hs-210-2225'
alias ssh-ecs-hs='ssh hs-tencent'
alias ssh-210-2225='ssh hs-210-2225'
CODE
}

playground_register_main "$@"
