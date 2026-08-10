#!/usr/bin/env bash
# ============================================================================
# deploy-systemd.sh — 安装 llmwiki/vault 同步的 systemd 服务与运行环境
#
# 功能:
#   1. 写入 /etc/llmwiki.env（模型端点 + CouchDB 凭据 + PATH）
#   2. 安装 sync-vault-raw.sh → /usr/local/bin/
#   3. 写入并启用 3 个 systemd 单元:
#      - vault-raw-sync.service   (sync-vault-raw.sh --daemon, 每 60s 增量拉取 raw/)
#      - llmwiki-compile.service  (全量拉取 + llmwiki compile, oneshot)
#      - llmwiki-compile.timer    (每 5 分钟触发编译, 默认启用)
#   4. 可选 --watch: 改用 llmwiki-watch.service（即时编译）替代 timer
#
# 用法:
#   bash deploy-systemd.sh                        # 本机（目标服务器）执行
#   bash deploy-systemd.sh --couch-pass xxx       # 指定 CouchDB 密码
#   bash deploy-systemd.sh --watch                # 启用 watch 即时编译
#
# 环境变量:
#   COUCHDB_USER / COUCHDB_PASSWORD — CouchDB 凭据（默认从 configs/couchdb-connection.txt 解析）
#   LLMWIKI_BASE_URL / LLMWIKI_API_KEY / LLMWIKI_MODEL — 模型端点（默认读 /etc/llmwiki.env 或直连 vLLM）
# ============================================================================
set -euo pipefail
# 基础设施地址（gitignored: scripts/data/hosts.cfg）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
	for _d in "$(dirname "${BASH_SOURCE[0]}")/../../../data" "$(dirname "${BASH_SOURCE[0]}")/../../data"; do
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
SSH_USER="${SSH_USER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIKI_ROOT="${WIKI_ROOT:-/opt/llmwiki}"
SERVICE_USER="${SERVICE_USER:-ubuntu}"
DO_WATCH=false
CONN_FILE="${SCRIPT_DIR}/../configs/couchdb-connection.txt"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info() { echo -e "${GREEN}  [✓]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!]${NC} $*"; }
error() { echo -e "${RED}  [✗]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--watch) DO_WATCH=true ;;
	--couch-user)
		shift
		COUCHDB_USER="$1"
		;;
	--couch-pass)
		shift
		COUCHDB_PASSWORD="$1"
		;;
	--help | -h)
		sed -n '2,24p' "$0" | sed 's/^#//; s/^ //'
		exit 0
		;;
	*)
		error "未知参数: $1"
		exit 1
		;;
	esac
	shift
done

# ---- CouchDB 凭据: 参数 > 环境变量 > configs 文件 ----
COUCHDB_USER="${COUCHDB_USER:-}"
COUCHDB_PASSWORD="${COUCHDB_PASSWORD:-}"
if [[ -z "$COUCHDB_USER" || -z "$COUCHDB_PASSWORD" ]] && [[ -f "$CONN_FILE" ]]; then
	COUCHDB_USER="${COUCHDB_USER:-$(grep -oP 'Username: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
	COUCHDB_PASSWORD="${COUCHDB_PASSWORD:-$(grep -oP 'Password: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
fi
if [[ -z "$COUCHDB_USER" || -z "$COUCHDB_PASSWORD" ]]; then
	error "缺少 CouchDB 凭据（--couch-pass 或 COUCHDB_PASSWORD 环境变量或 $CONN_FILE）"
	exit 1
fi

# ---- 模型端点: 环境变量 > 已有 /etc/llmwiki.env > 直连 vLLM 默认 ----
LLMWIKI_MODEL="${LLMWIKI_MODEL:-qwen3.6-27b}"
LLMWIKI_BASE_URL="${LLMWIKI_BASE_URL:-}"
LLMWIKI_API_KEY="${LLMWIKI_API_KEY:-}"
if [[ -z "$LLMWIKI_BASE_URL" && -f /etc/llmwiki.env ]]; then
	LLMWIKI_BASE_URL="$(grep -oP 'OPENAI_BASE_URL=\K.*' /etc/llmwiki.env 2>/dev/null || true)"
	LLMWIKI_API_KEY="$(grep -oP 'OPENAI_API_KEY=\K.*' /etc/llmwiki.env 2>/dev/null || true)"
