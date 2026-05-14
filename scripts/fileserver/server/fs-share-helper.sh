#!/usr/bin/env bash
# ============================================================
# fs-share-helper.sh — 文件服务器分享管理脚本
#
# 作用: 在 ECS 服务端创建/删除/列出分享链接
# 通过 sudoers 白名单授权给指定用户无密码执行
#
# 用法:
#   fs-share-helper create <share-id> <file-path>
#   fs-share-helper create-protected <share-id> <file-path> <password>
#   fs-share-helper create-with-ttl <share-id> <file-path> <ttl-seconds>
#   fs-share-helper delete <share-id>
#   fs-share-helper list
#   fs-share-helper cleanup
# ============================================================

set -euo pipefail

# === 配置 ===
SHARE_DIR="/data/files/.shares"
SHARES_CONF_DIR="/etc/nginx/shares.d"
META_DIR="$SHARE_DIR/.meta"
HTPASSWD_FILE="/etc/nginx/.share-passwd"
FILES_ROOT="/data/files"

# === 辅助函数 ===

usage() {
    cat <<EOF
用法: $(basename "$0") <command> [args]

命令:
  create <share-id> <file-path>          创建公开分享
  create-protected <share-id> <file-path> <password>  创建密码分享
  create-with-ttl <share-id> <file-path> <ttl-seconds>  创建带过期时间的分享
  delete <share-id>                      删除分享
  list                                   列出所有分享
  cleanup                                清理已过期的分享
EOF
    exit 1
}

validate_share_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[a-zA-Z0-9_-]{4,32}$ ]]; then
        echo "Error: share-id 必须为 4-32 位字母数字或下划线连字符" >&2
        exit 1
    fi
}

resolve_path() {
    local path="$1"
    # 去掉前导 /
    path="${path#/}"
    # 拼接完整路径，防止路径穿越
    local resolved
    resolved="$(cd "$FILES_ROOT" && realpath -m "$path" 2>/dev/null)" || resolved="$FILES_ROOT/$path"
    # 确保解析后的路径仍在 FILES_ROOT 内
    if [[ "$resolved" != "$FILES_ROOT"* ]]; then
        echo "Error: 路径穿越拒绝: $path" >&2
        exit 1
    fi
    echo "$resolved"
}

ensure_share_dir() {
    mkdir -p "$SHARE_DIR" "$SHARES_CONF_DIR" "$META_DIR"
}

gen_share_location() {
    local share_id="$1"
    local target_path="$2"
    cat <<NGINX
location /s/${share_id} {
    alias ${target_path};
    autoindex off;
}
NGINX
}

gen_share_location_protected() {
    local share_id="$1"
    local target_path="$2"
    cat <<NGINX
location /s/${share_id} {
    alias ${target_path};
    autoindex off;
    auth_basic "Protected Share";
    auth_basic_user_file ${HTPASSWD_FILE};
}
NGINX
}

nginx_reload() {
    nginx -t 2>/dev/null || { echo "Error: Nginx 配置测试失败"; exit 1; }
    systemctl reload nginx || nginx -s reload
}

# === 命令实现 ===

cmd_create() {
    local share_id="$1"
    local file_path="$2"

    validate_share_id "$share_id"
    ensure_share_dir

    local resolved
    resolved="$(resolve_path "$file_path")"

    if [ ! -e "$resolved" ]; then
        echo "Error: 文件不存在: $resolved" >&2
        exit 1
    fi

    # 创建 symlink
    ln -sf "$resolved" "$SHARE_DIR/$share_id"
    echo "✅ 分享创建成功: /s/${share_id}"
}

cmd_create_protected() {
    local share_id="$1"
    local file_path="$2"
    local password="$3"

    validate_share_id "$share_id"
    ensure_share_dir

    local resolved
    resolved="$(resolve_path "$file_path")"

    if [ ! -e "$resolved" ]; then
        echo "Error: 文件不存在: $resolved" >&2
        exit 1
    fi

    # 创建 symlink
    ln -sf "$resolved" "$SHARE_DIR/$share_id"

    # 写入 htpasswd（htpasswd -b 在用户已存在时更新密码）
    htpasswd -b "$HTPASSWD_FILE" "$share_id" "$password" 2>/dev/null || {
        # htpasswd 可能不存在，尝试安装
        if command -v apt-get &>/dev/null; then
            apt-get install -y apache2-utils >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y httpd-tools >/dev/null 2>&1
        fi
        htpasswd -b "$HTPASSWD_FILE" "$share_id" "$password"
    }

    # 写入 Nginx location 配置
    gen_share_location_protected "$share_id" "$resolved" > "$SHARES_CONF_DIR/${share_id}.conf"

    # 重载 Nginx
    nginx_reload

    echo "✅ 密码分享创建成功: /s/${share_id}"
}

