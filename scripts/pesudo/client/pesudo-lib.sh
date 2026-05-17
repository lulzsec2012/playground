#!/usr/bin/env bash
#
# pesudo-lib.sh — Pesudo 客户端公共函数库
#
# 提供: 服务器发现、HTTP 请求、凭据解密、expect sudo 执行
#
# Usage: source "$(dirname "$0")/pesudo-lib.sh"
#

# ====== 只在首次 source 时加载 ======
if [[ -n "${__PESUDO_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly __PESUDO_LIB_LOADED=1

# ====== 常量 ======
readonly PESUDO_CONFIG_DIR="${HOME}/.pesudo"
readonly PESUDO_CONFIG="${PESUDO_CONFIG_DIR}/config"
readonly PESUDO_CREDENTIALS="${PESUDO_CONFIG_DIR}/credentials"
readonly PESUDO_SERVER_PORT="${PESUDO_SERVER_PORT:-8643}"

# ====== 输出函数（自包含，不依赖外部 lib）======

die()   { echo -e "  \033[0;31m❌\033[0m $*" >&2; exit 1; }
ok()    { echo -e "  \033[0;32m✓\033[0m $*" >&2; }
warn()  { echo -e "  \033[1;33m⚠\033[0m $*" >&2; }
info()  { echo -e "\033[0;36m$*\033[0m" >&2; }

# 带边框的章节标题
section() {
    local title="$1"
    echo "" >&2
    info "══════════════════════════════════════"
    info "  ${title}"
    info "══════════════════════════════════════"
}

# ====== 配置加载 ======

# 加载凭据文件
load_credentials() {
    if [[ ! -f "$PESUDO_CREDENTIALS" ]]; then
        die "本机尚未注册，请先执行: pesudo-register [user@host]"
    fi

    MACHINE_ID=$(grep "^machine_id=" "$PESUDO_CREDENTIALS" 2>/dev/null | cut -d= -f2-)
    HOSTNAME=$(grep "^hostname=" "$PESUDO_CREDENTIALS" 2>/dev/null | cut -d= -f2-)

    if [[ -z "$MACHINE_ID" ]]; then
        die "凭据文件损坏: ${PESUDO_CREDENTIALS} 中缺少 machine_id"
    fi
}

# 读取配置文件单个键值
get_config() {
    local key="$1"
    local cfg="$PESUDO_CONFIG"
    [[ -f "$cfg" ]] || return 1
    grep "^${key}=" "$cfg" 2>/dev/null | cut -d= -f2- | head -1
}

# 写入配置文件
set_config() {
    local key="$1" value="$2"
    mkdir -p "$PESUDO_CONFIG_DIR"
    if grep -q "^${key}=" "$PESUDO_CONFIG" 2>/dev/null; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$PESUDO_CONFIG"
    else
        echo "${key}=${value}" >> "$PESUDO_CONFIG"
    fi
}

# ====== 服务器自动发现 ======

# 自动发现授权服务器
# 返回: SERVER_URL (如 "http://auth-server:8643")
# 失败: 返回 1，输出错误信息到 stderr
discover_server() {
    local server_url=""
    local curl_check="--connect-timeout 3 --max-time 5"

    # 1. Tailscale MagicDNS（最快，无需扫描）
    for host in "auth-server" "pesudo"; do
        if curl -sf ${curl_check} "http://${host}:${PESUDO_SERVER_PORT}/v1/health" -o /dev/null 2>/dev/null; then
            server_url="http://${host}:${PESUDO_SERVER_PORT}"
            info "→ 授权服务器: ${server_url} (MagicDNS)"
            set_config "SERVER_URL" "$server_url"
            echo "$server_url"
            return 0
        fi
    done

    # 2. Tailscale 节点扫描
    local ts_output
    ts_output=$(tailscale status 2>/dev/null | awk '/^100\./ && !/offline/ {print $1, $2}') || true
    if [[ -n "$ts_output" ]]; then
        # 2a. 先扫含关键字的节点（pesudo / auth）
        while IFS=' ' read -r ip name; do
            local clean_name="${name%%.*}"
            if echo "$clean_name" | grep -qiE "pesudo|auth"; then
                if curl -sf ${curl_check} "http://${ip}:${PESUDO_SERVER_PORT}/v1/health" -o /dev/null 2>/dev/null; then
                    server_url="http://${ip}:${PESUDO_SERVER_PORT}"
                    info "→ 授权服务器: ${server_url} (${clean_name})"
                    set_config "SERVER_URL" "$server_url"
                    echo "$server_url"
                    return 0
                fi
            fi
        done <<< "$ts_output"

        # 2b. 全量扫描
        while IFS=' ' read -r ip name; do
            if curl -sf ${curl_check} "http://${ip}:${PESUDO_SERVER_PORT}/v1/health" -o /dev/null 2>/dev/null; then
                server_url="http://${ip}:${PESUDO_SERVER_PORT}"
                local clean_name="${name%%.*}"
                info "→ 授权服务器: ${server_url} (${clean_name})"
                set_config "SERVER_URL" "$server_url"
                echo "$server_url"
                return 0
            fi
        done <<< "$ts_output"
    fi

    # 3. 配置文件中的 SERVER_URL（最后备选）
    server_url=$(get_config "SERVER_URL")
    if [[ -n "$server_url" ]]; then
        if curl -sf ${curl_check} "${server_url}/v1/health" -o /dev/null 2>/dev/null; then
            info "→ 授权服务器: ${server_url} (配置文件)"
            echo "$server_url"
            return 0
        fi
        warn "配置文件中的 SERVER_URL (${server_url}) 不可达，可能已过期或需要 SSH 隧道"
    fi

    warn "授权服务器未找到 (扫描了 MagicDNS + Tailscale 节点 + 配置文件)"
    return 1
}

# ====== HTTP 辅助函数 ======

# POST JSON 请求
# 用法: http_post_json <url> <json_data>
# 输出: 响应体 (stdout)
# 返回: 0=成功, 1=失败
http_post_json() {
    local url="$1" data="$2"
    curl -sf --connect-timeout 5 --max-time 10 -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$data" 2>/dev/null
}

# GET 请求
# 用法: http_get <url>
# 输出: 响应体
http_get() {
    curl -sf --connect-timeout 5 --max-time 10 "$url" 2>/dev/null
}

# 快速健康检查（无输出，仅返回 0/1）
# 用法: check_server_health <url>
check_server_health() {
    curl -sf --connect-timeout 3 --max-time 5 "$1/v1/health" -o /dev/null 2>/dev/null
}

# ====== 凭据解密 ======

# 解密一次性凭据（调用 Python 执行 AES-GCM）
# 用法: decrypt_credential <ciphertext_hex> <session_key_hex> <request_id>
# 输出: 密码明文 (stdout)
# 返回: 0=成功, 1=失败
decrypt_credential() {
    local ct="$1" key="$2" rid="$3"

    python3 -c "
import sys, json, binascii
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

data = binascii.unhexlify('${ct}')
k = binascii.unhexlify('${key}')
nonce, ciphertext = data[:12], data[12:]
aad = b'pesudo:v1:${rid}'

try:
    aesgcm = AESGCM(k)
    plain = aesgcm.decrypt(nonce, ciphertext, aad)
    payload = json.loads(plain)
    print(payload.get('password', ''), end='')
except Exception as e:
    print('DECRYPT_FAIL: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# ====== 凭据管理 ======

# 保存本地凭据文件
save_local_credentials() {
    local machine_id="$1" host="$2" ssh_port="${3:-22}"
    mkdir -p "$PESUDO_CONFIG_DIR"

    cat > "$PESUDO_CREDENTIALS" << EOF
machine_id=${machine_id}
hostname=${host}
ssh_port=${ssh_port}
EOF
    chmod 600 "$PESUDO_CREDENTIALS"
    ok "凭据已保存: ${PESUDO_CREDENTIALS}"
}

# ====== Sudo 执行 ======

# 通过 expect 执行 sudo 命令（密码仅存 expect 进程内存）
# 用法: expect_sudo <password> <command_args...>
# 返回: sudo 命令的退出码
expect_sudo() {
    local password="$1"
    shift

    SUDO_PASS="$password" expect -c "
        set timeout 30
        set password \$env(SUDO_PASS)
        spawn sudo -k $@
        expect {
            -re {password for .*:} {
                send \"\$password\\r\"
                exp_continue
            }
            -re {incorrect|sorry|try again} {
                puts \"\\nsudo 密码错误\"
                exit 1
            }
            eof {
                catch wait result
                set code [lindex \$result 3]
                if {[llength \$result] == 0} { set code 0 }
                exit \$code
            }
            timeout {
                puts \"\\nsudo 超时\"
                exit 1
            }
        }
    "
    return $?
}

# ====== 自动修复 ======

# 尝试自动修复授权服务器（SSH 到 ECS 重启服务）
# 失败时自动重试一次 SSH 连接
# 返回: SERVER_URL (stdout), 0=成功, 1=失败
recover_server() {
    local first_attempt="${1:-1}"

    # 1. 确定 ECS 主机
    local ecs_host
    ecs_host=$(get_config "ECS_HOST")

    if [[ -z "$ecs_host" ]]; then
        echo ""
        info "  请输入授权服务器 SSH 地址（如 user@host）"
        info "  此地址将被保存到配置文件，下次自动使用"
        read -r -p "  SSH 地址: " ecs_host
        if [[ -z "$ecs_host" ]]; then
            warn "已取消"
            return 1
        fi
    fi

    info "尝试通过 SSH 连接 ${ecs_host}..."

    # 2. 先试 SSH key（无密码交互）
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "$ecs_host" "echo ok" 2>/dev/null | grep -q "ok"; then
        info "SSH key 认证成功"
    else
        # 3. SSH key 失败，提示用密码
        echo ""
        if [[ "$first_attempt" = "1" ]]; then
            info "SSH key 认证失败，尝试密码登录..."
        fi
        return 1
    fi

    # 4. 重启服务
    info "正在重启授权服务器..."
    if ! ssh -o StrictHostKeyChecking=no "$ecs_host" \
        "systemctl --user restart pesudo-server 2>&1"; then
        # retry once
        sleep 1
        if ! ssh -o StrictHostKeyChecking=no "$ecs_host" \
            "systemctl --user restart pesudo-server 2>&1"; then
            warn "服务重启失败，请手动检查: ssh ${ecs_host} 'systemctl --user status pesudo-server'"
            return 1
        fi
    fi

    ok "服务已重启"

    # 5. 等待就绪（在 ECS 上验证）
    info "等待授权服务器就绪..."
    sleep 3
    local ecs_health
    ecs_health=$(ssh -o StrictHostKeyChecking=no "$ecs_host" \
        "curl -sf --connect-timeout 5 http://localhost:8643/v1/health" 2>/dev/null) || {
        warn "ECS 上服务未正常启动: ssh ${ecs_host} 'systemctl --user status pesudo-server'"
        return 1
    }
    ok "ECS 端服务运行正常"

    # 6. 尝试本地发现
    local server_url
    server_url=$(discover_server) || {
        # 本地不可达 → 提供自动 SSH 隧道
        echo ""
        warn "本机无法直连授权服务器（Tailscale 或安全组限制）"
        echo "  ─────────────────────────────────────"
        read -r -p "  是否建立 SSH 隧道（localhost:8643 → ECS）? [Y/n] " setup_tun
        if [[ -z "$setup_tun" || "$setup_tun" =~ ^[Yy] ]]; then
            # 检查是否已有可用隧道
            if curl -sf --connect-timeout 2 http://localhost:8643/v1/health -o /dev/null 2>/dev/null; then
                ok "现有隧道仍可用"
                server_url="http://localhost:8643"
            else
                # 清理残留的隧道进程
                local old_pid
                old_pid=$(lsof -ti :8643 2>/dev/null || true)
                if [[ -n "$old_pid" ]]; then
                    warn "端口 8643 被占用 (PID=$old_pid)，正在清理..."
                    kill "$old_pid" 2>/dev/null || true
                    sleep 1
                fi
                info "正在建立 SSH 隧道..."
                if ! ssh -o StrictHostKeyChecking=no \
                    -o ExitOnForwardFailure=yes \
                    -L 8643:localhost:8643 \
                    -f -N "$ecs_host" 2>&1; then
                    warn "隧道建立失败（端口 8643 可能已被占用）"
                    warn "请手动执行: ssh -L 8643:localhost:8643 ${ecs_host} -N -f"
                    return 1
                fi
                # 隧道建立后验证连通性
                sleep 1
                if ! curl -sf --connect-timeout 3 http://localhost:8643/v1/health -o /dev/null; then
                    # 隧道可能未正常工作，清理并返回
                    local stale_pid
                    stale_pid=$(lsof -ti :8643 2>/dev/null || true)
                    [[ -n "$stale_pid" ]] && kill "$stale_pid" 2>/dev/null || true
                    warn "SSH 隧道已建立但连接失败"
                    warn "请手动执行: ssh -L 8643:localhost:8643 ${ecs_host} -N -f"
                    return 1
                fi
                ok "SSH 隧道已建立"
                server_url="http://localhost:8643"
            fi
            set_config "SERVER_URL" "$server_url"
        else
            warn "请手动建立隧道: ssh -L 8643:localhost:8643 ${ecs_host} -N -f"
            return 1
        fi
    }

    # 7. 保存 ECS_HOST 到配置
    set_config "ECS_HOST" "$ecs_host"
    ok "授权服务器已恢复"
    echo "$server_url"
    return 0
}
