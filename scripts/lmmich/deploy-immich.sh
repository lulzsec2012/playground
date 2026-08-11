# ============================================================================
# deploy-immich.sh — Immich 照片管理 + 扩展工具一键部署
#
# 部署内容:
#   Immich 全家桶 (server + machine-learning + postgres + redis)
#   + helloxz/nsfw  (NSFW 识别, :6086)
#   + Ollama        (VLM 打标签后端, :11434)
#   + immich-analyze (AI 描述/关键词 → Immich)
#   + CLI 工具: immich-cli / immich-stack / immich-deduper / czkawka-cli
#
# 用法:
#   bash deploy-immich.sh                        # 本机部署
#   bash deploy-immich.sh --host <ip|ssh-alias>  # 远程部署
#   bash deploy-immich.sh --dir /opt/lmmich      # 部署目录 (默认 /opt/lmmich)
#   bash deploy-immich.sh --no-gpu               # 禁用 GPU (ML/Ollama 用 CPU)
#   bash deploy-immich.sh --remote-ml <url>      # ML 指向远程 (如 Mac mini: http://192.168.x.x:3003)
#   bash deploy-immich.sh --remote-ollama <url>  # Ollama 指向远程 (如 http://192.168.x.x:11434)
#   bash deploy-immich.sh --model <name>         # 打标签模型 (默认 qwen3-vl:4b-thinking-q4_K_M)
#   bash deploy-immich.sh --preset mac|gpu|fast  # 模型预设: mac=4b+moondream / gpu=30b-a3b / fast=moondream
#   bash deploy-immich.sh --mac-worker           # Mac mini 模式 (原生安装算力端, 见 install-mac-worker.sh)
#   bash deploy-immich.sh --admin-pass xxx       # 指定 Immich admin 密码
#   bash deploy-immich.sh --status / --remove    # 状态 / 卸载
#
# 环境变量: IMMICH_PORT / NSFW_PORT / OLLAMA_PORT / IMMICH_VERSION 等可覆盖
# 敏感值 (admin 密码/API key/NSFW token) 自动生成并写入 .env (gitignored)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/lmmich}"
REMOTE_HOST=""
DO_STATUS=false
DO_REMOVE=false
HAS_GPU=false
IMMICH_ADMIN_PASSWORD=""
REMOTE_ML=""
REMOTE_OLLAMA=""
DO_MAC_WORKER=false
ANALYZE_MODEL="${ANALYZE_MODEL:-qwen3-vl:4b-thinking-q4_K_M}"
IMMICH_PORT="${IMMICH_PORT:-2283}"
NSFW_PORT="${NSFW_PORT:-6086}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

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
	--dir)
		shift
		DEPLOY_DIR="$1"
		;;
	--admin-pass)
		shift
		IMMICH_ADMIN_PASSWORD="$1"
		;;
	--remote-ml)
		shift
		REMOTE_ML="$1"
		;;
	--remote-ollama)
		shift
		REMOTE_OLLAMA="$1"
		;;
	--model)
		shift
		ANALYZE_MODEL="$1"
		;;
	--preset)
		shift
		case "$1" in
		gpu) ANALYZE_MODEL="qwen3-vl:30b-a3b-thinking-q4_K_M" ;;
		mac) ANALYZE_MODEL="qwen3-vl:4b-thinking-q4_K_M" ;;
		fast) ANALYZE_MODEL="moondream" ;;
		*)
			error "未知预设: $1 (可用: mac/gpu/fast)"
			exit 1
			;;
		esac
		;;
	--mac-worker) DO_MAC_WORKER=true ;;
	--no-gpu) HAS_GPU=false ;;
	--status) DO_STATUS=true ;;
	--remove) DO_REMOVE=true ;;
	--help | -h)
		sed -n '2,22p' "$0" | sed 's/^#//; s/^ //'
		exit 0
		;;
	*)
		error "未知参数: $1"
		exit 1
		;;
	esac
	shift
done

