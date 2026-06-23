#!/usr/bin/env bash
# proxy-gen.sh — 聚合 Clash + ChromeGo 源，生成 sing-box 配置文件
#
# 流程:
#   1. bin/_fetch-clash          → 下载 Clash 源，生成 config.yaml
#   2. lib/source-chromego.sh   → 下载 ChromeGo 原生配置
#   3. lib/generate-config.py  → 合并并生成 sing-box config.json
#
# 用法:
#   bash proxy-gen.sh                              # 完整流程
#   bash proxy-gen.sh --configs /path/to/configs   # 指定配置目录
#   bash proxy-gen.sh --skip-clash                 # 跳过 Clash 源
#   bash proxy-gen.sh --skip-chromego              # 跳过 ChromeGo 源
#   bash proxy-gen.sh --deploy                     # 生成后重启 sing-box
#   bash proxy-gen.sh --help                       # 帮助

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/data/chromego_configs"
CLASH_YAML="${SCRIPT_DIR}/data/config.yaml"
OUTPUT="${CONFIGS_DIR}/config.json"

SKIP_CLASH=false
SKIP_CHROMEGO=false
DEPLOY=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}$1${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1" >&2; }
err()   { echo -e "  ${RED}✗${NC} $1" >&2; }

usage() {
    cat <<EOF
聚合 Clash + ChromeGo 源，生成 sing-box 配置文件。

用法: $(basename "$0") [选项]

选项:
  --configs DIR    指定 ChromeGo 配置目录 (默认 data/chromego_configs/)
  --skip-clash     跳过 Clash 源 (data/config.yaml)
  --skip-chromego  跳过 ChromeGo 源 (lib/source-chromego.sh)
  --deploy         生成后部署并重启 sing-box 服务
  -h, --help       显示此帮助

流程:
  1. bin/_fetch-clash           → Clash 源 → data/config.yaml
  2. lib/source-chromego.sh → ChromeGo 源 → data/chromego_configs/
  3. lib/generate-config.py → 合并 → sing-box config.json
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configs)      CONFIGS_DIR="$2"; shift 2 ;;
        --skip-clash)   SKIP_CLASH=true; shift ;;
        --skip-chromego) SKIP_CHROMEGO=true; shift ;;
        --deploy)       DEPLOY=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "未知选项: $1"; usage ;;
    esac
done

echo ""
echo "══════════════════════════════════════"
echo "  proxy-gen — sing-box 配置生成"
echo "══════════════════════════════════════"
echo ""

# ── 1. Clash 源 ─────────────────────────────────────────────────────
if [ "$SKIP_CLASH" = false ]; then
    if [ -f "$SCRIPT_DIR/bin/_fetch-clash" ]; then
        echo "[1/3] 下载 Clash 源..."
        bash "$SCRIPT_DIR/bin/_fetch-clash" || warn "_fetch-clash 执行失败，继续使用已有 config.yaml"
    else
        warn "bin/_fetch-clash 不存在，跳过 Clash 源"
    fi
else
    echo "[1/3] 跳过 Clash 源"
fi

# ── 2. ChromeGo 源 ──────────────────────────────────────────────────
if [ "$SKIP_CHROMEGO" = false ]; then
    echo ""
    echo "[2/3] 下载 ChromeGo 源..."
    if [ -f "$SCRIPT_DIR/lib/source-chromego.sh" ]; then
        bash "$SCRIPT_DIR/lib/source-chromego.sh" "$CONFIGS_DIR" || warn "source-chromego.sh 执行失败"
    else
        warn "lib/source-chromego.sh 不存在，跳过 ChromeGo 源"
    fi
else
    echo ""
    echo "[2/3] 跳过 ChromeGo 源"
fi

# ── 3. 生成 sing-box 配置 ───────────────────────────────────────────
echo ""
echo "[3/3] 生成 sing-box 配置..."

CLASH_ARGS=()
if [ -f "$CLASH_YAML" ]; then
    CLASH_ARGS=(--proxy-yaml "$CLASH_YAML")
fi

python3 "$SCRIPT_DIR/lib/generate-config.py" \
    --configs "$CONFIGS_DIR" \
    --output "$OUTPUT" \
    "${CLASH_ARGS[@]}"

# 后处理：归一化 server_port 为整数（某些 Clash 源导出字符串端口）
python3 -c "
import json, sys
with open('$OUTPUT') as f:
    c = json.load(f)
fixed = 0
for ob in c.get('outbounds', []):
    sp = ob.get('server_port')
    if sp is not None and isinstance(sp, str):
        try:
            ob['server_port'] = int(sp); fixed += 1
        except ValueError: pass
for ib in c.get('inbounds', []):
    lp = ib.get('listen_port')
    if lp is not None and isinstance(lp, str):
        try:
            ib['listen_port'] = int(lp); fixed += 1
        except ValueError: pass
if fixed:
    with open('$OUTPUT', 'w') as f:
        json.dump(c, f, indent=2)
    sys.stderr.write(f'  [port-normalize] fixed {fixed} entries\n')
"

echo ""
echo "  输出: $OUTPUT"

# ── 4. 部署 ─────────────────────────────────────────────────────────
if [ "$DEPLOY" = true ]; then
    echo ""
    echo "[部署] 重启 sing-box..."
    if command -v systemctl &>/dev/null; then
        sudo systemctl restart sing-box && ok "systemctl restart 完成"
    elif command -v launchctl &>/dev/null; then
        if launchctl kickstart "gui/$(id -u)/com.sing-box.chromego" 2>/dev/null; then
            ok "launchctl kickstart 完成"
        else
            warn "launchctl 重启失败，请手动重启"
        fi
    else
        if pkill -HUP sing-box 2>/dev/null; then
            ok "pkill -HUP sing-box 完成"
        else
            warn "未找到 sing-box 进程，请手动启动: sing-box run -c $OUTPUT"
        fi
    fi
fi

echo ""
echo "✅ 完成"
echo "💡 启动 sing-box:   sing-box run -c $OUTPUT"
echo "💡 Dashboard 地址:  http://127.0.0.1:9090/ui"
