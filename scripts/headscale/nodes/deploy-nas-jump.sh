#!/usr/bin/env bash
# ============================================================
# deploy-nas-jump.sh — NAS 2221 容器 (ubuntu-lite) tailscale 跳板部署
#
# 背景:
#   NAS 容器无 /dev/net/tun（内核 4.4 无 tun 模块），
#   故使用 userspace-networking 模式 + SOCKS5 代理，
#   局域网内 Mac 等设备经 NAS 访问 headscale tailnet。
#
# 架构:
#   Mac ──局域网(≈0.5ms)──► NAS:1080 (SOCKS5) ──tailnet──► 公司服务器
#
# 用法:
#   bash deploy-nas-jump.sh <authkey>
#   （在 Mac 上执行，自动 SSH 到 NAS 2221 容器）
# ============================================================
set -euo pipefail
# 基础设施地址（gitignored: scripts/data/hosts.cfg, 模板 hosts.cfg.example）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
    for _d in "$(dirname "${BASH_SOURCE[0]}")/../../data" "$(dirname "${BASH_SOURCE[0]}")/../data"; do
        [[ -f "$_d/hosts.cfg" ]] && { HOSTS_CFG="$_d/hosts.cfg"; break; }
    done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
TENCENT_IP="${TENCENT_IP:-}"; ALIYUN_IP="${ALIYUN_IP:-}"; COMPANY_IP="${COMPANY_IP:-}"
DEV_HOST_IP="${DEV_HOST_IP:-}"; DEV_HOST2_IP="${DEV_HOST2_IP:-}"; TAILSCALE_HOST_IP="${TAILSCALE_HOST_IP:-}"
DEV_CONTAINER_IP="${DEV_CONTAINER_IP:-}"; NAS_IP="${NAS_IP:-}"; SSH_USER="${SSH_USER:-}"


NAS_HOST="${NAS_HOST:-${NAS_IP}}"
NAS_PORT="${NAS_PORT:-2221}"
NAS_USER="${NAS_USER:-lizhi.lu}"
SERVER_URL="${SERVER_URL:-https://${TENCENT_IP}:8443}"
AUTHKEY="${1:-}"
HOSTNAME="ts-nas-hs"
SOCKS_PORT=1080

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() {
	echo -e "${RED}[✗]${NC} $*" >&2
	exit 1
}

[ -n "$AUTHKEY" ] || err "用法: bash $0 <headscale preauthkey>"

SSH="ssh -o ConnectTimeout=10 -o BatchMode=yes -p ${NAS_PORT} ${NAS_USER}@${NAS_HOST}"
SCP="scp -P ${NAS_PORT}"

info "1/5 上传 CA 证书到 NAS 容器..."
scp -q -P ${NAS_PORT} "$(dirname "$0")/../../data/headscale-ca.crt" "${NAS_USER}@${NAS_HOST}:/tmp/headscale-ca.crt" 2>/dev/null ||
	$SSH 'test -f /tmp/headscale-ca.crt' || err "请先将 CA 放到 /tmp/headscale-ca.crt"

info "2/5 信任 CA..."
$SSH 'sudo cp /tmp/headscale-ca.crt /usr/local/share/ca-certificates/headscale-ca.crt && sudo update-ca-certificates' >/dev/null 2>&1

info "3/5 安装 tailscale（如缺失）..."
$SSH 'command -v tailscale >/dev/null 2>&1 || {
    curl -fsSL --max-time 60 https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    curl -fsSL --max-time 60 https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y tailscale
}' >/dev/null 2>&1

info "4/5 启动 tailscaled（userspace + SOCKS5 :${SOCKS_PORT}）..."
$SSH "sudo pkill -9 tailscaled 2>/dev/null; sleep 2
sudo bash -c 'setsid nohup tailscaled --tun=userspace-networking --socks5-server=0.0.0.0:${SOCKS_PORT} --state=/var/lib/tailscale/tailscaled.state >/var/log/tailscaled.log 2>&1 < /dev/null &'
sleep 5" >/dev/null

info "5/5 加入 headscale..."
$SSH "sudo tailscale up --reset --force-reauth --login-server='${SERVER_URL}' --authkey='${AUTHKEY}' --hostname='${HOSTNAME}' --accept-dns=false"

echo ""
info "部署完成！节点: ${HOSTNAME} = $($SSH 'tailscale ip -4' 2>/dev/null | head -1)"
cat <<EOF

  局域网设备使用方式（Mac 示例）:
    # SOCKS5 代理指向 NAS:
    export ALL_PROXY="socks5h://${NAS_HOST}:${SOCKS_PORT}"

    # 经代理 SSH 到公司服务器 (tailnet IP):
    ssh -o ProxyCommand="nc -X 5 -x ${NAS_HOST}:${SOCKS_PORT} %h %p" ${SSH_USER}@${COMPANY_IP}

  验证:
    ssh ${NAS_USER}@${NAS_HOST} -p ${NAS_PORT} 'tailscale status'
EOF
