#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# ChromeGo → sing-box 一键部署脚本
# ═══════════════════════════════════════════════════════════════════════
# 用法:
#   ./chromego-deploy.sh                         # 安装 sing-box + 生成配置 + 启动
#   ./chromego-deploy.sh --config-only            # 只生成配置文件
#   ./chromego-deploy.sh --configs /path/to/dir   # 指定配置目录
#   ./chromego-deploy.sh --port 1080              # 自定义代理端口
#   ./chromego-deploy.sh --install-cron           # 安装定时更新（每天04:00）
#   ./chromego-deploy.sh --no-cron                # 跳过定时更新安装
# ═══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/chromego_configs"
SINGBOX_BIN="${SINGBOX_BIN:-sing-box}"
SINGBOX_CONFIG="${CONFIGS_DIR}/config.json"
PORT=1080
DASHBOARD_PORT=9090
CONFIG_ONLY=false
INSTALL_CRON=true

# ── 参数解析 ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-only)    CONFIG_ONLY=true; shift ;;
    --configs)        CONFIGS_DIR="$2"; shift 2 ;;
    --port)           PORT="$2"; shift 2 ;;
    --dashboard-port) DASHBOARD_PORT="$2"; shift 2 ;;
    --install-cron)   INSTALL_CRON=true; shift ;;
    --no-cron)        INSTALL_CRON=false; shift ;;
    -h|--help)        head -20 "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ── 颜色输出 ──────────────────────────────────────────────────────────

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# ═══════════════════════════════════════════════════════════════════════
# 1. 生成配置
# ═══════════════════════════════════════════════════════════════════════

step_config() {
  echo ""
  info "=== [1/4] 生成 sing-box 配置 ==="

  local gen_script="${SCRIPT_DIR}/chromego-gen-config.py"
  if [[ ! -f "$gen_script" ]]; then
    err "未找到 ${gen_script}"
    echo "请先运行 chromego-source.sh 下载 ChromeGo 源"
    exit 1
  fi

  python3 "$gen_script" \
    --configs "$CONFIGS_DIR" \
    --output "$SINGBOX_CONFIG"

  # 替换端口为用户指定值
  if [[ "$PORT" != "1080" ]]; then
    sed -i "s/\"listen_port\": 1080/\"listen_port\": $PORT/" "$SINGBOX_CONFIG"
  fi
  if [[ "$DASHBOARD_PORT" != "9090" ]]; then
    sed -i "s/\"external_controller\": \"127.0.0.1:9090\"/\"external_controller\": \"127.0.0.1:$DASHBOARD_PORT\"/" "$SINGBOX_CONFIG"
  fi

  ok "配置文件: ${SINGBOX_CONFIG}"
}

# ═══════════════════════════════════════════════════════════════════════
# 2. 安装 sing-box
# ═══════════════════════════════════════════════════════════════════════

step_install() {
  echo ""
  info "=== [2/4] 安装 sing-box ==="

  if command -v sing-box &>/dev/null; then
    local ver
    ver=$(sing-box version 2>/dev/null | head -1 || echo "已安装")
    ok "sing-box ${ver}"
    return
  fi

  # GitHub 最新版本
  info "下载 sing-box 最新版本..."

  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)   arch="amd64" ;;
    aarch64)  arch="arm64" ;;
    armv7l)   arch="armv7" ;;
    *)        err "不支持的架构: $arch"; exit 1 ;;
  esac

  local tmpdir
  tmpdir=$(mktemp -d)
  cd "$tmpdir"

  # 获取最新 release 下载链接
  local download_url
  download_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep "browser_download_url" \
    | grep "linux-${arch}" \
    | grep -v "go120" \
    | head -1 \
    | cut -d'"' -f4)

  if [[ -z "$download_url" ]]; then
    err "无法获取下载链接"
    exit 1
  fi

  info "下载: ${download_url}"
  curl -L -o sing-box.tar.gz "$download_url"
  tar -xzf sing-box.tar.gz
  sudo mv sing-box*/sing-box /usr/local/bin/
  rm -rf "$tmpdir"

  if command -v sing-box &>/dev/null; then
    ok "sing-box $(sing-box version 2>/dev/null | head -1) 已安装到 /usr/local/bin/"
  else
    err "安装失败"
    exit 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# 3. 配置 systemd 服务
