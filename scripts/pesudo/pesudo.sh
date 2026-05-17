#!/usr/bin/env bash
# pesudo.sh — Pesudo 统一管理入口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"

TUNNEL_TAG="pesudo-tunnel"

usage() {
    cat >&2 <<EOF
用法: pesudo.sh <command> [args...]

Pesudo 统一管理入口。

命令:
  deploy [target]          部署授权服务器到远程节点
  tunnel [host]            建立 SSH 隧道到授权服务器
  register [user@host]     注册机器到授权服务器
  install                  安装客户端到本机
  status [server]          查看已注册机器列表
  test [phase]             运行测试 (all|4|5|6|7)
  uninstall                卸载本机客户端

选项:
  --help                   显示此帮助

示例:
  pesudo.sh deploy                          # 部署到 auth-server
  pesudo.sh tunnel                          # SSH 隧道到 auth-server:8643
   pesudo.sh tunnel user@auth-server         # 指定主机
  pesudo.sh tunnel --kill                   # 关闭隧道
  pesudo.sh register user@dev-box-2         # 注册远程机器
  pesudo.sh status                          # 查看 all machines
  pesudo.sh test 4                          # 运行 Phase 4 测试

环境变量:
  PESUDO_MASTER_KEY        授权服务器主密钥
  PESUDO_PORT              授权服务器端口（默认 8643）
  PESUDO_ECS_HOST          隧道目标主机（默认 auth-server）
EOF
    exit ${1:-0}
}

cmd_deploy() {
    bash "${SCRIPT_DIR}/server/deploy.sh" "$@"
}

cmd_register() {
    bash "${SCRIPT_DIR}/client/pesudo-register" "$@"
}

cmd_install() {
    bash "${SCRIPT_DIR}/client/install.sh" "$@"
}

cmd_uninstall() {
    bash "${SCRIPT_DIR}/client/install.sh" --uninstall
}

cmd_tunnel() {
    local ssh_host="${1:-${PESUDO_ECS_HOST:-auth-server}}"
    local local_port="${PESUDO_PORT:-8643}"

    if [[ "$ssh_host" = "--kill" ]]; then
        pkill -f "${TUNNEL_TAG}" 2>/dev/null && {
            ok "SSH 隧道已关闭"
        } || {
            warn "没有运行中的 SSH 隧道"
        }
        return 0
    fi

    # 检查隧道是否已在运行
    if pgrep -f "${TUNNEL_TAG}" >/dev/null 2>&1; then
        ok "SSH 隧道已在运行: localhost:${local_port} → ${ssh_host}"
        return 0
    fi

    info "建立 SSH 隧道: localhost:${local_port} → ${ssh_host}:${local_port}"
    ssh -L "${local_port}:localhost:${local_port}" \
        "${ssh_host}" -N -f -o ControlMaster=no \
        -o ServerAliveInterval=30 \
        -o ExitOnForwardFailure=yes \
        -o "${TUNNEL_TAG}" 2>&1 || die "SSH 隧道建立失败，请检查: ssh ${ssh_host}"

    sleep 2

    # 验证隧道
    if pgrep -f "${TUNNEL_TAG}" >/dev/null 2>&1; then
        ok "SSH 隧道已建立"
        info "测试连接: curl -sf http://localhost:${local_port}/v1/health"
    else
        die "SSH 隧道未能保持运行"
    fi
}

cmd_status() {
    local server="${1:-}"
    if [[ -z "$server" ]]; then
        # 尝试自动发现
        if [[ -f "${HOME}/.pesudo/config" ]]; then
            server=$(grep "^SERVER_URL=" "${HOME}/.pesudo/config" | cut -d= -f2)
        fi
        if [[ -z "$server" ]]; then
            server="auth-server"
        fi
    fi
    # 确保有 http 前缀
    if [[ ! "$server" =~ ^http ]]; then
        if [[ "$server" =~ :[0-9]+$ ]]; then
            server="http://${server}"
        else
            server="http://${server}:8643"
        fi
    fi

    info "查询授权服务器: ${server}"
    local resp
    resp=$(curl -sf "${server}/v1/health" 2>/dev/null || echo '{"status":"error"}')

    local status
    status=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('status', 'error'))
except: print('error')
" 2>/dev/null)

    if [[ "$status" != "ok" ]]; then
        die "无法连接到授权服务器: ${server}"
    fi

    local machines
    machines=$(curl -sf "${server}/v1/machines" 2>/dev/null || echo '{"machines":[]}')

    echo ""
    section "已注册机器"
    echo "$machines" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('machines', []):
    status_icon = '✅' if m.get('allowed', True) else '❌'
    host = m.get('hostname', '?')
    user = m.get('user', '?')
    ts_ip = m.get('tailscale_ip', '?')
    last = m.get('last_used', 0)
    if last > 0: import time; last_str = time.strftime('%Y-%m-%d %H:%M', time.gmtime(last))
    else: last_str = '从未使用'
    print(f'  {status_icon} {host} ({user}@{ts_ip})')
    print(f'     上次使用: {last_str}')
" 2>/dev/null || echo "  (无法解析响应)"
}

cmd_test() {
    local phase="${1:-all}"
    cd "$SCRIPT_DIR"

    # 检查 Python 依赖
    if ! python3 -c "import cryptography" 2>/dev/null; then
        warn "Python cryptography 未安装，正在安装..."
        pip3 install -q -r server/requirements.txt || die "依赖安装失败"
    fi

    case "$phase" in
        all|4)
            section "Phase 4 测试"
            bash tests/test_phase_4.sh
            ;;
    esac

    case "$phase" in
        all|5)
            section "Phase 5 测试"
            bash tests/test_phase_5.sh
            ;;
    esac

    case "$phase" in
        all|6)
            section "Phase 6 测试"
            bash tests/test_phase_6.sh
            ;;
    esac

    case "$phase" in
        all|7)
            section "Phase 7 测试"
            bash tests/test_phase_7.sh
            ;;
    esac

    if [[ "$phase" = "all" ]]; then
        info ""
        info "运行全部 pytest..."
        python3 -m pytest tests/ -v --tb=short 2>/dev/null || {
            warn "pytest 未安装或失败，尝试安装..."
            pip3 install -q pytest
            python3 -m pytest tests/ -v --tb=short
        }
    fi
}

main() {
    [[ $# -eq 0 ]] && { usage 1; }

    local cmd="$1"
    shift

    case "$cmd" in
        deploy)     cmd_deploy "$@" ;;
        tunnel)     cmd_tunnel "$@" ;;
        register)   cmd_register "$@" ;;
        install)    cmd_install "$@" ;;
        uninstall)  cmd_uninstall "$@" ;;
        status)     cmd_status "$@" ;;
        test)       cmd_test "$@" ;;
        --help|-h)  usage ;;
        *)          die "未知命令: ${cmd}，使用 --help 查看帮助" ;;
    esac
}

main "$@"
