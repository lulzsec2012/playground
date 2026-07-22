#!/usr/bin/env bash
# deploy-couchdb.sh — 部署 CouchDB 用于 Obsidian Self-hosted LiveSync
#
# 用法:
#   bash deploy-couchdb.sh                                  # 部署到本机
#   bash deploy-couchdb.sh --host 62.234.69.194             # 部署到远程服务器
#   bash deploy-couchdb.sh --host tencent                   # 通过 SSH alias
#   bash deploy-couchdb.sh --password your-password         # 指定数据库密码
#   bash deploy-couchdb.sh --port 5984                      # 指定端口
#   bash deploy-couchdb.sh --remove                         # 卸载
#   bash deploy-couchdb.sh --status                         # 查看状态
#   bash deploy-couchdb.sh --help
#
# 环境变量:
#   COUCHDB_USER       — CouchDB 管理员用户名 (默认: admin)
#   COUCHDB_PASSWORD   — CouchDB 管理员密码 (默认: 自动生成)
#   COUCHDB_PORT       — 映射端口 (默认: 5984)
#   COUCHDB_DATA_DIR   — 数据持久化目录 (默认: /opt/couchdb/data)
#
# 前置条件:
#   - 远程部署: SSH 可登录目标服务器
#   - 本机部署: Docker 已安装
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── 默认配置 ──────────────────────────────────────────────────────────────
COUCHDB_USER="${COUCHDB_USER:-admin}"
COUCHDB_PASSWORD="${COUCHDB_PASSWORD:-}"
COUCHDB_PORT="${COUCHDB_PORT:-5984}"
COUCHDB_DATA_DIR="${COUCHDB_DATA_DIR:-/opt/couchdb/data}"
REMOTE_HOST=""
REMOTE_SSH=""
DO_REMOVE=false
DO_STATUS=false

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $1"; }
error() { echo -e "${RED}  [ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}  >>>${NC} ${BOLD}$1${NC}"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }

# ── 参数解析 ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) shift; REMOTE_HOST="$1" ;;
    --password) shift; COUCHDB_PASSWORD="$1" ;;
    --port) shift; COUCHDB_PORT="$1" ;;
    --remove) DO_REMOVE=true ;;
    --status) DO_STATUS=true ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^#//; s/^ //'
      exit 0 ;;
    *) error "未知参数: $1"; exit 1 ;;
  esac
  shift
done

# ── 远程执行封装 ──────────────────────────────────────────────────────────
if [[ -n "$REMOTE_HOST" ]]; then
  # 检查是否是 SSH alias (不含 . 和 @ 的当作 alias)
  if [[ "$REMOTE_HOST" != *"@"* ]] && [[ "$REMOTE_HOST" != *"."* ]]; then
    REMOTE_SSH="$REMOTE_HOST"
  else
    REMOTE_SSH="ssh ubuntu@${REMOTE_HOST}"
  fi
  REMOTE_PREFIX="$REMOTE_SSH"
  LOCAL_MODE=false
  info "远程模式: $REMOTE_SSH"
else
  LOCAL_MODE=true
  info "本机模式"
fi

run_remote() {
  if $LOCAL_MODE; then
    eval "$@"
  else
    $REMOTE_SSH "bash -s" <<< "$@"
  fi
}

# ── 自动生成密码 ──────────────────────────────────────────────────────────
if [[ -z "$COUCHDB_PASSWORD" ]]; then
  COUCHDB_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 2>/dev/null || echo "couchdb-$(date +%s)")
fi

# ══════════════════════════════════════════════════════════════════════════
# 状态查看
# ══════════════════════════════════════════════════════════════════════════

if $DO_STATUS; then
  echo ""
  echo -e "${BOLD}CouchDB 状态${NC}"
  echo "────────────────────────────────"

  if $LOCAL_MODE; then
    docker ps --filter name=couchdb --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  容器未运行"
    curl -sS --max-time 3 http://127.0.0.1:${COUCHDB_PORT}/ 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(f'  CouchDB: {d.get(\"version\",\"?\")}')
