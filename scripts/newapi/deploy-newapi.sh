#!/usr/bin/env bash
# ============================================================================
# deploy-newapi.sh — new-api (QuantumNous) LLM 网关部署脚本
#
# 替代 MixAPI（同为 one-api 系，但 new-api 持续维护且已修复 tool_calls 透传）
#
# 架构:
#   new-api (阿里云 39.102.52.1:3000)
#     ├── 渠道1: vLLM qwen3.6-27b  (headscale 内网 100.64.0.1:8002)
#     ├── 渠道2: DeepSeek API     (api.deepseek.com)
#     └── 消费端: Obsidian 插件 / llmwiki (端口 3000 不变，客户端零改动)
#
# 用法:
#   bash deploy-newapi.sh              # 部署容器（本地或远程主机）
#   bash deploy-newapi.sh --host       # 远程部署（配合 ssh 别名）
#   bash deploy-newapi.sh --status     # 查看状态
#   bash deploy-newapi.sh --remove     # 卸载
#
# 环境变量:
#   DEEPSEEK_API_KEY   — DeepSeek 渠道密钥
#   NEWAPI_PORT        — 映射端口 (默认 3000)
#   NEWAPI_DATA_DIR    — 数据目录 (默认 /opt/newapi/data)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 默认配置 ──────────────────────────────────────────────────────────────
NEWAPI_PORT="${NEWAPI_PORT:-3000}"
NEWAPI_DATA_DIR="${NEWAPI_DATA_DIR:-/opt/newapi/data}"
IMAGE="calciumion/new-api:latest"
CONTAINER="new-api"
REMOTE_HOST=""
REMOTE_SSH=""
DO_REMOVE=false
DO_STATUS=false

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}  [WARN]${NC} $1"; }
error() { echo -e "${RED}  [ERROR]${NC} $1"; }
ok() { echo -e "${GREEN}  ✓${NC} $1"; }

# ── 参数解析 ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
	case "$1" in
	--host)
		shift
		REMOTE_HOST="$1"
		;;
	--port)
		shift
		NEWAPI_PORT="$1"
		;;
	--data-dir)
		shift
		NEWAPI_DATA_DIR="$1"
		;;
	--remove) DO_REMOVE=true ;;
	--status) DO_STATUS=true ;;
	--help | -h)
		sed -n '2,30p' "$0" | sed 's/^#//; s/^ //'
		exit 0
		;;
	*)
		error "未知参数: $1"
		exit 1
		;;
	esac
done

# ── 远程执行封装 ──────────────────────────────────────────────────────────
run() {
	if [[ -n "$REMOTE_HOST" ]]; then
		$REMOTE_SSH "$*"
	else
		eval "$*"
	fi
}

# ── 状态 ──────────────────────────────────────────────────────────────────
do_status() {
	run "docker ps --filter name=${CONTAINER} --format '{{.Names}} | {{.Image}} | {{.Ports}} | {{.Status}}'"
	if [[ -n "$REMOTE_HOST" ]]; then
		$REMOTE_SSH "docker ps --filter name=${CONTAINER} --format '{{.Names}} | {{.Image}} | {{.Ports}} | {{.Status}}'"
	else
		docker ps --filter name=${CONTAINER} --format '{{.Names}} | {{.Image}} | {{.Ports}} | {{.Status}}'
	fi
}

# ── 卸载 ──────────────────────────────────────────────────────────────────
do_remove() {
	warn "卸载 ${CONTAINER}（数据保留在 ${NEWAPI_DATA_DIR}）..."
	run "docker stop ${CONTAINER} 2>/dev/null; docker rm ${CONTAINER} 2>/dev/null; echo removed"
	ok "已卸载"
}

# ── 部署 ──────────────────────────────────────────────────────────────────
do_deploy() {
	# 1. 数据目录
	run "sudo mkdir -p ${NEWAPI_DATA_DIR} && sudo chown -R \$(id -u):\$(id -g) ${NEWAPI_DATA_DIR}"
	ok "数据目录: ${NEWAPI_DATA_DIR}"

	# 2. 拉取镜像
	info "拉取镜像 ${IMAGE} ..."
	run "docker pull ${IMAGE}" || error "镜像拉取失败（国内可用 ghcr/镜像加速）"
	ok "镜像就绪"

	# 3. 清理旧容器
	run "docker rm -f ${CONTAINER} 2>/dev/null; true"

	# 4. 启动
	info "启动 ${CONTAINER} (:${NEWAPI_PORT}) ..."
	run "docker run -d --name ${CONTAINER} --restart always \
    -p ${NEWAPI_PORT}:3000 \
    -e TZ=Asia/Shanghai \
    -v ${NEWAPI_DATA_DIR}:/data \
    ${IMAGE}"
	ok "容器已启动"

	# 5. 等待就绪
	info "等待服务就绪..."
	sleep 5
	local health
	health="$(run "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${NEWAPI_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
	if [[ "$health" == "200" || "$health" == "302" || "$health" == "401" ]]; then
		ok "服务就绪: http://<host>:${NEWAPI_PORT}/"
	else
		warn "HTTP 状态: ${health}（可能仍在初始化，稍后访问管理界面确认）"
	fi
}

# ── 渠道配置指引 ──────────────────────────────────────────────────────────
print_channel_guide() {
	cat <<EOF

${CYAN}============================================================${NC}
  new-api 部署完成 — 下一步配置渠道
${CYAN}============================================================${NC}
  管理界面: http://<host>:${NEWAPI_PORT}/
  默认账号: root / 123456（首次登录后立即修改!）

  渠道配置（管理 → 渠道 → 添加渠道）:
  ┌─────────┬───────────────┬──────────────────────────────┬──────────────┐
  │ 名称    │ 类型          │ 代理地址                      │ 模型          │
  ├─────────┼───────────────┼──────────────────────────────┼──────────────┤
  │ vLLM    │ OpenAI        │ http://100.64.0.1:8002       │ qwen3.6-27b  │
  │ DeepSeek│ DeepSeek      │ https://api.deepseek.com      │ deepseek-v4-*│
  └─────────┴───────────────┴──────────────────────────────┴──────────────┘

  生成令牌（管理 → 令牌 → 添加令牌）后填入:
    - Obsidian ai-providers: baseUrl=http://<host>:${NEWAPI_PORT}  key=<新令牌>
    - llmwiki (腾讯云):       OPENAI_BASE_URL=http://<host>:${NEWAPI_PORT}  key=<新令牌>
    (tool_calls 已修复, llmwiki 可直连网关不再需要绕道 vLLM)

  迁移提示:
    原 MixAPI 数据在 ~/.mixapi_data/（如需迁移渠道参考 scripts/mixapi/ 旧配置）
EOF
}

# ── 主流程 ────────────────────────────────────────────────────────────────
if [[ -n "$REMOTE_HOST" ]]; then
	REMOTE_SSH="ssh -o ConnectTimeout=10 ${REMOTE_HOST}"
	info "远程部署: ${REMOTE_HOST}"
fi

if $DO_STATUS; then
	do_status
elif $DO_REMOVE; then
	do_remove
else
	do_deploy
	print_channel_guide
fi
