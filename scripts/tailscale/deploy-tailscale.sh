#!/usr/bin/env bash
# ============================================================
# deploy-tailscale.sh — 通用 Tailscale 节点部署脚本
# 基于 playground + docker 工程资源
#
# 安全设计：
#   1. 密钥通过 /dev/shm (tmpfs) 临时文件传入容器，不留磁盘
#   2. 容器内入口脚本认证后立即 unset 密钥、删除临时文件
#   3. 使用持久化 volume 保存 tailscale state，重启不需再次传入密钥
#   4. 推荐在 Tailscale 控制台使用一次性(ephemeral) auth key
#
# 用法:
#   ./deploy-tailscale.sh basic   -n <hostname>         # 基础节点
#   ./deploy-tailscale.sh exit    -n <hostname>         # Exit Node
#   ./deploy-tailscale.sh subnet  -n <hostname> -r <网段>  # Subnet Router
#
# 环境变量（从 data/vpn.cfg 自动读取，也可手动覆盖）:
#   TAILSCALE_AUTH_KEY  认证密钥
#   TAILSCALE_HOSTNAME  节点主机名
#   TAILSCALE_SERVER    自定义登录服务器（用于 Headscale 等）
#   ADVERTISE_ROUTES    subnet 模式要宣告的路由
#   ACCEPT_ROUTES       设为 true 则接受路由
# ============================================================
#   TS_IMAGE            容器映像（默认: tailscale/tailscale:stable）

set -euo pipefail

# ===================== 配置 =====================
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYGROUND_DIR="$(cd "${SCRIPTS_DIR}/../.." && pwd)"
TEMPLATES_DIR="${SCRIPTS_DIR}/templates"
VPN_CFG="${PLAYGROUND_DIR}/scripts/docker/data/vpn.cfg"
TS_IMAGE="${TS_IMAGE:-tailscale/tailscale:stable}"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ===================== 用法 =====================
usage() {
    cat <<EOF
用法: $(basename "$0") <mode> [选项]

模式:
  basic   部署基础 Tailscale 节点（仅加入 tailnet）
  exit    部署 Exit Node（宣告为出口节点）
  subnet  部署 Subnet Router（宣告子网路由，需 -r 参数）

选项:
  -n <hostname>  节点主机名（默认: ts-<本机hostname>）
  -r <网段>      宣告的路由，如 172.30.0.0/16（subnet 模式必需）
  -a             --accept-routes（接受 tailnet 路由通告）

示例:
  $(basename "$0") basic
  $(basename "$0") basic -n my-aliyun
  $(basename "$0") exit -n aliyun-exit
  $(basename "$0") subnet -n aliyun-router -r 172.30.0.0/16
  TAILSCALE_SERVER=https://headscale.example.com $(basename "$0") basic -n my-node
EOF
    exit 1
}

# ===================== 参数解析 =====================
MODE="${1:-}"
[ -z "$MODE" ] && usage
shift

HOSTNAME=""
ADVERTISE_ROUTES=""
ACCEPT_ROUTES=""

while getopts "n:r:ah" opt; do
    case $opt in
        n) HOSTNAME="$OPTARG" ;;
        r) ADVERTISE_ROUTES="$OPTARG" ;;
        a) ACCEPT_ROUTES="true" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ===================== 前置检查 =====================
command -v docker &>/dev/null || err "Docker not found. Please install Docker first."

[ -f "$VPN_CFG" ] || err "VPN config not found: ${VPN_CFG}"
[ -d "$TEMPLATES_DIR" ] || err "Templates directory not found: ${TEMPLATES_DIR}"

# 读取密钥
AUTH_KEY=$(grep "^TAILSCALE_AUTH_KEY=" "$VPN_CFG" | head -1 | cut -d= -f2-)
[ -n "$AUTH_KEY" ] || err "TAILSCALE_AUTH_KEY not found in ${VPN_CFG}"

# 生成 hostname
if [ -z "$HOSTNAME" ]; then
    HOSTNAME="ts-$(hostname -s 2>/dev/null || echo 'node')"
fi

# ===================== 模式配置 =====================
case "$MODE" in
    basic)
        ENTRYPOINT="entrypoint.sh"
        STATE_VOLUME="ts-${HOSTNAME}-state"
        ;;
    exit)
        ENTRYPOINT="entrypoint.sh"
        STATE_VOLUME="ts-${HOSTNAME}-state"
        ADVERTISE_ROUTES="${ADVERTISE_ROUTES:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
        ACCEPT_ROUTES="true"
        ;;
    subnet)
        ENTRYPOINT="entrypoint.sh"
        STATE_VOLUME="ts-${HOSTNAME}-state"
        [ -n "$ADVERTISE_ROUTES" ] || err "Subnet router requires -r <ROUTES> (e.g. -r 172.30.0.0/16)"
        ;;
    *)
        err "Unknown mode: ${MODE}. Use: basic | exit | subnet"
        ;;
esac

# ===================== 部署 =====================
CONTAINER_NAME="ts-${HOSTNAME}"

# 自动清理已存在的同名容器（参考 derp-deploy.sh 模式）
if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    warn "Container '${CONTAINER_NAME}' already exists, removing..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
    info "Removed old container."
fi


