#!/usr/bin/env bash
# fs-share-cleanup.sh — 清理过期分享链接
# 通过 crontab 定期执行，删除已过期的 TTL 分享
# 用法: sudo /usr/local/bin/fs-share-cleanup.sh

set -euo pipefail

SHARE_DIR="/data/files/.shares"
SHARES_CONF_DIR="/etc/nginx/shares.d"
META_DIR="$SHARE_DIR/.meta"

now=$(date +%s)
cleaned=0

if [ ! -d "$META_DIR" ]; then
    echo "[cleanup] 无 TTL 元数据目录，跳过分享清理"
else

for meta_file in "$META_DIR"/*.conf; do
    [ -f "$meta_file" ] || continue

    share_id="$(basename "$meta_file" .conf)"
    expires_at=$(grep -oP '^expires_at=\K[0-9]+' "$meta_file" 2>/dev/null || echo "0")

    if [ "$expires_at" -gt 0 ] && [ "$now" -ge "$expires_at" ]; then
        echo "[cleanup] 清理过期分享: ${share_id}"

        rm -f "$SHARE_DIR/$share_id" 2>/dev/null || true
        rm -f "$SHARES_CONF_DIR/${share_id}.conf" 2>/dev/null || true
        rm -f "$meta_file" 2>/dev/null || true

        cleaned=$((cleaned + 1))
    fi
done

if [ "$cleaned" -gt 0 ]; then
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    fi
    echo "[cleanup] 已清理 ${cleaned} 个过期分享"
fi
fi  # end share cleanup block

# === 恢复过期临时密码 ===
MARKER_DIR="/data/etc/temp-users"
if [ -d "$MARKER_DIR" ]; then
    for marker in "$MARKER_DIR"/*.conf; do
        [ ! -f "$marker" ] && continue
        source "$marker"
        if [ -n "${expires_at:-}" ] && [ "$(date +%s)" -ge "$expires_at" ]; then
            case "${service:-fs}" in
                mixapi)
                    orig_pw="${original_password:-}"
                    temp_pw="${temp_password:-}"
                    if [ -n "$orig_pw" ] && [ -n "$temp_pw" ]; then
                        COOKIE_JAR=$(mktemp)
                        # 用 temp_password 登录（当前有效密码）
                        LOGIN=$(curl -s -X POST "http://localhost:3000/api/user/login" \
                            -H "Content-Type: application/json" -c "$COOKIE_JAR" \
                            -d "{\"username\":\"root\",\"password\":\"${temp_pw}\"}" 2>/dev/null)
                        if echo "$LOGIN" | python3 -c "import sys,json;exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null; then
                            ROOT_ID=$(echo "$LOGIN" | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('id',1))" 2>/dev/null || echo 1)
                            curl -s -X PUT "http://localhost:3000/api/user/" \
                                -H "Content-Type: application/json" -b "$COOKIE_JAR" \
                                -H "New-Api-User: ${ROOT_ID}" \
                                -d "{\"id\":${ROOT_ID},\"username\":\"root\",\"password\":\"${orig_pw}\"}" >/dev/null 2>&1 || true
                            echo "[cleanup] mixapi root 密码已恢复"
                        else
                            # temp 密码也失效——尝试用 original 密码登录（可能已被手动改回）
                            LOGIN2=$(curl -s -X POST "http://localhost:3000/api/user/login" \
                                -H "Content-Type: application/json" -c "$COOKIE_JAR" \
                                -d "{\"username\":\"root\",\"password\":\"${orig_pw}\"}" 2>/dev/null)
                            if echo "$LOGIN2" | python3 -c "import sys,json;exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null; then
                                echo "[cleanup] mixapi 密码无需恢复"
                            else
                                echo "[cleanup] 警告: 无法登录 MIXAPI，密码未恢复" >&2
                            fi
                        fi
                        rm -f "$COOKIE_JAR"
                    fi
                    ;;
                *)
                    restore_pw="${restore_password:-}"
                    if [ -n "$restore_pw" ]; then
                        if systemctl is-active filebrowser &>/dev/null; then
                            systemctl stop filebrowser 2>/dev/null
                            sleep 1
                        fi
                        /usr/local/bin/filebrowser users update admin \
                            --database=/data/filebrowser.db \
                            --password="$restore_pw" 2>/dev/null || true
                        systemctl start filebrowser 2>/dev/null || true
                        echo "[cleanup] admin 密码已恢复"
                    fi
                    ;;
            esac
            rm -f "$marker"
        fi
    done
fi

exit 0