# ── 远程模式 ──────────────────────────────────────────────────────────────
if [[ -n "$REMOTE_HOST" ]]; then
	if [[ "$REMOTE_HOST" != *"@"* ]] && [[ "$REMOTE_HOST" != *"."* ]]; then
		REMOTE_SSH="$REMOTE_HOST"
	else
		REMOTE_SSH="ssh ubuntu@${REMOTE_HOST}"
	fi
	info "远程模式: $REMOTE_SSH"
	REMOTE_DIR="/tmp/lmmich-deploy-$(date +%s)"
	$REMOTE_SSH "mkdir -p $REMOTE_DIR" || exit 1
	scp -q "${SCRIPT_DIR}/deploy-immich.sh" "${SCRIPT_DIR}/docker-compose.yml.template" "$REMOTE_SSH:${REMOTE_DIR}/" || exit 1
	ARGS=()
	[[ -n "$IMMICH_ADMIN_PASSWORD" ]] && ARGS+=(--admin-pass "$IMMICH_ADMIN_PASSWORD")
	[[ -n "$REMOTE_ML" ]] && ARGS+=(--remote-ml "$REMOTE_ML")
	[[ -n "$REMOTE_OLLAMA" ]] && ARGS+=(--remote-ollama "$REMOTE_OLLAMA")
	[[ -n "$ANALYZE_MODEL" ]] && ARGS+=(--model "$ANALYZE_MODEL")
	$REMOTE_SSH "bash ${REMOTE_DIR}/deploy-immich.sh ${ARGS[*]:-}" || exit 1
	$REMOTE_SSH "rm -rf $REMOTE_DIR" 2>/dev/null || true
	exit 0
fi

# ── Mac mini 算力端模式 ───────────────────────────────────────────────────
if $DO_MAC_WORKER; then
	MAC_SCRIPT="${SCRIPT_DIR}/install-mac-worker.sh"
	if [[ -f "$MAC_SCRIPT" ]]; then
		MAC_ARGS=()
		[[ -n "$ANALYZE_MODEL" && "$ANALYZE_MODEL" != "qwen3-vl:4b-thinking-q4_K_M" ]] && MAC_ARGS+=(--model "$ANALYZE_MODEL")
		bash "$MAC_SCRIPT" "${MAC_ARGS[@]:-}"
	else
		error "缺少 ${MAC_SCRIPT}"
		exit 1
	fi
	exit 0
fi

# ── 状态 / 卸载 ───────────────────────────────────────────────────────────
if $DO_STATUS; then
	if [[ -f "${DEPLOY_DIR}/docker-compose.yml" ]]; then
		docker compose -f "${DEPLOY_DIR}/docker-compose.yml" ps 2>/dev/null || docker-compose -f "${DEPLOY_DIR}/docker-compose.yml" ps 2>/dev/null
	else
		warn "未部署 (${DEPLOY_DIR}/docker-compose.yml 不存在)"
	fi
	exit 0
fi

if $DO_REMOVE; then
	if [[ -f "${DEPLOY_DIR}/docker-compose.yml" ]]; then
		docker compose -f "${DEPLOY_DIR}/docker-compose.yml" down 2>/dev/null || docker-compose -f "${DEPLOY_DIR}/docker-compose.yml" down 2>/dev/null
		ok "容器已停止并移除 (数据保留在 ${DEPLOY_DIR}/)"
	fi
	exit 0
fi

# ── 前置检查 ──────────────────────────────────────────────────────────────
step "1/6 前置检查"
command -v docker >/dev/null || {
	error "未安装 Docker"
	exit 1
}
command -v docker compose >/dev/null 2>&1 || command -v docker-compose >/dev/null || {
	error "缺少 docker compose"
	exit 1
}
if nvidia-smi -L >/dev/null 2>&1; then
	HAS_GPU=true
	info "检测到 NVIDIA GPU，ML/Ollama 启用 GPU 加速"
else
	HAS_GPU=false
	warn "未检测到 GPU，ML/Ollama 将使用 CPU"
fi

# ── 初始化部署目录 + .env ─────────────────────────────────────────────────
step "2/6 初始化 ${DEPLOY_DIR}"
sudo mkdir -p "$DEPLOY_DIR"
sudo chown -R "$(id -u):$(id -g)" "$DEPLOY_DIR" 2>/dev/null || true
ENV_FILE="${DEPLOY_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
	[[ -z "$IMMICH_ADMIN_PASSWORD" ]] && IMMICH_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
	DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
	NSFW_TOKEN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
	cat >"$ENV_FILE" <<EOF
# Immich 部署配置 (敏感，勿提交)
UPLOAD_LOCATION=${DEPLOY_DIR}/upload
DB_DATA_LOCATION=${DEPLOY_DIR}/postgres
ML_CACHE=${DEPLOY_DIR}/model-cache
OLLAMA_DATA=${DEPLOY_DIR}/ollama-data

DB_USERNAME=postgres
DB_PASSWORD=${DB_PASSWORD}
DB_DATABASE_NAME=immich

IMMICH_PORT=${IMMICH_PORT}
NSFW_PORT=${NSFW_PORT}
NSFW_TOKEN=${NSFW_TOKEN}
NSFW_WORKERS=1
OLLAMA_PORT=${OLLAMA_PORT}

# Immich admin (首次启动后用于初始化)
IMMICH_ADMIN_EMAIL=admin@immich.localdomain
IMMICH_ADMIN_PASSWORD=${IMMICH_ADMIN_PASSWORD}