# 创建持久化 state volume
docker volume inspect "$STATE_VOLUME" &>/dev/null || \
    docker volume create "$STATE_VOLUME" >/dev/null
info "State volume '${STATE_VOLUME}' ready."

# ---- 密钥安全传递 ----
# 写入 /dev/shm (tmpfs，内存中，不留磁盘)
# 作为只读文件挂载到容器内，入口脚本读取后立即删除
TS_KEYFILE=$(mktemp -p /dev/shm ts-authkey-XXXXXX 2>/dev/null || mktemp -p /tmp ts-authkey-XXXXXX)
echo -n "$AUTH_KEY" > "$TS_KEYFILE"
trap 'rm -f "$TS_KEYFILE"' EXIT INT TERM

# ---- 构建 docker run 参数 ----
DOCKER_ARGS=(
    -d
    --name "${CONTAINER_NAME}"
    --restart always
    --network host
    --device /dev/net/tun:/dev/net/tun
    --cap-add NET_ADMIN
    -e "TAILSCALE_HOSTNAME=${HOSTNAME}"
    -e "TAILSCALE_STATE_ARG=/var/lib/tailscale/tailscaled.state"
    -e "ADVERTISE_ROUTES=${ADVERTISE_ROUTES:-}"
    -e "ACCEPT_ROUTES=${ACCEPT_ROUTES:-}"
    -v "${STATE_VOLUME}:/var/lib/tailscale"
    -v "${TEMPLATES_DIR}/${ENTRYPOINT}:/entrypoint.sh:ro"
    -v "${TS_KEYFILE}:/dev/shm/authkey:ro"
    --entrypoint /entrypoint.sh
)
# TAILSCALE_SERVER 可选传递
[ -n "${TAILSCALE_SERVER:-}" ] && DOCKER_ARGS+=(-e "TAILSCALE_SERVER=${TAILSCALE_SERVER}")

# ===================== 执行 =====================
cat <<EOF

==============================
  Tailscale 部署概要
==============================
  节点名称:   ${CONTAINER_NAME}
  模式:       ${MODE}
  Hostname:   ${HOSTNAME}
  映像:       tailscale/tailscale:stable
  数据卷:     ${STATE_VOLUME}
EOF
[ -n "$ADVERTISE_ROUTES" ] && echo "  宣告路由:   ${ADVERTISE_ROUTES}"
[ -n "${ACCEPT_ROUTES}" ]  && echo "  接受路由:   yes"
echo ""

# ---- 拉取映像 ----
echo "Pulling image: ${TS_IMAGE}..."
if docker pull "${TS_IMAGE}" &>/dev/null; then
    info "Image '${TS_IMAGE}' ready."
else
    warn "Failed to pull image: ${TS_IMAGE}"
    echo ""
    echo "  Docker Hub 从中国访问较慢，建议配置镜像加速器:"
    echo "    sudo tee /etc/docker/daemon.json <<'EOF'"
    echo "    { \"registry-mirrors\": [\"https://docker.m.daocloud.io\",\"https://docker.nju.edu.cn\"] }"
    echo '    EOF'
    echo '    sudo systemctl daemon-reload && sudo systemctl restart docker'
    echo ""
    warn "然后重新运行: $(basename "$0") ${MODE} -n ${HOSTNAME}"
    echo ""
    err "或手动拉取镜像: docker pull ${TS_IMAGE}"
fi
echo ""

# 启动容器
docker run "${DOCKER_ARGS[@]}" "${TS_IMAGE}"

# 立即删除宿主机的密钥临时文件（/dev/shm）
rm -f "$TS_KEYFILE"
trap - EXIT INT TERM

echo ""
info "Container '${CONTAINER_NAME}' started."

# ---- 等待启动 & 验证（参考 derp-deploy.sh 的验证模式） ----
echo "Waiting for startup (5s)..."
sleep 5
echo ""

echo "=== Container status ==="
docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo ""
echo "=== Recent logs ==="
docker logs "${CONTAINER_NAME}" --tail 10 2>&1

echo ""
echo "=== Process check ==="
docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -E 'tailscaled|tailscale' || echo "  (container still starting)"

echo ""
echo "=== Tailscale status ==="
docker exec "${CONTAINER_NAME}" tailscale status 2>/dev/null || \
    echo "  (not ready yet, check: docker logs ${CONTAINER_NAME})"

echo ""
echo "=== Tailscale IP ==="
docker exec "${CONTAINER_NAME}" tailscale ip -4 2>/dev/null && \
    info "Node '${HOSTNAME}' joined tailnet successfully!"

# ===================== 后续操作提示 =====================
cat <<EOF

==============================
  部署完成
==============================

  常用命令:
    docker logs ${CONTAINER_NAME}                       查看日志
    docker exec ${CONTAINER_NAME} tailscale status       查看状态
    docker exec ${CONTAINER_NAME} tailscale ip -4        查看 TS IP
    docker rm -f ${CONTAINER_NAME}                       删除节点

  密钥安全提醒:
    - 认证密钥保存在: ${VPN_CFG}
    - 确认节点成功加入 tailnet 后，可手动从 ${VPN_CFG} 删除该密钥
    - 容器认证完成后容器内部已清除密钥
    - 本脚本不会自动修改 ${VPN_CFG}

EOF
