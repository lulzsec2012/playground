#!/usr/bin/env bash
# ============================================================
# create-temp-user.sh — 临时重置 admin 密码（自动恢复）
#
# 不创建新用户，直接重置 admin 密码为 6 位数字，
# 到期后 cron 自动恢复为新的随机长密码。
#
# 用法: sudo bash create-temp-user.sh [ttl]
#   ttl: 30m, 1h, 8h, 24h（默认 1h）
#
# 输出: URL / 用户名 / 临时密码
# ============================================================

set -euo pipefail

# === 配置 ===
FILEBROWSER_DB="${FILEBROWSER_DB:-/data/filebrowser.db}"
FILEBROWSER_BIN="${FILEBROWSER_BIN:-/usr/local/bin/filebrowser}"
MARKER_DIR="/data/etc/temp-users"
FS_PORT="${FS_PORT:-8080}"
FS_HOST="${FS_HOST:-fileserver}"

# === TTL 解析 ===
parse_ttl_seconds() {
    local ttl="$1"
    case "$ttl" in
        *s) echo $((${ttl%s})) ;;
        *m) echo $((${ttl%m} * 60)) ;;
        *h) echo $((${ttl%h} * 3600)) ;;
        *d) echo $((${ttl%d} * 86400)) ;;
        *)  echo 3600 ;;
    esac
}

# === 生成 6 位数字密码 ===
gen_digit_password() {
    python3 -c "import secrets; print(f'{secrets.randbelow(1000000):06d}')"
}

# === 生成长随机密码 ===
gen_long_password() {
    python3 -c "import secrets; print(secrets.token_hex(16))"
}

# === 主流程 ===
main() {
    local ttl_raw="${1:-1h}"
    local ttl_seconds
    ttl_seconds=$(parse_ttl_seconds "$ttl_raw")
    local temp_password
    temp_password=$(gen_digit_password)
    local restore_password
    restore_password=$(gen_long_password)

    echo ">>> 重置 admin 密码 (有效期 ${ttl_raw})..."

    if systemctl is-active filebrowser &>/dev/null; then
        sudo systemctl stop filebrowser
        sleep 1
    fi

    "$FILEBROWSER_BIN" users update admin \
        --database="$FILEBROWSER_DB" \
        --password="$temp_password" 2>&1

    sudo systemctl start filebrowser
    echo "  admin 密码已更新"

    local expires_at
    expires_at=$(date -d "+${ttl_seconds} seconds" +%s 2>/dev/null || \
                 date -v "+${ttl_seconds}S" +%s 2>/dev/null)

    mkdir -p "$MARKER_DIR"
    cat > "$MARKER_DIR/admin-temp.conf" <<EOF
expires_at=${expires_at}
ttl=${ttl_raw}
restore_password=${restore_password}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

    echo ""
    echo "========================================"
    echo "  临时凭据"
    echo "========================================"
    echo "  URL:      http://${FS_HOST}:${FS_PORT}/login"
    echo "  Username: admin"
    echo "  Password: ${temp_password}"
    echo "  Expires:  ${ttl_raw}"
    echo "========================================"
    echo ""
    echo "  (到期后密码将自动恢复为随机长密码)"
}

main "$@"
