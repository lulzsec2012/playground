#!/usr/bin/env bash
# File Server — 一键部署脚本
# 在 Nginx + Tailscale 就绪的 ECS 上部署 Filebrowser 和分享工具
# 用法: bash deploy-server.sh

set -euo pipefail

# === 配置 ===
FILEBROWSER_VERSION="v2.31.2"
FILEBROWSER_BIN="/usr/local/bin/filebrowser"
FILEBROWSER_DB="/data/filebrowser.db"
FILES_ROOT="/data/files"
SHARE_DIR="$FILES_ROOT/.shares"
SHARES_CONF_DIR="/etc/nginx/shares.d"
FILEBROWSER_USER="fileserver"
SITE_CONF_NAME="fileserver"
DEPLOY_STATE_DIR="/var/lib/fileserver/deploy-status"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/filebrowser-site.conf.template"
HELPER_SRC="$SCRIPT_DIR/fs-share-helper.sh"
HELPER_DST="/usr/local/bin/fs-share-helper"
CLEANUP_SRC="$SCRIPT_DIR/fs-share-cleanup.sh"
CLEANUP_DST="/usr/local/bin/fs-share-cleanup"

# === 前提检查 ===

check_prerequisites() {
    local missing=0

    if ! command -v nginx &>/dev/null; then
        echo "❌ Nginx 未安装。请先执行 install-nginx.sh" >&2
        missing=1
    fi

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo "❌ 请安装 curl 或 wget" >&2
        missing=1
    fi

    if ! command -v tailscale &>/dev/null; then
        echo "⚠️  Tailscale 未安装，内网访问需手动配置 FS_HOST"
    fi

    # 检查是否为 root 或有无 sudo
    if ! sudo -n true 2>/dev/null; then
        echo "⚠️  当前用户可能没有无密码 sudo，部分操作可能需要交互输入密码"
    fi

    # DNS 解析检查
    if ! host github.com &>/dev/null && ! nslookup github.com &>/dev/null; then
        echo "❌ 无法解析 github.com，请检查 DNS 配置" >&2
        missing=1
    fi

    # 磁盘空间检查
    if [ ! -d "/data" ]; then
        echo "  /data 不存在，创建中..."
        sudo mkdir -p /data
    fi
    if ! df -BG /data | awk 'NR==2 {gsub(/[A-Z]/,"",$4); if ($4+0 < 1) exit 1}'; then
        echo "❌ /data 可用空间不足 1GB" >&2
        missing=1
    fi

    # 网络连通性检查
    if ! curl -sfI --max-time 5 https://github.com &>/dev/null; then
        echo "❌ 无法访问 github.com，请检查网络连接" >&2
        missing=1
    fi

    [ $missing -eq 1 ] && exit 1

    echo "✅ 前提检查通过"
}

# === 步骤实现 ===

step_download_filebrowser() {
    local marker="${DEPLOY_STATE_DIR}/step-01-download"
    if [ -f "$marker" ]; then
        echo "  Step 1 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 1/9] 下载 Filebrowser ${FILEBROWSER_VERSION}"

    if [ -f "$FILEBROWSER_BIN" ]; then
        local current_ver
        current_ver="$("$FILEBROWSER_BIN" version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
        if [ "$current_ver" = "$FILEBROWSER_VERSION" ]; then
            echo "  Filebrowser ${current_ver} 已存在，跳过下载"
            echo "done" | sudo tee "$marker" >/dev/null
            return
        fi
        echo "  发现旧版本 ${current_ver:-unknown}，更新中..."
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)       echo "Error: 不支持的架构: $arch" >&2; exit 1 ;;
    esac

    local url="https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-${arch}-filebrowser.tar.gz"
    local tmpdir
    tmpdir="$(mktemp -d)"

    echo "  下载: $url"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$tmpdir/filebrowser.tar.gz"
    else
        wget -q "$url" -O "$tmpdir/filebrowser.tar.gz"
    fi

    tar xzf "$tmpdir/filebrowser.tar.gz" -C "$tmpdir"
    sudo mv "$tmpdir/filebrowser" "$FILEBROWSER_BIN"
    sudo chmod +x "$FILEBROWSER_BIN"
    rm -rf "$tmpdir"

    echo "  Filebrowser 已安装: $("$FILEBROWSER_BIN" version 2>&1 | head -1)"

    echo "done" | sudo tee "$marker" >/dev/null
}

