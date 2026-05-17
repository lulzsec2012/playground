#!/usr/bin/env bash
# File Server — Tailscale 节点部署脚本
# 在 ECS 上安装 Tailscale 原生客户端（非 Docker），加入 tailnet
# 用法: bash deploy-tailscale.sh [--hostname fileserver]
#
# 依赖:
#   - data/vpn.cfg 文件中配置了 TAILSCALE_AUTH_KEY
#   - root 或 sudo 权限

set -euo pipefail

# === 配置 ===
TAILSCALE_BIN="/usr/local/bin/tailscale"
TAILSCALED_BIN="/usr/local/bin/tailscaled"
SERVICE_FILE="/etc/systemd/system/tailscaled.service"
TAILSCALE_VERSION="${TAILSCALE_VERSION:-stable}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYGROUND_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# 自动探测 vpn.cfg：优先 playground/data/vpn.cfg，回退 scripts/docker/data/
if [ -f "${PLAYGROUND_DIR}/data/vpn.cfg" ]; then
    VPN_CFG="${PLAYGROUND_DIR}/data/vpn.cfg"
else
    VPN_CFG="${PLAYGROUND_DIR}/scripts/docker/data/vpn.cfg"
fi

# === 辅助函数 ===

usage() {
    cat <<EOF
部署 Tailscale 原生节点

用法: bash $(basename "$0") [选项]

选项:
  -n, --hostname <name>   Tailscale 节点名（默认: fileserver）
  -h, --help              显示此帮助

环境变量（从 data/vpn.cfg 自动读取，也可手动覆盖）:
  TAILSCALE_AUTH_KEY   认证密钥
  TAILSCALE_HOSTNAME   节点主机名

示例:
  bash deploy-tailscale.sh
  bash deploy-tailscale.sh -n my-server
  TAILSCALE_AUTH_KEY=tskey-auth-xxx bash deploy-tailscale.sh
EOF
    exit 1
}

# === 参数解析 ===

HOSTNAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--hostname)  HOSTNAME="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "未知选项: $1" >&2; usage ;;
    esac
done

# === 加载 VPN 配置 ===

load_vpn_config() {
    if [ -f "$VPN_CFG" ]; then
        echo ">>> 加载 VPN 配置: $VPN_CFG"
        source "$VPN_CFG"
    else
        echo "  未找到 $VPN_CFG，依赖环境变量 TAILSCALE_AUTH_KEY"
    fi

    # 环境变量可覆盖配置文件
    TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
    HOSTNAME="${HOSTNAME:-${TAILSCALE_HOSTNAME:-fileserver}}"

    if [ -z "$TAILSCALE_AUTH_KEY" ]; then
        echo "❌ 错误: 未设置 TAILSCALE_AUTH_KEY" >&2
        echo "   请在 data/vpn.cfg 中配置或通过环境变量传入" >&2
        exit 1
    fi
}

# === 前提检查 ===

check_prerequisites() {
    local missing=0

    if ! command -v curl &>/dev/null; then
        echo "❌ 请安装 curl" >&2
        missing=1
    fi

    if ! command -v systemctl &>/dev/null; then
        echo "❌ 需要 systemd（不兼容的发行版）" >&2
        missing=1
    fi

    if ! sudo -n true 2>/dev/null; then
        echo "⚠️  当前用户可能没有无密码 sudo"
    fi

    # 检查是否已安装
    if [ -f "$TAILSCALED_BIN" ]; then
        echo "⚠️  Tailscale 已安装，将检查是否需要更新"
    fi

    [ $missing -eq 1 ] && exit 1
    echo "✅ 前提检查通过"
}

# === 步骤实现 ===