except: print('  无法连接 CouchDB')
" 2>/dev/null || echo "  无法连接 CouchDB"
  else
    $REMOTE_SSH "docker ps --filter name=couchdb --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null || echo "  容器未运行"
    $REMOTE_SSH "curl -sS --max-time 3 http://127.0.0.1:${COUCHDB_PORT}/" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(f'  CouchDB: {d.get(\"version\",\"?\")}')
except: print('  无法连接 CouchDB')
" 2>/dev/null || echo "  无法连接 CouchDB"
  fi
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# 卸载
# ══════════════════════════════════════════════════════════════════════════

if $DO_REMOVE; then
  step "卸载 CouchDB"
  if $LOCAL_MODE; then
    docker stop couchdb 2>/dev/null || true
    docker rm couchdb 2>/dev/null || true
    sudo rm -rf "$COUCHDB_DATA_DIR"
  else
    $REMOTE_SSH "docker stop couchdb 2>/dev/null; docker rm couchdb 2>/dev/null; sudo rm -rf $COUCHDB_DATA_DIR"
  fi
  ok "CouchDB 已卸载"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
# 1. 检查 Docker
# ══════════════════════════════════════════════════════════════════════════

step "检查 Docker"

if $LOCAL_MODE; then
  if ! command -v docker &>/dev/null; then
    error "本机未安装 Docker"
    exit 1
  fi
  ok "Docker $(docker --version)"
else
  if ! $REMOTE_SSH "command -v docker" &>/dev/null; then
    warn "远程服务器未安装 Docker，尝试安装..."
    $REMOTE_SSH "curl -fsSL https://get.docker.com | sudo sh" || {
      error "Docker 安装失败，请手动安装后重试"
      exit 1
    }
    $REMOTE_SSH "sudo usermod -aG docker ubuntu" || true
  fi
  ok "远程 Docker 就绪"
fi

# ══════════════════════════════════════════════════════════════════════════
# 2. 创建数据目录
# ══════════════════════════════════════════════════════════════════════════

step "创建数据目录"

# CouchDB 容器内以 UID 5984 (couchdb 用户) 运行
# 数据目录必须可被该用户写入
COUCHDB_UID=5984

if $LOCAL_MODE; then
  sudo mkdir -p "$COUCHDB_DATA_DIR"
  sudo chown ${COUCHDB_UID}:${COUCHDB_UID} "$COUCHDB_DATA_DIR"
  ok "数据目录: $COUCHDB_DATA_DIR (owner UID ${COUCHDB_UID})"
else
  $REMOTE_SSH "sudo mkdir -p $COUCHDB_DATA_DIR && sudo chown ${COUCHDB_UID}:${COUCHDB_UID} $COUCHDB_DATA_DIR"
  ok "数据目录: $COUCHDB_DATA_DIR (owner UID ${COUCHDB_UID})"
fi

# ══════════════════════════════════════════════════════════════════════════
# 3. 启动 CouchDB 容器
# ══════════════════════════════════════════════════════════════════════════

step "启动 CouchDB 容器"

DOCKER_CMD="docker run -d \
  --name couchdb \
  --restart=always \
  -p ${COUCHDB_PORT}:5984 \
  -e COUCHDB_USER=${COUCHDB_USER} \
  -e COUCHDB_PASSWORD=${COUCHDB_PASSWORD} \
  -v ${COUCHDB_DATA_DIR}:/opt/couchdb/data \
  couchdb:latest"

if $LOCAL_MODE; then
  # 停止旧容器
  docker stop couchdb 2>/dev/null || true
  docker rm couchdb 2>/dev/null || true
  eval "$DOCKER_CMD"
  ok "CouchDB 容器已启动"
else
  $REMOTE_SSH "docker stop couchdb 2>/dev/null; docker rm couchdb 2>/dev/null; $DOCKER_CMD"
  ok "CouchDB 容器已启动 (远程)"
fi

# 等待启动
sleep 3

# ══════════════════════════════════════════════════════════════════════════
# 4. 配置 CORS
# ══════════════════════════════════════════════════════════════════════════