step_create_system_user() {
    local marker="${DEPLOY_STATE_DIR}/step-02-system-user"
    if [ -f "$marker" ]; then
        echo "  Step 2 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 2/9] 创建系统用户和目录"

    # 创建系统用户
    if id "$FILEBROWSER_USER" &>/dev/null; then
        echo "  用户 $FILEBROWSER_USER 已存在，跳过"
    else
        sudo useradd -r -s /usr/sbin/nologin "$FILEBROWSER_USER"
        echo "  用户 $FILEBROWSER_USER 已创建"
    fi

    # 创建存储目录
    sudo mkdir -p "$FILES_ROOT"
    sudo mkdir -p "$SHARE_DIR"

    # 设置属主
    sudo chown -R "$FILEBROWSER_USER:$FILEBROWSER_USER" "$FILES_ROOT"
    echo "  目录 $FILES_ROOT 已就绪"

    echo "done" | sudo tee "$marker" >/dev/null
}

step_record_public_ip() {
    local marker="${DEPLOY_STATE_DIR}/step-03-public-ip"
    if [ -f "$marker" ]; then
        echo "  Step 3 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 3/9] 记录公网 IP"

    local ip=""
    ip="$(curl -sf --max-time 5 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || curl -sf --max-time 10 https://ifconfig.me 2>/dev/null || curl -sf --max-time 10 https://api.ipify.org 2>/dev/null || echo "")"

    if [ -n "$ip" ]; then
        echo "$ip" | sudo tee "$FILES_ROOT/public-ip.txt" >/dev/null
        echo "  公网 IP: $ip"
    else
        echo "  ⚠️  无法获取公网 IP，后续分享功能可能受限"
        echo "  可手动: curl ifconfig.me | sudo tee $FILES_ROOT/public-ip.txt"
    fi

    echo "done" | sudo tee "$marker" >/dev/null
}

step_configure_filebrowser() {
    local marker="${DEPLOY_STATE_DIR}/step-04-configure"
    if [ -f "$marker" ]; then
        echo "  Step 4 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 4/9] 配置 Filebrowser"

    # 停掉运行中的服务和孤儿进程，释放数据库锁
    sudo systemctl stop filebrowser 2>/dev/null || true
    sudo pkill -u fileserver filebrowser 2>/dev/null || true
    sleep 1

    # 生成随机密码
    local admin_pass
    admin_pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || openssl rand -base64 12 | tr -d '/+=' | head -c 16)"

    # 初始化配置
    sudo "$FILEBROWSER_BIN" config init --database="$FILEBROWSER_DB" 2>/dev/null || true

    sudo "$FILEBROWSER_BIN" config set \
        --database="$FILEBROWSER_DB" \
        --address=127.0.0.1 \
        --port=8081 \
        --root="$FILES_ROOT" \
        --perm.admin=true \
        --baseurl=/ \
        2>/dev/null

    # 创建 admin 用户并设置密码（幂等处理）
    if sudo "$FILEBROWSER_BIN" users ls --database="$FILEBROWSER_DB" 2>/dev/null | grep -q "admin"; then
        sudo "$FILEBROWSER_BIN" users reset \
            admin \
            --database="$FILEBROWSER_DB" \
            --password="$admin_pass" \
            2>/dev/null
        echo "  用户密码已更新"
    else
        sudo "$FILEBROWSER_BIN" users add \
            admin "$admin_pass" \
            --database="$FILEBROWSER_DB" \
            --perm.admin=true \
            2>/dev/null
        echo "  用户 admin 已创建"
    fi

    # 密码仅在部署时打印到终端，不留文件（.admin-cred 曾保存在 /data/files/ 下，
    # 但该目录是 Filebrowser document root，属于暴露风险）

    # 修复文件所有权
    sudo chown -R "$FILEBROWSER_USER:$FILEBROWSER_USER" "$FILES_ROOT" "$FILEBROWSER_DB"
    echo "  文件所有权已修复"

    echo "  Filebrowser 配置完成"
    echo "  🔑 初始密码: $admin_pass"

    echo "done" | sudo tee "$marker" >/dev/null
}