cmd_delete() {
    local share_id="$1"

    validate_share_id "$share_id"

    # 删除 symlink
    rm -f "$SHARE_DIR/$share_id"

    # 删除 htpasswd 条目
    if [ -f "$HTPASSWD_FILE" ]; then
        htpasswd -D "$HTPASSWD_FILE" "$share_id" 2>/dev/null || true
    fi

    # 删除 Nginx location 配置
    rm -f "$SHARES_CONF_DIR/${share_id}.conf"

    rm -f "$META_DIR/${share_id}.conf" 2>/dev/null || true

    # 重载 Nginx
    nginx_reload

    echo "✅ 分享已删除: $share_id"
}

cmd_list() {
    echo "=== 活跃分享 ==="

    local has_protected=0
    [ -f "$HTPASSWD_FILE" ] && has_protected=1

    local count=0
    for entry in "$SHARE_DIR"/*; do
        [ -L "$entry" ] || continue
        local name
        name="$(basename "$entry")"
        local target
        target="$(readlink "$entry" 2>/dev/null || echo "$entry")"
        count=$((count + 1))

        if [ "$has_protected" -eq 1 ] && grep -q "^${name}:" "$HTPASSWD_FILE" 2>/dev/null; then
            echo "  🔒 /s/${name} → ${target#${FILES_ROOT}/}"
        else
            echo "  🔓 /s/${name} → ${target#${FILES_ROOT}/}"
        fi
    done

    [ "$count" -eq 0 ] && echo "  暂无分享"
}

# ---------- TTL 支持 ----------

cmd_create_with_ttl() {
    local share_id="$1"
    local file_path="$2"
    local ttl_seconds="$3"

    # 先创建公开分享
    cmd_create "$share_id" "$file_path"

    mkdir -p "$META_DIR" 2>/dev/null || true

    local now
    now=$(date +%s)
    local expires_at=$((now + ttl_seconds))
    cat > "$META_DIR/${share_id}.conf" <<EOF
expires_at=$expires_at
created_at=$now
file_path=$file_path
EOF
    echo "  过期时间: $(date -d "@${expires_at}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${expires_at}")"
}

cmd_cleanup() {
    local now
    now=$(date +%s)
    local cleaned=0

    if [ ! -d "$META_DIR" ]; then
        echo "  无 TTL 元数据目录，跳过"
        exit 0
    fi

    for meta_file in "$META_DIR"/*.conf; do
        [ -f "$meta_file" ] || continue

        local share_id
        share_id="$(basename "$meta_file" .conf)"
        local expires_at=0

        expires_at=$(grep -oP '^expires_at=\K[0-9]+' "$meta_file" 2>/dev/null || echo "0")

        if [ "$expires_at" -gt 0 ] && [ "$now" -ge "$expires_at" ]; then
            echo "  清理过期分享: ${share_id}"
            cmd_delete "$share_id"
            rm -f "$meta_file" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        fi
    done

    if [ "$cleaned" -eq 0 ]; then
        echo "  无过期分享"
    else
        echo "  已清理 ${cleaned} 个过期分享"
    fi
}

# === 入口 ===

[ $# -lt 1 ] && usage

case "$1" in
    create)
        [ $# -lt 3 ] && { echo "用法: $0 create <share-id> <file-path>" >&2; exit 1; }
        cmd_create "$2" "$3"
        ;;
    create-protected)
        [ $# -lt 4 ] && { echo "用法: $0 create-protected <share-id> <file-path> <password>" >&2; exit 1; }
        cmd_create_protected "$2" "$3" "$4"
        ;;
    create-with-ttl)
        [ $# -lt 4 ] && { echo "用法: $0 create-with-ttl <share-id> <file-path> <ttl-seconds>" >&2; exit 1; }
        cmd_create_with_ttl "$2" "$3" "$4"
        ;;
    delete)
        [ $# -lt 2 ] && { echo "用法: $0 delete <share-id>" >&2; exit 1; }
        cmd_delete "$2"
        ;;
    list)
        cmd_list
        ;;
    cleanup)
        cmd_cleanup
        ;;
    --help|-h)
        usage
        ;;
    *)
        echo "Error: 未知命令 '$1'" >&2
        usage
        ;;
esac
