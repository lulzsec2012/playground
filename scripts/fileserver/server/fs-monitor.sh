#!/usr/bin/env bash
# ============================================================
# fs-monitor.sh — File Server Health Monitor
#
# 检查文件服务器各项服务运行状态并输出结构化报告。
# 设计为在 ECS 服务器上运行，也可通过 SSH 远程执行。
#
# 用法:
#   sudo fs-monitor
#
# 部署位置:
#   /usr/local/bin/fs-monitor (由 deploy-server.sh 部署)
#
# 退出码:
#   0 = 全部健康
#   1 = 有警告
#   2 = 有错误
# ============================================================

set -euo pipefail

# === 配置 ===
FILES_ROOT="/data/files"
SHARES_DIR="$FILES_ROOT/.shares"
NGINX_SHARES_CONF="/etc/nginx/shares.d"
PUBLIC_IP_FILE="/data/etc/public-ip"
DISK_WARN=80
DISK_ERR=95

# === 全局计数器 ===
OK=0
WARN=0
ERR=0

# === 辅助函数 ===

# 格式化输出行：标签左对齐 + 点填充到 22 字符
print_line() {
    local label="$1" status="$2"
    local padded
    padded=$(printf "%-22s" "$label" | tr ' ' '.')
    printf "%s %s\n" "$padded" "$status"
}

print_header() {
    local date_str
    date_str=$(date '+%Y-%m-%d %H:%M:%S')
    cat << EOF
╔══════════════════════════════════════════╗
║        File Server Health Report         ║
║        $date_str                  ║
╚══════════════════════════════════════════╝

EOF
}

inc_ok()   { OK=$((OK + 1)); }
inc_warn() { WARN=$((WARN + 1)); }
inc_err()  { ERR=$((ERR + 1)); }

# === 检查函数 ===
# 每个函数返回 0（正常）或 1（异常），同时更新全局计数器
# 使用 || true 保证在 set -e 下安全执行

check_nginx() {
    local running=false pid=""

    if command -v pidof &>/dev/null; then
        local pids
        pids=$(pidof nginx 2>/dev/null || true)
        if [ -n "$pids" ]; then
            running=true
            pid=$(echo "$pids" | cut -d' ' -f1)
        fi
    fi

    if ! $running && command -v systemctl &>/dev/null; then
        if systemctl is-active nginx &>/dev/null 2>&1; then
            running=true
            pid="systemd"
        fi
    fi

    if $running; then
        if [ "$pid" = "systemd" ]; then
            print_line "Nginx" "✅ running (systemd active)"
        else
            print_line "Nginx" "✅ running (pid $pid)"
        fi
        inc_ok
        return 0
    else
        print_line "Nginx" "❌ not running"
        inc_err
        return 1
    fi
}

check_filebrowser() {
    if command -v systemctl &>/dev/null; then
        if systemctl is-active filebrowser &>/dev/null 2>&1; then
            print_line "Filebrowser" "✅ running (systemd active)"
            inc_ok
            return 0
        fi
    fi

    if command -v curl &>/dev/null; then
        if curl -sf -o /dev/null http://127.0.0.1:8081/api/health 2>/dev/null; then
            print_line "Filebrowser" "✅ running (port 8081)"
            inc_ok
            return 0
        fi
    fi

    print_line "Filebrowser" "❌ not running or unreachable"
    inc_err
    return 1
}

check_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        print_line "Tailscale" "[skipped] not installed"
        return 0
    fi

    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active tailscaled &>/dev/null 2>&1; then
            print_line "Tailscale" "❌ tailscaled not running"
            inc_err
            return 1
        fi
    fi

    local status_output
    status_output=$(tailscale status 2>/dev/null || true)

    if echo "$status_output" | grep -qE "^100\\."; then
        local ip
        ip=$(echo "$status_output" | awk '/^100\./{print $1; exit}')
        print_line "Tailscale" "✅ online (${ip})"
        inc_ok
        return 0
    else
        print_line "Tailscale" "❌ not connected to tailnet"
        inc_err
        return 1
    fi
}

check_disk() {
    if [ ! -d "$FILES_ROOT" ]; then
        print_line "Disk Usage" "❌ directory not found"
        inc_err
        return 1
    fi

    local usage
    usage=$(df -h "$FILES_ROOT" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")

    if [ "$usage" -gt "$DISK_ERR" ]; then
        print_line "Disk Usage" "❌ ${usage}% (err threshold: ${DISK_ERR}%)"
        inc_err
        return 1
    elif [ "$usage" -gt "$DISK_WARN" ]; then
        print_line "Disk Usage" "⚠️  ${usage}% (warn threshold: ${DISK_WARN}%)"
        inc_warn
        return 1
    else
        print_line "Disk Usage" "✅ ${usage}%"
        inc_ok
        return 0
    fi
}

check_nginx_config() {
    if ! command -v nginx &>/dev/null; then
        print_line "Nginx Config" "[skipped] nginx not installed"
        return 0
    fi

    local output
    output=$(nginx -t 2>&1 || true)

    if echo "$output" | grep -q "syntax is ok"; then
        print_line "Nginx Config" "✅ syntax ok"
        inc_ok
        return 0
    else
        local err_msg
        err_msg=$(echo "$output" | grep -i "error" | head -1 || echo "$output" | head -1)
        print_line "Nginx Config" "❌ ${err_msg}"
        inc_err
        return 1
    fi
}

check_shares_dir() {
    local missing=""

    if [ ! -d "$SHARES_DIR" ]; then
        missing="${SHARES_DIR}"
    fi
    if [ ! -d "$NGINX_SHARES_CONF" ]; then
        if [ -n "$missing" ]; then
            missing="${missing}, ${NGINX_SHARES_CONF}"
        else
            missing="${NGINX_SHARES_CONF}"
        fi
    fi

    if [ -z "$missing" ]; then
        print_line "Shares Dir" "✅ ok"
        inc_ok
        return 0
    else
        print_line "Shares Dir" "❌ missing: $missing"
        inc_err
        return 1
    fi
}

check_public_ip() {
    local ip_file="$PUBLIC_IP_FILE"
    [ ! -f "$ip_file" ] && [ -f "$FILES_ROOT/.public-ip" ] && ip_file="$FILES_ROOT/.public-ip"

    if [ -f "$ip_file" ] && [ -s "$ip_file" ]; then
        local ip
        ip=$(tr -d '\n' < "$ip_file")
        print_line "Public IP" "✅ $ip"
        inc_ok
        return 0
    elif [ -f "$ip_file" ] && [ ! -s "$ip_file" ]; then
        print_line "Public IP" "❌ file exists but empty"
        inc_err
        return 1
    else
        print_line "Public IP" "❌ file not found"
        inc_err
        return 1
    fi
}

# === 主流程 ===
main() {
    print_header

    check_nginx || true
    check_filebrowser || true
    check_tailscale || true
    check_disk || true
    check_nginx_config || true
    check_shares_dir || true
    check_public_ip || true

    local total=$((OK + WARN + ERR))
    echo ""
    echo "Summary: $OK ok, $WARN warning(s), $ERR error(s)"

    if [ "$ERR" -gt 0 ]; then
        exit 2
    elif [ "$WARN" -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

main