# immich-analyze (启动后自动获取或手动填入)
IMMICH_API_KEY=
ANALYZE_MODE=combined
ANALYZE_MODEL=${ANALYZE_MODEL:-qwen3-vl:4b-thinking-q4_K_M}
ANALYZE_OVERWRITE=missing-ai

# 远程算力 (空 = 本地部署 ML/Ollama; 非空 = 指向远程, 如 Mac mini)
REMOTE_ML=${REMOTE_ML}
REMOTE_OLLAMA=${REMOTE_OLLAMA}
EOF
	ok ".env 已生成 (admin 密码: ${IMMICH_ADMIN_PASSWORD})"
else
	info ".env 已存在，复用配置"
fi
# shellcheck disable=SC1091
source "$ENV_FILE"

# ── 渲染 docker-compose.yml ───────────────────────────────────────────────
step "3/6 生成 docker-compose.yml"
ML_GPU_SECTION=""
OLLAMA_GPU_SECTION=""
if $HAS_GPU; then
	ML_GPU_SECTION="    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
	OLLAMA_GPU_SECTION="    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
fi

python3 - "$SCRIPT_DIR" "$DEPLOY_DIR" "$ML_GPU_SECTION" "$OLLAMA_GPU_SECTION" <<'PYEOF'
import os, re, sys
src, dst, ml_gpu, ollama_gpu = sys.argv[1:5]
tpl = open(os.path.join(src, 'docker-compose.yml.template')).read()
env = {'ML_GPU_SECTION': ml_gpu, 'OLLAMA_GPU_SECTION': ollama_gpu, 'IMMICH_VERSION': 'release'}
for line in open(os.path.join(dst, '.env')):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        k, _, v = line.partition('=')
        env[k] = v

REMOTE_ML = env.get('REMOTE_ML', '')
REMOTE_OLLAMA = env.get('REMOTE_OLLAMA', '')
env['MACHINE_LEARNING_URL'] = REMOTE_ML if REMOTE_ML else 'http://immich-machine-learning:3003'
env['ANALYZE_HOSTS'] = REMOTE_OLLAMA if REMOTE_OLLAMA else 'http://ollama:%s' % env.get('OLLAMA_PORT', '11434')
env['ML_DEPENDS'] = '' if REMOTE_ML else '      - immich-machine-learning'
env['ANALYZE_DEPENDS'] = '' if REMOTE_OLLAMA else '      - ollama'

if REMOTE_ML:
    tpl = re.sub(r'\$\{SERVICE_ML_BEGIN\}.*?\$\{SERVICE_ML_END\}', '', tpl, flags=re.S)
else:
    tpl = tpl.replace('${SERVICE_ML_BEGIN}\n', '').replace('${SERVICE_ML_END}\n', '')
if REMOTE_OLLAMA:
    tpl = re.sub(r'\$\{SERVICE_OLLAMA_BEGIN\}.*?\$\{SERVICE_OLLAMA_END\}', '', tpl, flags=re.S)
else:
    tpl = tpl.replace('${SERVICE_OLLAMA_BEGIN}\n', '').replace('${SERVICE_OLLAMA_END}\n', '')

for k, v in env.items():
    tpl = tpl.replace('${%s}' % k, v)
def _resolve(m):
    inner = m.group(1)
    if ':-' in inner:
        var, _, default = inner.partition(':-')
        val = env.get(var)
        return val if val else default
    return env.get(inner, m.group(0))
tpl = re.sub(r'\$\{([^}]+)\}', _resolve, tpl)
leftover = sorted(set(re.findall(r'\$\{[^}]+\}', tpl)))
if leftover:
    print('  警告: 未替换占位符:', leftover)
open(os.path.join(dst, 'docker-compose.yml'), 'w').write(tpl)
PYEOF
ok "docker-compose.yml 已生成"

# ── 启动容器 ──────────────────────────────────────────────────────────────
step "4/6 启动容器 (拉取镜像可能需要几分钟)"
cd "$DEPLOY_DIR"
docker compose up -d 2>&1 | tail -5 || {
	error "启动失败，见上方日志"
	exit 1
}

# ── 健康检查 + admin 初始化 ──────────────────────────────────────────────
step "5/6 等待服务就绪"
for i in $(seq 1 60); do
	if curl -s --max-time 3 "http://127.0.0.1:${IMMICH_PORT}/api/server/ping" 2>/dev/null | grep -q '"res":"pong"'; then
		ok "Immich 就绪: http://<server>:${IMMICH_PORT}"
		break
	fi
	[ "$i" -eq 60 ] && { warn "Immich 60s 内未就绪，请稍后检查 docker compose logs immich-server"; }
	sleep 2
done

