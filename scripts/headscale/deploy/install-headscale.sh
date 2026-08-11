#!/usr/bin/env bash
# ============================================================
# install-headscale.sh — headscale 控制服务器部署
#
# 功能:
#   - 下载安装 headscale (Ubuntu: .deb / macOS: brew)
#   - 生成自签 CA + 服务器证书 (SAN=公网 IP)
#   - 渲染配置 (内置 DERP + STUN)
#   - systemd / brew services 启动
#   - 创建用户
#
# 用法:
#   sudo bash install-headscale.sh \
#       --server-url https://${TENCENT_IP}:8443 \
#       --listen-addr 0.0.0.0:8443 \
#       --derp-ipv4 ${TENCENT_IP} \
#       --user playground \
#       --version 0.29.3
# ============================================================
set -euo pipefail
# 基础设施地址（gitignored: scripts/data/hosts.cfg, 模板 hosts.cfg.example）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
	for _d in "$(dirname "${BASH_SOURCE[0]}")/../../data" "$(dirname "${BASH_SOURCE[0]}")/../data"; do
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../templates/config.yaml.tmpl"

# ── 默认值 ────────────────────────────────────────────────────────────────
VERSION="0.29.3"
SERVER_URL="https://${TENCENT_IP}:8443"
LISTEN_ADDR="0.0.0.0:8443"
DERP_IPV4=""
USER_NAME="playground"
DATA_DIR="/var/lib/headscale"
CONFIG_DIR="/etc/headscale"

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

# ── 参数解析 ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
	--server-url)
		SERVER_URL="$2"
		shift 2
		;;
	--listen-addr)
		LISTEN_ADDR="$2"
		shift 2
		;;
	--derp-ipv4)
		DERP_IPV4="$2"
		shift 2
		;;
	--user)
		USER_NAME="$2"
		shift 2
		;;
	--version)
		VERSION="$2"
		shift 2
		;;
	--data-dir)
		DATA_DIR="$2"
		shift 2
		;;
	--config-dir)
		CONFIG_DIR="$2"
		shift 2
		;;
	-h | --help)
		echo "用法: sudo bash $0 [--server-url URL] [--listen-addr IP:PORT] [--derp-ipv4 IP] [--user NAME] [--version X.Y.Z]"
		exit 0
		;;
	*) err "未知参数: $1" ;;
	esac
done

# 从 server-url 推导公网 IP（DERP map 用）
if [ -z "$DERP_IPV4" ]; then
	DERP_IPV4="$(echo "$SERVER_URL" | sed -E 's|^https?://([^:/]+).*|\1|')"
fi

# ── 前置检查 ──────────────────────────────────────────────────────────────
[ -f "$TEMPLATE" ] || err "模板不存在: ${TEMPLATE}（脚本需从 scripts/headscale/ 目录运行）"
command -v curl >/dev/null || err "缺少 curl"
command -v openssl >/dev/null || err "缺少 openssl"

OS="$(uname -s)"
case "$OS" in
Linux) ;;
Darwin)
	DATA_DIR="$(brew --prefix 2>/dev/null)/var/lib/headscale" || DATA_DIR="/opt/homebrew/var/lib/headscale"
	CONFIG_DIR="$(brew --prefix 2>/dev/null)/etc/headscale" || CONFIG_DIR="/opt/homebrew/etc/headscale"
	;;
*) err "不支持的 OS: $OS" ;;
esac

mkdir -p "$DATA_DIR/certs" "$CONFIG_DIR"

# ── 1. 安装 headscale ────────────────────────────────────────────────────
install_headscale() {
	if command -v headscale >/dev/null 2>&1; then
		warn "headscale 已安装: $(headscale version 2>/dev/null | head -1)"
		return
	fi
	case "$OS" in
	Linux)
		ARCH="$(uname -m)"
		case "$ARCH" in
		x86_64 | amd64) DEB_ARCH="amd64" ;;
		aarch64 | arm64) DEB_ARCH="arm64" ;;
		*) err "不支持的架构: $ARCH" ;;
		esac
		DEB="headscale_${VERSION}_linux_${DEB_ARCH}.deb"
		# 本地已有 deb 则直接使用（国内服务器常无法访问 GitHub）
		if [ -f "/tmp/${DEB}" ]; then
			info "使用本地 deb: /tmp/${DEB}"
		else
			info "下载 ${DEB} ..."
			curl -fsSL --connect-timeout 10 --max-time 300 -o "/tmp/${DEB}" "https://github.com/juanfont/headscale/releases/download/v${VERSION}/${DEB}" ||
				err "GitHub 下载失败。请手动下载后放到 /tmp/${DEB} 再重跑本脚本"
		fi
		info "安装 ${DEB} ..."
		DEBIAN_FRONTEND=noninteractive apt-get install -y "/tmp/${DEB}"
		rm -f "/tmp/${DEB}"
		;;
	Darwin)
		info "brew 安装 headscale-cli ..."
		brew install headscale-cli
		;;
	esac
	command -v headscale >/dev/null 2>&1 || err "headscale 安装失败"
	info "headscale 版本: $(headscale version 2>/dev/null | head -1)"
}