step "配置 CORS"

CORS_INI="[cors]
origins = app://obsidian.md, capacitor://localhost, http://localhost
credentials = true
methods = GET, PUT, POST, HEAD, DELETE
headers = accept, authorization, content-type, origin, referer, x-couchdb-command
max_age = 3600"

if $LOCAL_MODE; then
  docker exec couchdb bash -c "echo '$CORS_INI' >> /opt/couchdb/etc/local.ini"
  docker restart couchdb
  ok "CORS 已配置"
else
  $REMOTE_SSH "docker exec couchdb bash -c \"echo '$CORS_INI' >> /opt/couchdb/etc/local.ini\"; docker restart couchdb"
  ok "CORS 已配置 (远程)"
fi

sleep 2

# ══════════════════════════════════════════════════════════════════════════
# 5. 验证
# ══════════════════════════════════════════════════════════════════════════

step "验证"

if $LOCAL_MODE; then
  VERSION=$(curl -sS --max-time 5 "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}/" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo "失败")
  ok "CouchDB 版本: $VERSION"
  echo ""
  echo -e "${BOLD}Obsidian LiveSync 连接信息${NC}"
  echo "────────────────────────────────"
  echo "  URI:      http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}/"
  echo "  Username: ${COUCHDB_USER}"
  echo "  Password: ${COUCHDB_PASSWORD}"
  echo "  端口:     ${COUCHDB_PORT}"
  echo ""
  echo "  ⚠️  本机部署仅限本机 Obsidian 使用"
  echo "     其他设备需通过 Tailscale 或反向代理访问"
else
  SERVER_IP="${REMOTE_HOST#*@}"
  SERVER_IP="${SERVER_IP##* }"
  # 获取服务器公网 IP（如果是域名则直接用）
  if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP="$SERVER_IP"
  else
    # 尝试从 SSH 获取
    PUBLIC_IP="$SERVER_IP"
  fi

  VERSION=$($REMOTE_SSH "curl -sS --max-time 5 http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}/" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo "失败")
  ok "CouchDB 版本: $VERSION"
  echo ""
  echo -e "${BOLD}Obsidian LiveSync 连接信息${NC}"
  echo "────────────────────────────────"
  echo "  URI:      http://${PUBLIC_IP}:${COUCHDB_PORT}/"
  echo "  Username: ${COUCHDB_USER}"
  echo "  Password: ${COUCHDB_PASSWORD}"
  echo ""
  echo -e "  ${YELLOW}⚠  当前仅 HTTP 直连${NC}"
  echo "     桌面版 Obsidian 可用"
  echo "     移动端（iOS/Android）需要 HTTPS"
  echo "     后续配置反代: bash deploy-couchdb.sh --proxy"
  echo ""
  echo "  Obsidian Self-hosted LiveSync 插件配置:"
  echo "    URI:        http://${PUBLIC_IP}:${COUCHDB_PORT}/"
  echo "    Username:   ${COUCHDB_USER}"
  echo "    Password:   ${COUCHDB_PASSWORD}"
  echo "    DB name:    my-vault (自定义)"
fi
echo ""

# ── 保存连接信息到本地文件 ──────────────────────────────────────────────
CONFIG_DIR="$(cd "$SCRIPT_DIR" && pwd)/configs"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/couchdb-connection.txt" <<EOF
CouchDB Connection Info
========================
URI:      http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@${PUBLIC_IP:-127.0.0.1}:${COUCHDB_PORT}/
Username: ${COUCHDB_USER}
Password: ${COUCHDB_PASSWORD}
Port:     ${COUCHDB_PORT}

LiveSync Plugin Settings:
  URI:        http://${PUBLIC_IP:-127.0.0.1}:${COUCHDB_PORT}/
  Username:   ${COUCHDB_USER}
  Password:   ${COUCHDB_PASSWORD}
  DB name:    my-vault
EOF
chmod 600 "$CONFIG_DIR/couchdb-connection.txt"
ok "连接信息已保存到: $CONFIG_DIR/couchdb-connection.txt (chmod 600)"