step_download_tailscale() {
    echo ""
    echo ">>> [Step 1/5] 下载 Tailscale ${TAILSCALE_VERSION}"

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)       echo "❌ 不支持的架构: $arch" >&2; exit 1 ;;
    esac

    local url="https://pkgs.tailscale.com/${TAILSCALE_VERSION}/tailscale-${TAILSCALE_VERSION}-${arch}.tgz"
    # 如果是 stable，改用不带版本号的下载路径
    if [ "$TAILSCALE_VERSION" = "stable" ]; then
        # 从 GitHub 获取最新稳定版
        echo "  获取最新稳定版版本号..."
        local latest
        latest="$(curl -sfI https://github.com/tailscale/tailscale/releases/latest 2>/dev/null | grep -i 'location:' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
        if [ -z "$latest" ]; then
            latest="v1.80.0"  # fallback
            echo "  无法获取最新版，使用 ${latest} 作为默认值"
        else
            echo "  最新版本: ${latest}"
        fi
        url="https://pkgs.tailscale.com/${latest}/tailscale-${latest}-${arch}.tgz"
    fi

    # 检查是否已有对应版本
    if [ -f "$TAILSCALED_BIN" ]; then
        local current_ver
        current_ver="$("$TAILSCALE_BIN" version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
        local target_ver
        target_ver="$(echo "$url" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
        if [ -n "$current_ver" ] && [ "$current_ver" = "$target_ver" ]; then
            echo "  Tailscale ${current_ver} 已是最新，跳过下载"
            return
        fi
        echo "  发现 ${current_ver:-旧版本}，更新中..."
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  下载: $url"
    curl -fsSL "$url" -o "$tmpdir/tailscale.tgz" || {
        echo "❌ 下载失败" >&2
        rm -rf "$tmpdir"
        exit 1
    }

    tar xzf "$tmpdir/tailscale.tgz" -C "$tmpdir"
    local extracted_dir
    extracted_dir="$(find "$tmpdir" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"

    if [ -n "$extracted_dir" ]; then
        sudo mv "$extracted_dir/tailscale" "$TAILSCALE_BIN"
        sudo mv "$extracted_dir/tailscaled" "$TAILSCALED_BIN"
    else
        # 直接解压（某些版本结构不同）
        sudo mv "$tmpdir/tailscale" "$TAILSCALE_BIN" 2>/dev/null || true
        sudo mv "$tmpdir/tailscaled" "$TAILSCALED_BIN" 2>/dev/null || true
    fi

    sudo chmod +x "$TAILSCALE_BIN" "$TAILSCALED_BIN"
    rm -rf "$tmpdir"

    echo "  Tailscale 已安装: $("$TAILSCALE_BIN" version 2>&1 | head -1)"
}

step_install_systemd_service() {
    echo ""
    echo ">>> [Step 2/5] 注册 systemd 服务"

    if systemctl is-active tailscaled &>/dev/null; then
        sudo systemctl stop tailscaled
        echo "  旧服务已停止"
    fi

    if [ ! -f "$SERVICE_FILE" ]; then
        sudo tee "$SERVICE_FILE" >/dev/null <<'SERVICE'
[Unit]
Description=Tailscale node agent
Documentation=https://tailscale.com/kb/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/tailscaled
Environment="PATH=/usr/bin:/bin:/usr/local/bin"
Restart=always
RestartSec=5
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
SERVICE
        echo "  服务文件已创建"
    else
        echo "  服务文件已存在，跳过"
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable tailscaled
    echo "  服务已启用"
}

step_start_tailscaled() {
    echo ""
    echo ">>> [Step 3/5] 启动 tailscaled"

    sudo systemctl start tailscaled
    sleep 2

    if systemctl is-active tailscaled &>/dev/null; then
        echo "  ✅ tailscaled 运行中"
    else
        echo "  ❌ tailscaled 启动失败，请检查: systemctl status tailscaled" >&2
        exit 1
    fi
}

step_authenticate() {
    echo ""
    echo ">>> [Step 4/5] 认证并加入 tailnet"

    # 检查是否已认证
    if "$TAILSCALE_BIN" status 2>/dev/null | grep -q "$HOSTNAME"; then
        echo "  节点 ${HOSTNAME} 已在 tailnet 中，跳过认证"
        return
    fi

    echo "  使用 auth key 认证..."
    sudo "$TAILSCALE_BIN" up \
        --authkey="$TAILSCALE_AUTH_KEY" \
        --hostname="$HOSTNAME" \
        --accept-routes || {
        echo "❌ 认证失败" >&2
        echo "   请检查 TAILSCALE_AUTH_KEY 是否有效" >&2
        echo "   或手动运行: sudo tailscale up --hostname=${HOSTNAME}" >&2
        exit 1
    }

    sleep 3
    echo "  ✅ 认证成功"
}

step_verify() {
    echo ""
    echo ">>> [Step 5/5] 验证部署"

    local node_ip
    node_ip="$("$TAILSCALE_BIN" status 2>/dev/null | grep "^100\." | grep "$HOSTNAME" | awk '{print $1}')"

    if [ -n "$node_ip" ]; then
        echo "  ✅ 节点在线: ${HOSTNAME} (${node_ip})"
    else
        echo "  ⚠️  节点状态待确认，请手动检查: tailscale status" >&2
    fi

    echo "  ✅ tailscale ping 测试: $("$TAILSCALE_BIN" ping -c 1 "$HOSTNAME" 2>/dev/null | head -1 || echo "跳过")"
}

# === 主流程 ===

main() {
    echo "========================================"
    echo "  File Server — Tailscale 节点部署"
    echo "========================================"
    echo ""

    load_vpn_config
    check_prerequisites
    step_download_tailscale
    step_install_systemd_service
    step_start_tailscaled
    step_authenticate
    step_verify

    echo ""
    echo "========================================"
    echo "  ✅ Tailscale 部署完成"
    echo "  节点名: ${HOSTNAME}"
    echo "  管理台: https://login.tailscale.com/admin/machines"
    echo "========================================"
}

main "$@"