step_install_systemd_service() {
    local marker="${DEPLOY_STATE_DIR}/step-05-systemd-service"
    if [ -f "$marker" ]; then
        echo "  Step 5 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 5/9] 注册 systemd 服务"

    local service_file="/etc/systemd/system/filebrowser.service"

    # 如果服务已存在，先停止
    if systemctl is-active filebrowser &>/dev/null; then
        sudo systemctl stop filebrowser
        echo "  旧服务已停止"
    fi

    sudo tee "$service_file" >/dev/null <<SERVICE
[Unit]
Description=Filebrowser — File Server Web UI
After=network.target

[Service]
ExecStart=$FILEBROWSER_BIN --database=$FILEBROWSER_DB
User=$FILEBROWSER_USER
Group=$FILEBROWSER_USER
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable --now filebrowser

    # 验证运行状态
    sleep 2
    if systemctl is-active filebrowser &>/dev/null; then
        echo "  ✅ Filebrowser 服务运行中"
    else
        echo "  ❌ Filebrowser 服务启动失败，请检查: systemctl status filebrowser" >&2
        exit 1
    fi

    echo "done" | sudo tee "$marker" >/dev/null
}

step_install_share_helper() {
    local marker="${DEPLOY_STATE_DIR}/step-06-share-helper"
    if [ -f "$marker" ]; then
        echo "  Step 6 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 6/9] 安装分享管理脚本"

    if [ -f "$HELPER_SRC" ]; then
        sudo cp "$HELPER_SRC" "$HELPER_DST"
        sudo chmod +x "$HELPER_DST"
        echo "  fs-share-helper.sh 已安装到 $HELPER_DST"

        # 配置 sudoers 白名单
        local sudoers_file="/etc/sudoers.d/fs-share-helper"
        local current_user
        current_user="$(whoami)"

        if [ ! -f "$sudoers_file" ]; then
            echo "$current_user ALL=(ALL) NOPASSWD: $HELPER_DST" | sudo tee "$sudoers_file" >/dev/null
            sudo chmod 440 "$sudoers_file"
            echo "  sudoers 白名单已配置"
        else
            echo "  sudoers 白名单已存在，跳过"
        fi

        # 验证
        echo "  验证: $(sudo $HELPER_DST --help 2>&1 | head -1)"
    else
        echo "  ⚠️  未找到 $HELPER_SRC，跳过"
    fi

    echo "done" | sudo tee "$marker" >/dev/null
}

step_install_cleanup_cron() {
    local marker="${DEPLOY_STATE_DIR}/step-07-cleanup-cron"
    if [ -f "$marker" ]; then
        echo "  Step 7 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 7/9] 安装分享清理脚本 + crontab"

    if [ -f "$CLEANUP_SRC" ]; then
        sudo cp "$CLEANUP_SRC" "$CLEANUP_DST"
        sudo chmod +x "$CLEANUP_DST"
        echo "  fs-share-cleanup.sh 已安装到 $CLEANUP_DST"

        local cron_job="*/5 * * * * root $CLEANUP_DST >/dev/null 2>&1"
        if [ -f /etc/crontab ] && ! grep -qF "$CLEANUP_DST" /etc/crontab 2>/dev/null; then
            echo "$cron_job" | sudo tee -a /etc/crontab >/dev/null
            echo "  crontab 已添加（每 5 分钟）"
        elif grep -qF "$CLEANUP_DST" /etc/crontab 2>/dev/null; then
            echo "  crontab 已存在，跳过"
        else
            echo "  ⚠️  无法写入 /etc/crontab，请手动添加:"
            echo "     ${cron_job}"
        fi
    else
        echo "  ⚠️  未找到 $CLEANUP_SRC，跳过"
    fi

    echo "done" | sudo tee "$marker" >/dev/null
}