# ── 2. 生成自签 CA + 服务器证书 ──────────────────────────────────────────
gen_certs() {
	local CERT_DIR="$DATA_DIR/certs"
	if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/ca.crt" ]; then
		warn "证书已存在，跳过生成（如需重生成: rm -rf ${CERT_DIR}）"
		return
	fi
	info "生成自签 CA + 服务器证书 (SAN=IP:${DERP_IPV4}) ..."
	# CA
	openssl genrsa -out "$CERT_DIR/ca.key" 3072 2>/dev/null
	openssl req -x509 -new -key "$CERT_DIR/ca.key" -sha256 -days 3650 \
		-subj "/CN=headscale-ca" -out "$CERT_DIR/ca.crt"
	# 服务器证书
	openssl genrsa -out "$CERT_DIR/server.key" 3072 2>/dev/null
	openssl req -new -key "$CERT_DIR/server.key" \
		-subj "/CN=${DERP_IPV4}" -out "$CERT_DIR/server.csr"
	printf "subjectAltName=IP:%s\n" "$DERP_IPV4" >"$CERT_DIR/san.cnf"
	openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" \
		-CAkey "$CERT_DIR/ca.key" -CAcreateserial -days 3650 -sha256 \
		-extfile "$CERT_DIR/san.cnf" -out "$CERT_DIR/server.crt"
	rm -f "$CERT_DIR/server.csr"
	chmod 600 "$CERT_DIR/ca.key" "$CERT_DIR/server.key"
	info "证书生成完成: ${CERT_DIR}/ca.crt（分发给各客户端信任）"
}

# ── 3. 渲染配置 ──────────────────────────────────────────────────────────
render_config() {
	local SOCKET_PATH
	case "$OS" in
	Linux) SOCKET_PATH="/var/run/headscale/headscale.sock" ;;
	Darwin) SOCKET_PATH="${DATA_DIR}/headscale.sock" ;;
	esac
	info "渲染配置 → ${CONFIG_DIR}/config.yaml"
	sed -e "s|__SERVER_URL__|${SERVER_URL}|g" \
		-e "s|__LISTEN_ADDR__|${LISTEN_ADDR}|g" \
		-e "s|__DATA_DIR__|${DATA_DIR}|g" \
		-e "s|__DERP_IPV4__|${DERP_IPV4}|g" \
		-e "s|__SOCKET_PATH__|${SOCKET_PATH}|g" \
		"$TEMPLATE" >"${CONFIG_DIR}/config.yaml"
	chmod 644 "${CONFIG_DIR}/config.yaml"
}

# ── 4. 启动服务 ──────────────────────────────────────────────────────────
start_service() {
	case "$OS" in
	Linux)
		mkdir -p /var/run/headscale
		systemctl daemon-reload
		systemctl enable headscale
		systemctl restart headscale
		sleep 2
		systemctl is-active headscale >/dev/null 2>&1 || {
			journalctl -u headscale -n 30 --no-pager >&2
			err "headscale 启动失败"
		}
		info "headscale 已启动 (systemd)"
		;;
	Darwin)
		# 检查 brew 是否有 service；无则 launchctl 手动托管
		if brew services list 2>/dev/null | grep -q headscale; then
			brew services start headscale-cli 2>/dev/null || brew services start headscale 2>/dev/null
		else
			warn "brew services 不支持 headscale，使用 nohup 托管"
			nohup headscale serve -c "${CONFIG_DIR}/config.yaml" \
				>"${DATA_DIR}/headscale.log" 2>&1 &
		fi
		info "headscale 已启动 (macOS)"
		;;
	esac
}

# ── 5. 创建用户 ──────────────────────────────────────────────────────────
create_user() {
	if headscale users list 2>/dev/null | grep -qw "$USER_NAME"; then
		warn "用户 ${USER_NAME} 已存在"
	else
		info "创建用户 ${USER_NAME} ..."
		headscale users create "$USER_NAME"
	fi
	# 打印用户 ID（0.29+ 的 preauthkey 需要 -u <用户ID>）
	headscale users list -o json 2>/dev/null | python3 -c "
import json,sys
for u in json.load(sys.stdin):
    if u.get('name') == '$USER_NAME':
        print(f'[i] 用户 {u[\"name\"]} ID={u[\"id\"]}')" || true
}

# ── 主流程 ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || err "请用 root 运行（sudo bash $0 ...）"
install_headscale
gen_certs
render_config
start_service
sleep 2
create_user

cat <<EOF

==============================
  headscale 部署完成
==============================
  控制面 URL:   ${SERVER_URL}
  监听地址:     ${LISTEN_ADDR}
  数据目录:     ${DATA_DIR}
  配置:         ${CONFIG_DIR}/config.yaml
  CA 证书:      ${DATA_DIR}/certs/ca.crt   ← 分发给所有客户端信任
  用户:         ${USER_NAME}

  防火墙/安全组需放行:
    TCP ${LISTEN_ADDR##*:}   (控制面 + DERP)
    UDP 3478                 (STUN)

  下一步:
    1. 生成预授权密钥（注意 0.29+ 用用户 ID）:
       sudo headscale users list            # 找到 ${USER_NAME} 的 ID
       sudo headscale preauthkeys create -u <用户ID> --expiration 24h --reusable
    2. 在客户端信任 CA 并加入:
       sudo bash nodes/join-client.sh --server ${SERVER_URL} \\
           --authkey hskey-auth-XXX --hostname <节点名> --ca ca.crt
==============================
EOF
