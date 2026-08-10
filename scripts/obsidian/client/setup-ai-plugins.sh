#!/usr/bin/env bash
# ============================================================================
# setup-ai-plugins.sh — 一键安装 Obsidian AI 插件（阶段1）
#
# 安装:
#   1. Copilot for Obsidian       (logancyang/obsidian-copilot)  — vault RAG/总结
#   2. AI Providers               (pfrankov/obsidian-ai-providers) — 统一模型配置
#   3. Local GPT                  (pfrankov/obsidian-local-gpt)   — 选中文本 AI 动作
#
# 用法:
#   bash setup-ai-plugins.sh /path/to/vault
#
# 说明:
#   - 插件二进制从 GitHub release 下载（国内经 ghfast.top 镜像加速）
#   - 下载后写入 <vault>/.obsidian/plugins/<plugin>/
#   - 最后提示在 Obsidian 中启用插件（社区插件 → 启用）
# ============================================================================
set -euo pipefail

VAULT_PATH="${1:-}"
GH_MIRROR="${GH_MIRROR:-https://ghfast.top}"

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}  [WARN]${NC} $1"; }
ok() { echo -e "${GREEN}  ✓${NC} $1"; }

if [[ -z "$VAULT_PATH" ]]; then
	echo "用法: bash $0 /path/to/vault"
	echo "  GH_MIRROR=https://github.com bash $0 /path/to/vault  # 直连 GitHub"
	exit 1
fi

[[ -d "$VAULT_PATH/.obsidian" ]] || {
	echo "❌ 不是 Obsidian vault: $VAULT_PATH"
	exit 1
}

PLUGINS_DIR="${VAULT_PATH}/.obsidian/plugins"
mkdir -p "$PLUGINS_DIR"

# ── 插件定义: 名 | repo | 版本 ───────────────────────────────────────────
PLUGINS=(
	"copilot|logancyang/obsidian-copilot|3.3.3"
	"ai-providers|pfrankov/obsidian-ai-providers|1.10.0"
	"local-gpt|pfrankov/obsidian-local-gpt|4.2.2"
)

install_plugin() {
	local name="$1" repo="$2" version="$3"
	local dir="${PLUGINS_DIR}/${name}"
	mkdir -p "$dir"

	if [[ -f "$dir/main.js" ]]; then
		warn "$name 已安装 (跳过)"
		return
	fi

	local base="${GH_MIRROR}/https://github.com/${repo}/releases/download/${version}"
	info "下载 $name ($version) ..."
	curl -fsSL --connect-timeout 10 --max-time 120 "${base}/main.js" -o "$dir/main.js"
	curl -fsSL --connect-timeout 10 --max-time 60 "${base}/manifest.json" -o "$dir/manifest.json"
	curl -fsSL --connect-timeout 10 --max-time 60 "${base}/styles.css" -o "$dir/styles.css" || true
	ok "$name → $dir"
}

for p in "${PLUGINS[@]}"; do
	IFS='|' read -r name repo version <<<"$p"
	install_plugin "$name" "$repo" "$version"
done

# ── 更新 community-plugins.json ──────────────────────────────────────────
CP_FILE="${VAULT_PATH}/.obsidian/community-plugins.json"
if [[ -f "$CP_FILE" ]]; then
	python3 - "$CP_FILE" <<'PY'
import json, sys
path = sys.argv[1]
try:
    plugins = json.load(open(path))
except (json.JSONDecodeError, FileNotFoundError):
    plugins = []
for p in ["copilot", "ai-providers", "local-gpt"]:
    if p not in plugins:
        plugins.append(p)
json.dump(plugins, open(path, "w"), indent=2)
print(f"community-plugins.json 更新: {len(plugins)} 个插件")
PY
else
	cat >"$CP_FILE" <<'JSON'
["obsidian-local-rest-api", "dataview", "copilot", "ai-providers", "local-gpt"]
JSON
	ok "创建 community-plugins.json"
fi

cat <<EOF

${GREEN}============================================================${NC}
  AI 插件安装完成
${GREEN}============================================================${NC}
  插件目录: ${PLUGINS_DIR}
    - copilot      (v3.3.3)   vault RAG 问答 / 总结 / Agent
    - ai-providers (v1.10.0)  统一模型配置 (DeepSeek/OpenAI兼容/vLLM)
    - local-gpt    (v4.2.2)   选中文本 → 总结/改写/翻译

  下一步 (Obsidian 内操作):
    1. 打开 vault → 设置 → 第三方插件 → 已安装插件
    2. 启用 copilot / ai-providers / local-gpt 三个插件
    3. 配置模型:
       - AI Providers 添加 provider: DeepSeek 或 OpenAI-compatible
       - Copilot 设置 → 选择对应 provider 作为默认模型

  快速验证:
    Obsidian 中选中一段文本 → 右键 → Local GPT → Summarize
EOF
