#!/usr/bin/env bash
# ============================================================================
# install-mac-worker.sh — Mac mini 原生算力端安装（供 NAS 的 Immich 远程调用）
#
# 安装内容:
#   1. Ollama (原生, Metal GPU 加速) + qwen3-vl VLM 模型 → NAS 打标签用
#   2. immich-machine-learning (原生 Python + PyTorch MPS) → CLIP/人脸/对象检测
#
# 为什么原生而非 Docker: Docker Desktop for Mac 不支持 Metal GPU 加速
#
# 用法 (在 Mac mini 上执行):
#   bash install-mac-worker.sh                 # 安装全部 (默认模型: qwen3-vl:4b + moondream)
#   bash install-mac-worker.sh --ml-only       # 只装 Immich ML
#   bash install-mac-worker.sh --ollama-only   # 只装 Ollama
#   bash install-mac-worker.sh --model "qwen3-vl:7b moondream"  # 指定模型(空格分隔, 可多个)
#   bash install-mac-worker.sh --preset gpu    # 4090 服务器模型预设 (qwen3-vl:30b-a3b)
#   bash install-mac-worker.sh --status        # 查看服务状态
#
# 依赖: Homebrew (用于 Ollama), Python 3.10+
# ============================================================================
set -euo pipefail

DO_ML=true
DO_OLLAMA=true
VLM_MODELS="${VLM_MODELS:-qwen3-vl:4b-thinking-q4_K_M moondream}"
ML_PORT="${ML_PORT:-3003}"
ML_DIR="${ML_DIR:-$HOME/immich-machine-learning}"
DO_STATUS=false

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info() { echo -e "${GREEN}  [✓]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!]${NC} $*"; }
error() { echo -e "${RED}  [✗]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--ml-only) DO_OLLAMA=false ;;
	--ollama-only) DO_ML=false ;;
	--model)
		shift
		VLM_MODELS="$1"
		;;
	--preset)
		shift
		case "$1" in
		gpu) VLM_MODELS="qwen3-vl:30b-a3b-thinking-q4_K_M" ;;
		mac) VLM_MODELS="qwen3-vl:4b-thinking-q4_K_M moondream" ;;
		fast) VLM_MODELS="moondream" ;;
		*)
			error "未知预设: $1 (可用: gpu/mac/fast)"
			exit 1
			;;
		esac
		;;
	--status) DO_STATUS=true ;;
	--help | -h)
		sed -n '2,18p' "$0" | sed 's/^#//; s/^ //'
		exit 0
		;;
	*)
		error "未知参数: $1"
		exit 1
		;;
	esac
	shift
done

if $DO_STATUS; then
	echo "=== Ollama ==="
	curl -s --max-time 3 http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  models:", [m["name"] for m in d.get("models",[])])' 2>/dev/null || echo "  (未运行)"
	echo "=== Immich ML ==="
	curl -s --max-time 3 "http://127.0.0.1:${ML_PORT}/ping" 2>/dev/null | head -c 100 || echo "  (未运行)"
	echo ""
	exit 0
fi

# ── 1. Ollama ────────────────────────────────────────────────────────────
if $DO_OLLAMA; then
	echo -e "\n${GREEN}── 1/2 Ollama (Metal 加速) ──${NC}"
	if ! command -v ollama >/dev/null 2>&1; then
		if command -v brew >/dev/null 2>&1; then
			brew install ollama
		else
			info "未检测到 Homebrew，使用官方安装脚本"
			curl -fsSL https://ollama.com/install.sh | sh
		fi
	fi
	info "Ollama $(ollama --version 2>&1 | head -1)"
	if ! curl -s --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
		brew services start ollama 2>/dev/null || nohup ollama serve >/dev/null 2>&1 &
		sleep 5
	fi
	for m in $VLM_MODELS; do
		info "拉取模型 ${m}..."
		ollama pull "$m"
	done
	info "Ollama 就绪: http://127.0.0.1:11434 (模型: $VLM_MODELS)"
else
	info "跳过 Ollama"
fi

# ── 2. immich-machine-learning ───────────────────────────────────────────
if $DO_ML; then
	echo ""
	echo -e "\n${GREEN}── 2/2 immich-machine-learning (MPS 加速) ──${NC}"
	if [[ ! -d "$ML_DIR" ]]; then
		git clone --depth 1 https://github.com/immich-app/immich.git /tmp/immich-src 2>/dev/null || true
		mkdir -p "$ML_DIR"
		cp -r /tmp/immich-src/machine-learning/* "$ML_DIR/" 2>/dev/null || {
			error "Immich 源码拉取失败，请手动检查网络"
			exit 1
		}
		rm -rf /tmp/immich-src
	fi
	cd "$ML_DIR"
	if [[ ! -d .venv ]]; then
		python3 -m venv .venv
	fi
	source .venv/bin/activate
	pip install --quiet -r requirements.txt
	info "依赖安装完成"
	cat >run-ml.sh <<EOF
#!/bin/bash
cd "$ML_DIR"
source .venv/bin/activate
export MACHINE_LEARNING_CACHE_FOLDER="$ML_DIR/cache"
export TRANSFORMERS_CACHE="$ML_DIR/cache"
export PYTORCH_ENABLE_MPS_FALLBACK=1
exec python -m src.main --port ${ML_PORT}
EOF
	chmod +x run-ml.sh
	# launchd 常驻
	cat >"$HOME/Library/LaunchAgents/local.immich-ml.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.immich-ml</string>
	<key>ProgramArguments</key>
	<array>
		<string>${ML_DIR}/run-ml.sh</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
</dict>
</plist>
EOF
	launchctl load "$HOME/Library/LaunchAgents/local.immich-ml.plist" 2>/dev/null || true
	sleep 8
	curl -s --max-time 3 "http://127.0.0.1:${ML_PORT}/ping" >/dev/null 2>&1 && info "Immich ML 就绪: http://127.0.0.1:${ML_PORT}" || warn "ML 服务启动中，稍后检查: launchctl list | grep immich-ml"
else
	info "跳过 Immich ML"
fi

# ── 输出 ─────────────────────────────────────────────────────────────────
MAC_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<mac-lan-ip>")
echo ""
echo "══════════════════════════════════════════════════════════"
echo " Mac mini 算力端部署完成!"
echo ""
echo "  Ollama:      http://${MAC_IP}:11434"
echo "  Immich ML:   http://${MAC_IP}:${ML_PORT}"
echo ""
echo "  在 NAS 上执行部署 (指向本机):"
echo "    bash deploy-immich.sh --remote-ml http://${MAC_IP}:${ML_PORT} \\"
echo "                          --remote-ollama http://${MAC_IP}:11434"
echo ""
echo "  常驻管理:"
echo "    brew services list | grep ollama"
echo "    launchctl list | grep immich-ml"
echo "══════════════════════════════════════════════════════════"
