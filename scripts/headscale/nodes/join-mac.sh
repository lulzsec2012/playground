#!/usr/bin/env bash
# ============================================================
# join-mac.sh — Mac 重启后一键加入 headscale（供重启后手动运行）
#
# 背景:
#   Mac 网络扩展(Network Extension)被反复 kill 后状态损坏，
#   重启 Mac 后扩展全新加载，会读取已写入的 admin 域 CA 信任。
#
# 用法（重启后执行）:
#   HEADSCALE_AUTHKEY=hskey-xxx bash scripts/headscale/join-mac.sh
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


SERVER="${HEADSCALE_SERVER:-https://${TENCENT_IP}:8443}"
AUTHKEY="${HEADSCALE_AUTHKEY:-}"
HOSTNAME="mac-mini"
CA_CERT="/tmp/headscale-ca.crt"

[ -n "$AUTHKEY" ] || {
	echo "❌ 缺少 HEADSCALE_AUTHKEY（在 headscale 控制面生成: headscale preauthkeys create）"
	exit 1
}

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

# ── 0. 确保 CA 文件存在 ──────────────────────────────────────────────
if [ ! -f "$CA_CERT" ]; then
	warn "CA 文件缺失，尝试从腾讯云拉取..."
	scp ${SSH_USER}@${TENCENT_IP}:/tmp/headscale-ca.crt "$CA_CERT" 2>/dev/null ||
		ssh ${SSH_USER}@${TENCENT_IP} 'sudo cat /var/lib/headscale/certs/ca.crt' >"$CA_CERT"
fi
[ -f "$CA_CERT" ] || err "无法获取 CA 证书"

# ── 1. 确认 admin 域信任 ─────────────────────────────────────────────
echo "=== 检查 admin 域 CA 信任 ==="
TRUST_COUNT=$(security dump-trust-settings -d 2>/dev/null | grep -A4 "headscale-ca" | grep -c "Policy OID" || true)
if [ "${TRUST_COUNT:-0}" -ge 1 ]; then
	info "admin 域信任已生效（重启后保留）"
else
	warn "admin 域信任缺失，尝试重新写入（需输入密码）..."
	osascript -e "do shell script \"security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain $CA_CERT\" with administrator privileges" ||
		err "信任写入失败，请手动执行: sudo security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain $CA_CERT"
fi

# ── 2. 确认 tailscale app 运行 ───────────────────────────────────────
echo "=== 检查 Tailscale app ==="
if ! rtk_ps() { :; } 2>/dev/null; then :; fi
pgrep -f "Tailscale.app/Contents/MacOS/Tailscale" >/dev/null || open -a Tailscale
sleep 8

# ── 3. 加入 headscale ────────────────────────────────────────────────
echo "=== 加入 headscale ($SERVER) ==="
tailscale up --reset --force-reauth \
	--login-server="$SERVER" \
	--authkey="$AUTHKEY" \
	--hostname="$HOSTNAME" \
	--accept-dns=false
info "加入成功！"

# ── 4. 验证 ──────────────────────────────────────────────────────────
echo ""
echo "=== 本机 Tailscale 状态 ==="
tailscale status | head -6
echo ""
echo "=== 本机 IP ==="
tailscale ip -4 && info "已接入 headscale 网络 ✓"
echo ""
echo "验证对端: tailscale ping ${COMPANY_IP} (公司服务器)"
echo "          tailscale ping 100.64.0.2 (腾讯云)"