step_generate_nginx_site() {
    local marker="${DEPLOY_STATE_DIR}/step-08-nginx-site"
    if [ -f "$marker" ]; then
        echo "  Step 8 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 8/9] 生成 Nginx site 配置"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        echo "  ⚠️  未找到模板文件 $TEMPLATE_FILE，跳过" >&2
        return
    fi

    # 从模板生成 site 配置（替换变量）
    local site_file="/etc/nginx/sites-available/$SITE_CONF_NAME"
    sudo cp "$TEMPLATE_FILE" "$site_file"

    # 如果有公网 IP，替换模板中的占位符
    if [ -f "$FILES_ROOT/public-ip.txt" ]; then
        local public_ip
        public_ip="$(cat "$FILES_ROOT/public-ip.txt")"
        sudo sed -i "s/{{PUBLIC_IP}}/$public_ip/g" "$site_file" 2>/dev/null || true
    fi

    echo "  Nginx site 配置已生成: $site_file"

    echo "done" | sudo tee "$marker" >/dev/null
}

step_enable_site() {
    local marker="${DEPLOY_STATE_DIR}/step-09-enable-site"
    if [ -f "$marker" ]; then
        echo "  Step 9 已完成，跳过"
        return
    fi

    echo ""
    echo ">>> [Step 9/9] 启用 Nginx site"

    local site_available="/etc/nginx/sites-available/$SITE_CONF_NAME"
    local site_enabled="/etc/nginx/sites-enabled/$SITE_CONF_NAME"

    if [ -f "$site_available" ]; then
        sudo ln -sf "$site_available" "$site_enabled"
        echo "  Site 已启用"

        # 语法检查
        sudo nginx -t || {
            echo "  ❌ Nginx 配置测试失败，请检查" >&2
            exit 1
        }

        # 重载 Nginx
        sudo systemctl reload nginx || sudo nginx -s reload
        echo "  Nginx 已重载"
    fi

    echo "done" | sudo tee "$marker" >/dev/null
}

step_print_result() {
    echo ""
    echo "========================================"
    echo "  ✅ File Server 部署完成"
    echo "========================================"

    local public_ip=""
    [ -f "$FILES_ROOT/public-ip.txt" ] && public_ip="$(cat "$FILES_ROOT/public-ip.txt")"

    if systemctl is-active tailscale &>/dev/null; then
        echo "  🌐 Tailscale:  http://fileserver:8080"
    fi

    if [ -n "$public_ip" ]; then
        echo "  🌐 Nginx 公网: http://${public_ip}:8080"
        echo "     (仅 Tailscale 内网可访问)"
    fi

    echo "  🔑 管理密码已在 [Step 4/9] 中显示，请保存到密码管理器"

    echo "  🔌 SSH 通道就绪: ssh $(whoami)@$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "  🔌 fs-share-helper: $(sudo $HELPER_DST --help 2>&1 | head -1)"
    echo ""
    echo "  下一步: 在开发机上配置客户端"
    echo "  cd /path/to/scripts/fileserver/client/"
    echo "  cp fileserver.conf.TEMPLATE fileserver.conf"
    echo "  # 编辑 fileserver.conf 后执行:"
    echo "  bash install-path.sh && source ~/.zshrc"
    echo "========================================"
}

# === 帮助信息 ===

usage() {
    echo "用法: bash deploy-server.sh [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  --undo         回滚部署（按完成步骤的逆序依次撤销）"
    echo ""
    echo "部署步骤:"
    echo "  Step 1/9 — 下载 Filebrowser"
    echo "  Step 2/9 — 创建系统用户和目录"
    echo "  Step 3/9 — 记录公网 IP"
    echo "  Step 4/9 — 配置 Filebrowser"
    echo "  Step 5/9 — 注册 systemd 服务"
    echo "  Step 6/9 — 安装分享管理脚本"
    echo "  Step 7/9 — 安装分享清理脚本 + crontab"
    echo "  Step 8/9 — 生成 Nginx site 配置"
    echo "  Step 9/9 — 启用 Nginx site"
    echo ""
    echo "回滚步骤:"
    echo "  撤销 Step 9 → Step 8 → ... → Step 1（逆序执行）"
}