# 尝试自动初始化 admin + 创建 API key
if [[ -z "${IMMICH_API_KEY:-}" ]]; then
	ADMIN_EMAIL="${IMMICH_ADMIN_EMAIL:-admin@immich.localdomain}"
	ADMIN_PASS="${IMMICH_ADMIN_PASSWORD:-}"
	if [[ -n "$ADMIN_PASS" ]]; then
		REG=$(curl -s --max-time 5 -X POST "http://127.0.0.1:${IMMICH_PORT}/api/auth/register" \
			-H 'Content-Type: application/json' \
			-d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || true)
		if echo "$REG" | grep -q 'accessToken'; then
			ok "admin 用户自动创建成功"
		elif echo "$REG" | grep -qiE 'exist|registered|already'; then
			info "admin 用户已存在"
		else
			warn "自动注册未成功 (Immich 新版需在 UI 完成初始化): http://<server>:${IMMICH_PORT}"
			warn "  完成后在 管理后台 → API Keys 创建 Key，写入 ${ENV_FILE} 的 IMMICH_API_KEY"
		fi
		TOKEN=$(echo "$REG" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null || true)
		if [[ -n "$TOKEN" ]]; then
			KEY=$(curl -s --max-time 5 -X POST "http://127.0.0.1:${IMMICH_PORT}/api/api-keys" \
				-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
				-d '{"name":"deploy-script"}' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("secret",""))' 2>/dev/null || true)
			if [[ -n "$KEY" ]]; then
				sed -i "s|^IMMICH_API_KEY=.*|IMMICH_API_KEY=${KEY}|" "$ENV_FILE"
				ok "API Key 已自动创建"
			fi
		fi
	fi
fi

# ── 安装 CLI 工具 ─────────────────────────────────────────────────────────
step "6/6 安装 CLI 工具 (immich-cli / immich-stack / immich-deduper / czkawka)"
if command -v npm >/dev/null 2>&1; then
	npm install -g @immich/cli >/dev/null 2>&1 && ok "immich-cli" || warn "immich-cli 安装失败"
else
	warn "无 npm，跳过 immich-cli (可用: docker exec immich-server immich)"
fi

ARCH="$(uname -m)"
STACK_VER="$(curl -s --max-time 8 https://api.github.com/repos/Majorfi/immich-stack/releases/latest 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
if [[ -n "$STACK_VER" ]]; then
	STACK_URL="https://github.com/Majorfi/immich-stack/releases/download/${STACK_VER}/immich-stack_${ARCH}"
	sudo curl -sL --max-time 60 -o /usr/local/bin/immich-stack "$STACK_URL" && sudo chmod +x /usr/local/bin/immich-stack && ok "immich-stack ${STACK_VER}" || warn "immich-stack 下载失败"
fi

pip3 install --quiet immich-deduper 2>/dev/null && ok "immich-deduper (pip)" || warn "immich-deduper 安装失败 (可用 Docker: ghcr.io/varun-raj/immich-deduper)"

if command -v apt-get >/dev/null 2>&1; then
	sudo apt-get install -y -qq czkawka-cli >/dev/null 2>&1 && ok "czkawka-cli" || warn "czkawka-cli 安装失败 (可手动: https://github.com/qarmin/czkawka/releases)"
fi

# ── 完成 ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo " 部署完成!"
echo ""
echo "  Immich Web:      http://<server>:${IMMICH_PORT}"
echo "  NSFW API:        http://127.0.0.1:${NSFW_PORT}/api/upload_check"
echo "  Ollama:          http://127.0.0.1:${OLLAMA_PORT}"
echo ""
echo "  admin:           ${IMMICH_ADMIN_EMAIL:-admin@immich.localdomain}"
echo "  密码:            ${IMMICH_ADMIN_PASSWORD:-见 ${ENV_FILE}}"
echo "  配置/密钥:       ${ENV_FILE}"
echo ""
echo "  CLI 工具:"
echo "    immich-cli      导入照片:  immich upload --server http://<server>:${IMMICH_PORT} --key \$(grep IMMICH_API_KEY ${ENV_FILE} | cut -d= -f2) --recursive /path"
echo "    immich-stack    相似堆叠:  immich-stack --dry-run"
echo "    immich-deduper  精细去重:  immich-deduper --server-url http://<server>:${IMMICH_PORT}/api --api-key <KEY> --dry-run"
echo "    czkawka-cli     文件查重:  czkawka_cli duplicate -d ${DEPLOY_DIR}/upload"
echo ""
echo "  首次使用: 浏览器打开 Immich → 完成 admin 初始化 (若脚本未自动创建)"
echo "  详细工作流见: scripts/lmmich/README.md"
echo "══════════════════════════════════════════════════════════"
