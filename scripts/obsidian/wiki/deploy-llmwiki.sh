#!/usr/bin/env bash
# ============================================================================
# deploy-llmwiki.sh — LLM Wiki (llm-wiki-compiler) 部署脚本
#
# 架构:
#   llmwiki (腾讯云 <tencent-ip>) → vLLM qwen3.6-27b (公司 2225, headscale 内网)
#   或经 new-api 网关: llmwiki → new-api (<aliyun-ip>:3000) → vLLM
#
# 用法:
#   bash deploy-llmwiki.sh [wiki-root]                         # 默认 /opt/llmwiki, 直连 vLLM
#   LLMWIKI_BASE_URL=http://<gateway-ip>:3000/v1 \
#   LLMWIKI_API_KEY=sk-xxx \
#   bash deploy-llmwiki.sh                                    # 走 new-api 网关
#
# 环境变量:
#   LLMWIKI_MODEL       — 模型名 (默认: qwen3.6-27b)
#   LLMWIKI_BASE_URL    — OpenAI 兼容端点 (默认: http://<company-ip>:8002/v1 直连 vLLM)
#   LLMWIKI_API_KEY     — API Key (默认: sk-local, vLLM 不校验)
#
# 依赖: Node.js 22+ (自动安装)
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

WIKI_ROOT="${1:-/opt/llmwiki}"
LLMWIKI_MODEL="${LLMWIKI_MODEL:-qwen3.6-27b}"
LLMWIKI_BASE_URL="${LLMWIKI_BASE_URL:-}"
[[ -z "$LLMWIKI_BASE_URL" && -n "$COMPANY_IP" ]] && LLMWIKI_BASE_URL="http://${COMPANY_IP}:8002/v1"
LLMWIKI_API_KEY="${LLMWIKI_API_KEY:-sk-local}"
export PATH=/usr/local/node/bin:$PATH

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}  [✓]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!]${NC} $*"; }

# 1. Node.js
if ! command -v node >/dev/null 2>&1; then
	warn "安装 Node.js 22..."
	curl -fsSL --connect-timeout 10 --max-time 120 https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz -o /tmp/node.tar.xz
	sudo tar -xJf /tmp/node.tar.xz -C /usr/local/
	sudo mv /usr/local/node-v22.14.0-linux-x64 /usr/local/node 2>/dev/null || true
	echo 'export PATH=/usr/local/node/bin:$PATH' | sudo tee /etc/profile.d/node.sh >/dev/null
	info "Node $(node --version)"
fi

# 2. llm-wiki-compiler
if ! command -v llmwiki >/dev/null 2>&1; then
	warn "安装 llm-wiki-compiler..."
	sudo chown -R ubuntu:ubuntu /usr/local/node 2>/dev/null || true
	npm install -g llm-wiki-compiler
fi
info "llmwiki $(llmwiki --version)"

# 3. 项目初始化
sudo mkdir -p "$WIKI_ROOT" && sudo chown -R ubuntu:ubuntu "$WIKI_ROOT"
cd "$WIKI_ROOT"
[[ -f .llmwiki/schema.json ]] || llmwiki schema init
mkdir -p sources wiki
info "项目: $WIKI_ROOT"

# 4. 环境配置
sudo tee /etc/profile.d/llmwiki.sh >/dev/null <<ENV
export LLMWIKI_PROVIDER=openai
export LLMWIKI_MODEL=${LLMWIKI_MODEL}
export OPENAI_API_KEY=${LLMWIKI_API_KEY}
export OPENAI_BASE_URL=${LLMWIKI_BASE_URL}
ENV
info "环境变量已配置 (/etc/profile.d/llmwiki.sh)"

cat <<DONE

部署完成!
  使用:
    source /etc/profile.d/llmwiki.sh
    llmwiki ingest <file-or-url>          # 摄入材料 → sources/
    llmwiki compile                       # 编译为 wiki 页
    llmwiki watch                         # 自动监控 sources/ 变更并重编译
    llmwiki query "问题"                   # 基于 wiki 问答
    bash scripts/obsidian/wiki/llmwiki-clean.sh wiki   # 清理 qwen think 残留
DONE