# === 回滚 ===

undo() {
    echo "========================================"
    echo "  File Server — 回滚部署"
    echo "========================================"
    echo ""

    # 按逆序读取 marker 文件
    for step in 09 08 07 06 05 04 03 02 01; do
        local marker_file
        case "$step" in
            09) marker_file="${DEPLOY_STATE_DIR}/step-09-enable-site" ;;
            08) marker_file="${DEPLOY_STATE_DIR}/step-08-nginx-site" ;;
            07) marker_file="${DEPLOY_STATE_DIR}/step-07-cleanup-cron" ;;
            06) marker_file="${DEPLOY_STATE_DIR}/step-06-share-helper" ;;
            05) marker_file="${DEPLOY_STATE_DIR}/step-05-systemd-service" ;;
            04) marker_file="${DEPLOY_STATE_DIR}/step-04-configure" ;;
            03) marker_file="${DEPLOY_STATE_DIR}/step-03-public-ip" ;;
            02) marker_file="${DEPLOY_STATE_DIR}/step-02-system-user" ;;
            01) marker_file="${DEPLOY_STATE_DIR}/step-01-download" ;;
        esac

        if [ ! -f "$marker_file" ]; then
            continue
        fi

        echo ">>> 撤销 Step ${step}..."

        case "$step" in
            09)
                echo "  关闭 Nginx site 配置…"
                sudo rm -f "/etc/nginx/sites-enabled/$SITE_CONF_NAME"
                sudo systemctl reload nginx 2>/dev/null || sudo nginx -s reload 2>/dev/null || true
                ;;
            08)
                echo "  移除 Nginx site 配置…"
                sudo rm -f "/etc/nginx/sites-available/$SITE_CONF_NAME"
                ;;
            07)
                echo "  移除清理脚本和 crontab…"
                sudo rm -f "$CLEANUP_DST"
                if [ -f /etc/crontab ]; then
                    sudo sed -i "\|${CLEANUP_DST}|d" /etc/crontab
                fi
                ;;
            06)
                echo "  移除分享管理脚本和 sudoers…"
                sudo rm -f "$HELPER_DST"
                sudo rm -f "/etc/sudoers.d/fs-share-helper"
                ;;
            05)
                echo "  停止并移除 filebrowser 服务…"
                sudo systemctl stop filebrowser 2>/dev/null || true
                sudo rm -f "/etc/systemd/system/filebrowser.service"
                sudo systemctl daemon-reload
                ;;
            04)
                echo "  删除 Filebrowser 数据库…"
                sudo rm -f "$FILEBROWSER_DB"
                ;;
            03)
                echo "  删除公网 IP 记录…"
                sudo rm -f "$FILES_ROOT/public-ip.txt"
                ;;
            02)
                echo "  删除系统用户和文件目录…"
                sudo userdel -r "$FILEBROWSER_USER" 2>/dev/null || true
                sudo rm -rf "/data/files"
                ;;
            01)
                echo "  删除 Filebrowser 二进制文件…"
                sudo rm -f "$FILEBROWSER_BIN"
                ;;
        esac

        sudo rm -f "$marker_file"
        echo "  Step ${step} 已撤销"
    done

    echo ""
    echo "========================================"
    echo "  ✅ 回滚完成"
    echo "========================================"
}

# === 主流程 ===

main() {
    echo "========================================"
    echo "  File Server — 一键部署"
    echo "========================================"
    echo ""

    sudo mkdir -p "$DEPLOY_STATE_DIR"

    check_prerequisites
    step_download_filebrowser
    step_create_system_user
    step_record_public_ip
    step_configure_filebrowser
    step_install_systemd_service
    step_install_share_helper
    step_install_cleanup_cron
    step_generate_nginx_site
    step_enable_site
    step_print_result
}

case "${1:-}" in
    --undo) undo;;
    -h|--help) usage;;
    *) main;;
esac
