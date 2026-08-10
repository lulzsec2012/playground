#!/usr/bin/env bash
# ============================================================================
# deploy-all.sh — Obsidian LiveSync + LLM Wiki 一键部署
#
# 在目标服务器上完成: CouchDB → sync-vault-raw → llmwiki → systemd 全链路
#
# 用法:
#   # 本机模式（在目标服务器上执行，或配合 --host 远程执行）
#   bash deploy-all.sh
#
#   # 远程模式（从任意机器发起，自动 scp 脚本到远程执行）
#   bash deploy-all.sh --host <tencent-ip>
#   bash deploy-all.sh --host tencent
#
# 常用参数:
#   --couch-pass xxx       CouchDB 密码（默认自动生成）
#   --model-endpoint URL   OpenAI 兼容端点（默认 http://<company-ip>:8002/v1 直连 vLLM）
#   --model-key KEY        模型 API Key（默认 sk-local）
#   --model NAME           模型名（默认 qwen3.6-27b）
#   --watch                启用 llmwiki watch 即时编译（默认用 5min timer）
#
# 幂等: 重复执行只补齐缺失组件，不破坏现有数据
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_CFG="${HOSTS_CFG:-}"
for _d in "${SCRIPT_DIR}/../../data" "${SCRIPT_DIR}/../data"; do [[ -f "$_d/hosts.cfg" ]] && {
	HOSTS_CFG="$_d/hosts.cfg"
	break
}; done
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
COMPANY_IP="${COMPANY_IP:-}"
REMOTE_HOST=""
COUCHDB_PASSWORD="${COUCHDB_PASSWORD:-}"
LLMWIKI_BASE_URL="${LLMWIKI_BASE_URL:-}"
[[ -z "$LLMWIKI_BASE_URL" && -n "$COMPANY_IP" ]] && LLMWIKI_BASE_URL="http://${COMPANY_IP}:8002/v1"
LLMWIKI_API_KEY="${LLMWIKI_API_KEY:-sk-local}"
LLMWIKI_MODEL="${LLMWIKI_MODEL:-qwen3.6-27b}"
DO_WATCH=false

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
info() { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}  [WARN]${NC} $1"; }
error() { echo -e "${RED}  [ERROR]${NC} $1"; }
step() { echo -e "\n${CYAN}  >>>${NC} ${BOLD}$1${NC}"; }
ok() { echo -e "${GREEN}  ✓${NC} $1"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--host)
		shift
		REMOTE_HOST="$1"
		;;
	--couch-pass)
		shift
		COUCHDB_PASSWORD="$1"
		;;
	--model-endpoint)
		shift
		LLMWIKI_BASE_URL="$1"
		;;
	--model-key)
		shift
		LLMWIKI_API_KEY="$1"
		;;
	--model)
		shift
		LLMWIKI_MODEL="$1"
		;;
	--watch) DO_WATCH=true ;;
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

# ── 远程模式: 打包整个 obsidian 目录（排除 configs 凭据）到远程并递归执行 ──
if [[ -n "$REMOTE_HOST" ]]; then
	if [[ "$REMOTE_HOST" != *"@"* ]] && [[ "$REMOTE_HOST" != *"."* ]]; then
		REMOTE_SSH="$REMOTE_HOST"
	else
		REMOTE_SSH="ssh ubuntu@${REMOTE_HOST}"
	fi
	info "远程模式: $REMOTE_SSH"
	REMOTE_DIR="/tmp/obsidian-deploy-$(date +%s)"
	$REMOTE_SSH "mkdir -p $REMOTE_DIR" || exit 1
	tar -C "${SCRIPT_DIR}/.." --exclude=configs -cf - . | $REMOTE_SSH "tar -C ${REMOTE_DIR} -xf -" || exit 1
	ARGS=()
	[[ -n "$COUCHDB_PASSWORD" ]] && ARGS+=(--couch-pass "$COUCHDB_PASSWORD")
	ARGS+=(--model-endpoint "$LLMWIKI_BASE_URL" --model-key "$LLMWIKI_API_KEY" --model "$LLMWIKI_MODEL")
	$DO_WATCH && ARGS+=(--watch)
	$REMOTE_SSH "bash ${REMOTE_DIR}/deploy/deploy-all.sh ${ARGS[*]}" || exit 1
	$REMOTE_SSH "rm -rf $REMOTE_DIR" 2>/dev/null || true
	exit 0
fi

info "本机部署模式"
export LLMWIKI_BASE_URL LLMWIKI_API_KEY LLMWIKI_MODEL