# ═══════════════════════════════════════════════════════════════════════

step_service() {
  echo ""
  info "=== [3/4] 配置 systemd 服务 ==="

  # 检查 systemd
  if ! command -v systemctl &>/dev/null; then
    warn "无 systemd，跳过服务配置"
    warn "手动启动: sing-box run -c ${SINGBOX_CONFIG}"
    return
  fi

  local unit_name="sing-box-chromego"
  local unit_file="/etc/systemd/system/${unit_name}.service"

  if [[ -f "$unit_file" ]]; then
    ok "服务单元已存在: ${unit_name}"
  else
    info "创建 systemd 服务单元..."

    # 创建运行用户（如果不存在）
    if ! id -u sing-box &>/dev/null 2>&1; then
      sudo useradd -r -s /usr/sbin/nologin sing-box 2>/dev/null || true
    fi

    sudo tee "$unit_file" > /dev/null <<EOF
[Unit]
Description=ChromeGo sing-box Proxy
Documentation=https://sing-box.sagernet.org
After=network.target

[Service]
Type=simple
User=sing-box
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    ok "服务单元已创建: ${unit_name}"
  fi

  info "启动服务..."
  sudo systemctl enable "${unit_name}" 2>/dev/null || true
  sudo systemctl restart "${unit_name}" 2>/dev/null || true
  sleep 2

  if sudo systemctl is-active --quiet "${unit_name}"; then
    ok "sing-box 服务运行中"
  else
    warn "服务启动异常，查看日志: sudo journalctl -u ${unit_name} -n 50 --no-pager"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# 4. 输出信息
# ═══════════════════════════════════════════════════════════════════════

step_info() {
  echo ""
  info "=== [4/4] 部署信息 ==="

  local count
  count=$(python3 -c "
import json
c = json.load(open('${SINGBOX_CONFIG}'))
proxies = [ob for ob in c['outbounds']
           if ob['type'] not in ('selector','urltest','direct')]
print(len(proxies))
" 2>/dev/null || echo "?")

  echo ""
  echo "  代理端口:     ${BLUE}socks5+http :${PORT}${NC}"
  echo "  Dashboard:    ${BLUE}http://127.0.0.1:${DASHBOARD_PORT}/ui${NC}"
  echo "  代理节点:     ${count} 个"
  echo "  配置文件:     ${SINGBOX_CONFIG}"
  echo ""
  echo "  常用命令:"
  echo "    启动:         sing-box run -c ${SINGBOX_CONFIG}"
  echo "    检查配置:     sing-box check -c ${SINGBOX_CONFIG}"
  echo "    查看日志:     sudo journalctl -u sing-box-chromego -f"
  echo ""
  echo "  测试代理:"
  echo "    curl --proxy socks5://127.0.0.1:${PORT} http://cp.cloudflare.com/generate_204"
  echo "    curl --proxy http://127.0.0.1:${PORT} https://www.google.com"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

main() {
  echo "╔══════════════════════════════════════════════════╗"
  echo "║   ChromeGo → sing-box 一键部署                   ║"
  echo "╚══════════════════════════════════════════════════╝"

  step_config
  if $CONFIG_ONLY; then
    echo ""
    ok "配置生成完成（--config-only，跳过安装/部署）"
    exit 0
  fi

  step_install
  step_service

  # ── 安装定时更新 cron ──
  if $INSTALL_CRON; then
    echo ""
    info "=== 安装定时更新（每天 04:00）==="
    info "  （临时目录下载 → 验证 → 原子替换 — 不重启服务，不影响现有连接）"
    local cron_script="${SCRIPT_DIR}/chromego-update-cron.sh"
    if [[ -f "$cron_script" ]]; then
      bash "$cron_script" --install-cron
    else
      warn "未找到 chromego-update-cron.sh，跳过定时安装"
    fi
  fi

  step_info
}

main
