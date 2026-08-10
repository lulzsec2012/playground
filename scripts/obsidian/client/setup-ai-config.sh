#!/usr/bin/env bash
# ============================================================================
# setup-ai-config.sh — 生成 AI 插件预配置文件（阶段1 第二部分）
#
# 生成:
#   <vault>/.obsidian/plugins/ai-providers/data.json   — AI Providers 配置
#   <vault>/.obsidian/plugins/copilot/data.json        — Copilot 配置（可选）
#
# 模型来源:
#   - DeepSeek 官方 API (deepseek-v4-flash / pro)      ← 默认
#   - MixAPI 网关 (<aliyun-ip>:3000)                    ← 统一入口
#   - 本地 vLLM (127.0.0.1:8001)                        ← 内网模型
#
# 用法:
#   DEEPSEEK_API_KEY=sk-xxx bash setup-ai-config.sh /path/to/vault
#   bash setup-ai-config.sh /path/to/vault --no-copilot
# ============================================================================
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
NC='\033[0m'

VAULT_PATH="${1:-}"
NO_COPILOT=false
for a in "$@"; do [[ "$a" == "--no-copilot" ]] && NO_COPILOT=true; done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "$VAULT_PATH" ]]; then
	echo "用法: DEEPSEEK_API_KEY=sk-xxx bash $0 /path/to/vault [--no-copilot]"
	exit 1
fi

AP_DIR="${VAULT_PATH}/.obsidian/plugins/ai-providers"
[[ -d "$AP_DIR" ]] || {
	echo "❌ 未找到 ai-providers 插件目录（先运行 setup-ai-plugins.sh）"
	exit 1
}

# ── 渲染 AI Providers 配置 ───────────────────────────────────────────────
DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-}"
sed -e "s|{{DEEPSEEK_API_KEY}}|${DEEPSEEK_KEY}|g" \
	-e "s|{{MIXAPI_API_KEY}}|${MIXAPI_API_KEY:-}|g" \
	"${SCRIPT_DIR}/../config/ai-providers.data.json" >"${AP_DIR}/data.json"
echo "  ✓ ai-providers/data.json 已生成"

# ── 可选: Copilot 配置 ───────────────────────────────────────────────────
if ! $NO_COPILOT; then
	CP_DIR="${VAULT_PATH}/.obsidian/plugins/copilot"
	if [[ -d "$CP_DIR" ]]; then
		cat >"${CP_DIR}/data.json" <<JSON
{
  "openAIApiBaseUrl": "https://api.deepseek.com/v1",
  "openAIApiKey": "${DEEPSEEK_KEY}",
  "defaultModel": "deepseek-v4-flash",
  "temperature": 0.3
}
JSON
		echo "  ✓ copilot/data.json 已生成 (DeepSeek)"
	fi
fi

cat <<EOF

${GREEN}============================================================${NC}
  AI 配置生成完成
${GREEN}============================================================${NC}
  AI Providers: ${AP_DIR}/data.json
    - DeepSeek (默认, deepseek-v4-flash)
    - MixAPI 网关 (<aliyun-ip>:3000)
    - Local vLLM (127.0.0.1:8001)

  下一步:
    1. Obsidian 设置 → AI Providers → 确认三个 provider
    2. 填入缺失的 API Key（DEEPSEEK_API_KEY / MIXAPI_API_KEY）
    3. Copilot 设置 → 选择 DeepSeek 作为默认模型
EOF
