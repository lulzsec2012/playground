#!/usr/bin/env bash
# lib/auto-proxy.sh — 自动检测可用 SOCKS5 代理
#
# source 此文件后，提供以下变量和函数：
#   PROXY_LIST     — 所有可用代理列表，每行格式 "scheme://ip:port"
#   PROXY_ADDR     — 最佳代理地址 "ip:port"
#   CURL_PROXY     — 给 curl 的参数串 "-x socks5h://ip:port"
#
# 函数:
#   proxy_test_url <scheme> <addr> [url]
#     — 测试某个代理能否访问指定 URL
#     scheme: socks5h / socks5, addr: ip:port, url 可选（默认 Google 204）
#
# 检测策略：
#   1. 本机 127.0.0.1:1080 socks5h（DNS 走代理）
#   2. 本机 127.0.0.1:1080 socks5
#   3. tailnet 在线节点 + 端口 1080/7890/7891/10808
#   4. MagicDNS 网关 100.100.100.1:1080

if [ -n "${_AUTO_PROXY_LOADED:-}" ]; then return; fi
_AUTO_PROXY_LOADED=1

_AUTO_PROXY_TEST_URL="${AUTO_PROXY_TEST_URL:-https://www.google.com/generate_204}"
_AUTO_PROXY_TIMEOUT="${AUTO_PROXY_TIMEOUT:-3}"
_AUTO_PROXY_PROBE_PORTS="${AUTO_PROXY_PROBE_PORTS:-1080 7890 7891 10808}"

# 测试代理是否可访问指定 URL
# proxy_test_url <scheme> <addr> [url]  →  0=成功 1=失败
proxy_test_url() {
    local scheme="$1" addr="$2" url="${3:-$_AUTO_PROXY_TEST_URL}"
    local code
    code=$(curl -sS --connect-timeout "$_AUTO_PROXY_TIMEOUT" \
        --max-time "$((_AUTO_PROXY_TIMEOUT + 2))" \
        -x "${scheme}://${addr}" \
        -o /dev/null -w "%{http_code}" \
        "$url" 2>/dev/null || true)
    case "$code" in
        204|200|301|302|307|308) return 0 ;;
        *) return 1 ;;
    esac
}

# 扫描 tailnet 在线节点 IP
_auto_scan_tailnet() {
    command -v tailscale &>/dev/null || { echo ""; return; }
    tailscale status --json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for peer in data.get('Peer', {}).values():
        if peer.get('Online', False):
            for addr in peer.get('TailscaleIPs', []):
                print(addr)
except: pass
" 2>/dev/null || true
}

# 检测所有可用代理，填充 PROXY_LIST / PROXY_ADDR / CURL_PROXY
auto_detect_proxies() {
    PROXY_ADDR=""; CURL_PROXY=""; PROXY_LIST=""
    local found=()

    _try_add() {
        local scheme="$1" addr="$2"
        local key="${scheme}://${addr}"
        for f in "${found[@]}"; do
            [[ "${f#*://}" = "$addr" ]] && return
        done
        found+=("$key")
    }

    proxy_test_url socks5h "127.0.0.1:1080" && _try_add socks5h "127.0.0.1:1080"
    proxy_test_url socks5  "127.0.0.1:1080" && _try_add socks5  "127.0.0.1:1080"

    local peers
    peers=$(_auto_scan_tailnet)
    if [ -n "$peers" ]; then
        local peer port
        for peer in $peers; do
            for port in $_AUTO_PROXY_PROBE_PORTS; do
                proxy_test_url socks5h "${peer}:${port}" && _try_add socks5h "${peer}:${port}"
                proxy_test_url socks5  "${peer}:${port}" && _try_add socks5  "${peer}:${port}"
            done
        done
    fi

    proxy_test_url socks5h "100.100.100.1:1080" && _try_add socks5h "100.100.100.1:1080"

    if [ ${#found[@]} -gt 0 ]; then
        PROXY_LIST=$(printf "%s\n" "${found[@]}")
        local best="${found[0]}" addr="${found[0]#*://}" scheme="${found[0]%%://*}"
        PROXY_ADDR="$addr"
        CURL_PROXY="-x ${best}"
        export PROXY_ADDR CURL_PROXY PROXY_LIST
        return 0
    fi
    return 1
}

# 不再自动检测——由调用方显式调用 auto_detect_proxies || true