# ══════════════════════════════════════════════════════════════════════
# 1. CouchDB（已运行则跳过）
# ══════════════════════════════════════════════════════════════════════
step "1/5 CouchDB (LiveSync 后端)"
if curl -s --max-time 3 http://127.0.0.1:5984/_up >/dev/null 2>&1; then
	ok "CouchDB 已在运行"
else
	if [[ -z "$COUCHDB_PASSWORD" ]]; then
		COUCHDB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 2>/dev/null)
	fi
	bash "${SCRIPT_DIR}/../sync/deploy-couchdb.sh" --password "$COUCHDB_PASSWORD" || exit 1
fi

# 从容器读取实际密码（若自动生成）
if [[ -z "$COUCHDB_PASSWORD" ]] && docker inspect couchdb >/dev/null 2>&1; then
	COUCHDB_PASSWORD="$(docker inspect couchdb --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^COUCHDB_PASSWORD=' | cut -d= -f2)"
fi
export COUCHDB_PASSWORD

# ══════════════════════════════════════════════════════════════════════
# 2. 初始化 my-vault 数据库
# ══════════════════════════════════════════════════════════════════════
step "2/5 初始化 my-vault 数据库"
COUCHDB_USER="${COUCHDB_USER:-admin}"
if ! curl -s --max-time 5 -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
	"http://127.0.0.1:5984/my-vault" | grep -q '"db_name"'; then
	curl -s --max-time 5 -X PUT -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
		"http://127.0.0.1:5984/my-vault" >/dev/null && ok "my-vault 已创建"
else
	ok "my-vault 已存在"
fi

# 写入连接信息（gitignored，供各脚本解析）
mkdir -p "${SCRIPT_DIR}/../configs"
cat >"${SCRIPT_DIR}/../configs/couchdb-connection.txt" <<EOF
CouchDB Connection Info
========================
URI:      http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@$(hostname -I 2>/dev/null | awk '{print $1}'):5984/
Username: ${COUCHDB_USER}
Password: ${COUCHDB_PASSWORD}
Port:     5984

LiveSync Plugin Settings:
  URI:        http://$(hostname -I 2>/dev/null | awk '{print $1}'):5984/
  Username:   ${COUCHDB_USER}
  Password:   ${COUCHDB_PASSWORD}
  DB name:    my-vault
EOF
ok "连接信息 → configs/couchdb-connection.txt"

# ══════════════════════════════════════════════════════════════════════
# 3. llmwiki（已装则跳过，幂等）
# ══════════════════════════════════════════════════════════════════════
step "3/5 LLM Wiki 编译引擎"
export LLMWIKI_BASE_URL LLMWIKI_API_KEY LLMWIKI_MODEL
bash "${SCRIPT_DIR}/../wiki/deploy-llmwiki.sh" || exit 1

# ══════════════════════════════════════════════════════════════════════
# 4. systemd 服务
# ══════════════════════════════════════════════════════════════════════
step "4/5 systemd 服务"
WATCH_ARGS=()
$DO_WATCH && WATCH_ARGS+=(--watch)
bash "${SCRIPT_DIR}/../runtime/deploy-systemd.sh" --couch-user "$COUCHDB_USER" \
	--couch-pass "$COUCHDB_PASSWORD" "${WATCH_ARGS[@]}" || exit 1

# ══════════════════════════════════════════════════════════════════════
# 5. 验证
# ══════════════════════════════════════════════════════════════════════
step "5/5 验证"
curl -s --max-time 5 http://127.0.0.1:5984/_up | grep -q '"ok"' && ok "CouchDB 可达"
systemctl is-active vault-raw-sync.service >/dev/null 2>&1 && ok "vault-raw-sync 运行中"
if $DO_WATCH; then
	systemctl is-active llmwiki-watch.service >/dev/null 2>&1 && ok "llmwiki-watch 运行中"
else
	systemctl is-active llmwiki-compile.timer >/dev/null 2>&1 && ok "compile timer 运行中"
fi
export PATH=/usr/local/node/bin:$PATH
llmwiki --version >/dev/null 2>&1 && ok "llmwiki $(llmwiki --version) 可用"

echo ""
echo "══════════════════════════════════════════════════"
echo " 部署完成!"
echo "  客户端 LiveSync 配置:"
echo "    URI:        http://<公网IP>:5984/"
echo "    Username:   ${COUCHDB_USER}"
echo "    Password:   ${COUCHDB_PASSWORD}"
echo "    DB name:    my-vault"
echo "══════════════════════════════════════════════════"
