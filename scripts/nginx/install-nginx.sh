#!/usr/bin/env bash
# File Server — Nginx 安装脚本
# 支持 Ubuntu (Debian 系) / CentOS (RHEL 系)
# 用法: bash install-nginx.sh

set -euo pipefail

# === 检测系统发行版 ===
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                echo "debian"
                ;;
            centos|rhel|rocky|almalinux)
                echo "rhel"
                ;;
            *)
                echo "unknown"
                ;;
        esac
    elif command -v apt-get &>/dev/null; then
        echo "debian"
    elif command -v yum &>/dev/null; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# === 安装 Nginx ===
install_nginx() {
    local distro="$1"
    echo ">>> 检测到系统: $distro"

    case "$distro" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y -qq nginx apache2-utils
            ;;
        rhel)
            sudo yum install -y epel-release
            sudo yum install -y nginx httpd-tools
            sudo systemctl enable nginx
            ;;
        *)
            echo "Error: 不支持的发行版，请手动安装 Nginx" >&2
            exit 1
            ;;
    esac

    echo ">>> Nginx 安装完成: $(nginx -v 2>&1)"
}

# === 目录结构 ===
setup_dirs() {
    # 确保必要目录存在
    sudo mkdir -p /etc/nginx/sites-available
    sudo mkdir -p /etc/nginx/sites-enabled
    sudo mkdir -p /etc/nginx/shares.d
    sudo mkdir -p /etc/nginx/conf.d

    echo ">>> 目录结构已创建"
}

# === 部署 nginx.conf ===
deploy_nginx_conf() {
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    if [ -f "$script_dir/nginx.conf" ]; then
        # 备份原始配置
        if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.bak ]; then
            sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
            echo ">>> 已备份原有 nginx.conf → nginx.conf.bak"
        fi
        sudo cp "$script_dir/nginx.conf" /etc/nginx/nginx.conf
        echo ">>> nginx.conf 已部署"
    else
        echo "Warning: 未找到 nginx.conf，跳过" >&2
    fi
}

# === 启动 Nginx ===
start_nginx() {
    # 测试配置
    sudo nginx -t || {
        echo "Error: Nginx 配置测试失败" >&2
        exit 1
    }

    # 启动/重载
    if pidof nginx &>/dev/null; then
        sudo systemctl reload nginx || sudo nginx -s reload
        echo ">>> Nginx 已重载"
    else
        sudo systemctl enable --now nginx || sudo nginx
        echo ">>> Nginx 已启动"
    fi
}

# === 主流程 ===
main() {
    echo "========================================"
    echo "  File Server — Nginx 安装"
    echo "========================================"

    local distro
    distro="$(detect_distro)"

    install_nginx "$distro"
    setup_dirs
    deploy_nginx_conf
    start_nginx

    echo ""
    echo "========================================"
    echo "  ✅ Nginx 安装完成"
    echo "  配置目录: /etc/nginx/"
    echo "  分享配置: /etc/nginx/shares.d/"
    echo "  Site 目录: /etc/nginx/sites-available/"
    echo "========================================"
}

main "$@"
