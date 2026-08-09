#!/usr/bin/env bash
# ============================================================
# join-client.sh — 将本机 tailscale 客户端接入 headscale 网络
#
# 功能:
#   - 信任 headscale 自签 CA（macOS Keychain / Linux ca-certificates）
#   - 安装 tailscale 客户端（如缺失）
#   - tailscale up 指向自建控制面
#
# 用法:
#   sudo bash join-client.sh \
#       --server https://62.234.69.194:8443 \
#       --authkey tskey-auth-XXX \
#       --hostname mac-mini \
#       --ca /path/to/ca.crt
# ============================================================
set -euo pipefail

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

SERVER=""
AUTHKEY=""
HOSTNAME="$(hostname -s 2>/dev/null || echo node)"
CA_PATH=""

while [ $# -gt 0 ]; do
	case "$1" in
	--server)
		SERVER="$2"
		shift 2
		;;
	--authkey)
		AUTHKEY="$2"
		shift 2
		;;
	--hostname)
		HOSTNAME="$2"
		shift 2
		;;
	--ca)
		CA_PATH="$2"
		shift 2
		;;
	-h | --help)
		echo "用法: sudo bash $0 --server URL --authkey KEY [--hostname NAME] [--ca CA.crt]"
		exit 0
		;;
	*) err "未知参数: $1" ;;
	esac
done

[ -n "$SERVER" ] || err "缺少 --server（headscale 控制面 URL）"
[ -n "$AUTHKEY" ] || err "缺少 --authkey（预授权密钥，在控制面执行 headscale preauthkeys create）"

OS="$(uname -s)"

# ── 1. 信任 CA ───────────────────────────────────────────────────────────
trust_ca() {
	[ -n "$CA_PATH" ] || {
		warn "未提供 --ca，跳过 CA 信任（自签证书会 TLS 失败）"
		return
	}
	[ -f "$CA_PATH" ] || err "CA 文件不存在: $CA_PATH"
	case "$OS" in
	Darwin)
		info "信任 CA 到 macOS Keychain ..."
		security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_PATH"
		;;
	Linux)
		info "信任 CA 到 ca-certificates ..."
		cp "$CA_PATH" /usr/local/share/ca-certificates/headscale-ca.crt
		update-ca-certificates
		;;
	esac
	info "CA 信任完成"
}

# ── 2. 安装 tailscale（如缺失）──────────────────────────────────────────
install_tailscale() {
	if command -v tailscale >/dev/null 2>&1; then
		info "tailscale 已安装: $(tailscale version 2>/dev/null | head -1)"
		return
	fi
	case "$OS" in
	Darwin)
		info "brew 安装 tailscale（需要 GUI 登录一次）..."
		brew install --cask tailscale
		open -a Tailscale || true
		;;
	Linux)
		info "安装 tailscale (apt) ..."
		curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarch.deb -o /tmp/tailscale.deb 2>/dev/null ||
			curl -fsSL https://tailscale.com/install.sh | sh
		[ -f /tmp/tailscale.deb ] && apt-get install -y /tmp/tailscale.deb
		rm -f /tmp/tailscale.deb
		systemctl enable --now tailscaled
		;;
	esac
	command -v tailscale >/dev/null 2>&1 || err "tailscale 安装失败"
}

# ── 3. 加入 headscale ───────────────────────────────────────────────────
join() {
	info "接入控制面 ${SERVER} (hostname=${HOSTNAME}) ..."
	tailscale up --login-server="$SERVER" --authkey="$AUTHKEY" --hostname="$HOSTNAME"
	info "加入成功！"
}

# ── 主流程 ───────────────────────────────────────────────────────────────
trust_ca
install_tailscale
join

echo ""
echo "=== 本机 Tailscale 状态 ==="
tailscale status 2>/dev/null || true
echo ""
echo "=== 本机 Tailscale IP ==="
tailscale ip -4 2>/dev/null && info "已接入 headscale 网络 ✓"
echo ""
echo "验证其他节点: tailscale ping <对端IP>"