fi
LLMWIKI_BASE_URL="${LLMWIKI_BASE_URL:-}"
[[ -z "$LLMWIKI_BASE_URL" && -n "$COMPANY_IP" ]] && LLMWIKI_BASE_URL="http://${COMPANY_IP}:8002/v1"
LLMWIKI_API_KEY="${LLMWIKI_API_KEY:-sk-local}"

# ──────────────────────────────────────────────────────────────
# 1. /etc/llmwiki.env
# ──────────────────────────────────────────────────────────────
sudo mkdir -p "$WIKI_ROOT"
sudo tee /etc/llmwiki.env >/dev/null <<ENV
LLMWIKI_PROVIDER=openai
LLMWIKI_MODEL=${LLMWIKI_MODEL}
OPENAI_API_KEY=${LLMWIKI_API_KEY}
OPENAI_BASE_URL=${LLMWIKI_BASE_URL}
PATH=/usr/local/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${COUCHDB_PASSWORD}
ENV
sudo chmod 600 /etc/llmwiki.env
info "/etc/llmwiki.env (模型: ${LLMWIKI_MODEL} @ ${LLMWIKI_BASE_URL})"

# ──────────────────────────────────────────────────────────────
# 2. sync-vault-raw.sh → /usr/local/bin
# ──────────────────────────────────────────────────────────────
sudo cp "${SCRIPT_DIR}/../sync/sync-vault-raw.sh" /usr/local/bin/sync-vault-raw.sh
sudo chmod +x /usr/local/bin/sync-vault-raw.sh
info "/usr/local/bin/sync-vault-raw.sh"

# ──────────────────────────────────────────────────────────────
# 3. systemd 单元
# ──────────────────────────────────────────────────────────────
UNIT_DIR=/etc/systemd/system

sudo tee ${UNIT_DIR}/vault-raw-sync.service >/dev/null <<UNIT
[Unit]
Description=Sync vault raw/ from CouchDB to llmwiki sources/

[Service]
Type=simple
User=${SERVICE_USER}
EnvironmentFile=/etc/llmwiki.env
ExecStart=/usr/local/bin/sync-vault-raw.sh --daemon
Restart=always
RestartSec=10
UNIT

sudo tee ${UNIT_DIR}/llmwiki-compile.service >/dev/null <<UNIT
[Unit]
Description=LLM Wiki - periodic compile
After=network.target

[Service]
Type=oneshot
User=${SERVICE_USER}
WorkingDirectory=${WIKI_ROOT}
EnvironmentFile=/etc/llmwiki.env
ExecStart=/usr/local/bin/sync-vault-raw.sh --force
ExecStart=/usr/local/node/bin/llmwiki compile
TimeoutStartSec=600
UNIT

sudo tee ${UNIT_DIR}/llmwiki-compile.timer >/dev/null <<UNIT
[Unit]
Description=LLM Wiki compile timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

if $DO_WATCH; then
	sudo tee ${UNIT_DIR}/llmwiki-watch.service >/dev/null <<UNIT
[Unit]
Description=LLM Wiki - vault raw sync + auto compile
After=docker.service network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${WIKI_ROOT}
EnvironmentFile=/etc/llmwiki.env
ExecStartPre=/usr/local/bin/sync-vault-raw.sh --force
ExecStart=/usr/local/node/bin/llmwiki watch
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
fi

# ──────────────────────────────────────────────────────────────
# 4. 启用与启动
# ──────────────────────────────────────────────────────────────
sudo systemctl daemon-reload
sudo systemctl restart vault-raw-sync.service
sudo systemctl disable llmwiki-watch.service >/dev/null 2>&1 || true

if $DO_WATCH; then
	sudo systemctl enable --now llmwiki-watch.service >/dev/null 2>&1
	sudo systemctl stop llmwiki-compile.timer >/dev/null 2>&1 || true
	info "已启用 llmwiki-watch.service（即时编译）"
else
	sudo systemctl enable llmwiki-compile.timer >/dev/null 2>&1
	sudo systemctl start llmwiki-compile.timer
	info "已启用 llmwiki-compile.timer（每 5 分钟编译）"
fi

echo ""
echo "  systemd 服务状态:"
systemctl is-active vault-raw-sync.service | sed 's/^/    vault-raw-sync: /'
if $DO_WATCH; then
	systemctl is-active llmwiki-watch.service | sed 's/^/    llmwiki-watch: /'
else
	systemctl is-active llmwiki-compile.timer | sed 's/^/    compile-timer: /'
fi
