#!/usr/bin/env bash
# lib/source-chromego.sh — 递归自代理 ChromeGo 源下载器
#
# 从 ChromeGo 上游 GitLab 源下载免费代理配置，自动检测可用代理。
# 核心策略：
#   1. 对每个 batch 遍历所有可用代理尝试下载
#   2. 部分成功 → 生成配置/重启 sing-box，用新代理重试失败 batch
#   3. 全部失败 → 不做无意义部署，直接退出
#
# ChromeGo 项目（bannedbook/fanqiang）在 GitLab 维护了多个协议的最新可用代理，
# 包含 VLESS+REALITY+XHTTP、Hysteria2、Sing-box 等新一代协议的原生配置。
# 本脚本直接从该源下载配置，无需 700MB 的 ChromeGo 分发包。
#
# Usage:
#   bash lib/source-chromego.sh                           # download to default dir
#   bash lib/source-chromego.sh ./my_configs              # custom output dir
#   bash lib/source-chromego.sh --help                    # show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/auto-proxy.sh
source "$SCRIPT_DIR/lib/auto-proxy.sh"

OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/data/chromego_configs}"
GEN_PY="$SCRIPT_DIR/lib/generate-config.py"
MAX_RETRY=3

# www.gitlabip.xyz 是 GitLab 反向代理，国内访问更稳定
PRIMARY_BASE="https://www.gitlabip.xyz/Alvin9999/PAC/refs/heads/master/backup/img/1/2/ipp"
FALLBACK_BASE="https://gitlab.com/free9999/ipupdate/-/raw/master/backup/img/1/2/ipp"

PROTOCOLS=(
  "xray:4:json"
  "clash.meta2:6:yaml"
  "hysteria:4:json"
  "hysteria2:4:json"
  "singbox:2:json"
  "juicity:2:json"
  "mieru:2:json"
  "naiveproxy:2:json"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}$1${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1" >&2; }
err()   { echo -e "  ${RED}✗${NC} $1" >&2; }

usage() {
    cat <<EOF
Fetch free proxy configs from ChromeGo upstream (GitLab).

Usage: $(basename "$0") [<output-dir>]
       $(basename "$0") --help

Arguments:
  <output-dir>  download directory (default: chromego_configs/)

Protocols:
EOF
    for entry in "${PROTOCOLS[@]}"; do
        local name="${entry%%:*}"
        local rest="${entry#*:}"
        local max="${rest%%:*}"
        local ext="${rest#*:}"
        echo "  - $name  (up to $max batches, .$ext)"
    done
    echo ""
    echo "Primary: $PRIMARY_BASE"
    echo "Fallback: $FALLBACK_BASE"
    exit 0
}

# ── 尝试下载单个 batch ──
# 参数: <protocol> <batch> <ext> <outfile>
# 返回: 0=成功, 1=全部失败
# 策略: 遍历 PROXY_LIST 中每个代理
try_batch_download() {
    local protocol="$1" batch="$2" ext="$3" outfile="$4"
    local primary_url="${PRIMARY_BASE}/${protocol}/${batch}/config.${ext}"
    local fallback_url="${FALLBACK_BASE}/${protocol}/${batch}/config.${ext}"

    # 尝试 primary URL
    if [ -n "${PROXY_LIST:-}" ]; then
        # 有代理 → 遍历所有可用代理
        while IFS= read -r proxy; do
            [ -z "$proxy" ] && continue
            local scheme="${proxy%%://*}"
            local addr="${proxy#*://}"
            local code
            code="$(curl -sL -o "$outfile" -w "%{http_code}" \
                --connect-timeout 8 --max-time 15 \
                -x "${scheme}://${addr}" "$primary_url" 2>/dev/null || true)"
            if [ "$code" = "200" ] && [ -s "$outfile" ]; then
                return 0
            fi
        done <<< "$PROXY_LIST"

        # primary 失败 → 遍历 fallback
        while IFS= read -r proxy; do
            [ -z "$proxy" ] && continue
            local scheme="${proxy%%://*}"
            local addr="${proxy#*://}"
            local code
            code="$(curl -sL -o "$outfile" -w "%{http_code}" \
                --connect-timeout 8 --max-time 15 \
                -x "${scheme}://${addr}" "$fallback_url" 2>/dev/null || true)"
            if [ "$code" = "200" ] && [ -s "$outfile" ]; then
                return 0
            fi
        done <<< "$PROXY_LIST"
    else
        # 无代理 → 直连
        local code
        code="$(curl -sL -o "$outfile" -w "%{http_code}" \
            --connect-timeout 8 --max-time 15 "$primary_url" 2>/dev/null || true)"
        if [ "$code" = "200" ] && [ -s "$outfile" ]; then
            return 0
        fi

        rm -f "$outfile"
        code="$(curl -sL -o "$outfile" -w "%{http_code}" \
            --connect-timeout 8 --max-time 15 "$fallback_url" 2>/dev/null || true)"
        if [ "$code" = "200" ] && [ -s "$outfile" ]; then
            return 0
        fi
    fi

    rm -f "$outfile"
    return 1
}

# ── 部署部分结果 ──
# 直接调用 generate-config.py → restart sing-box → 重新检测代理
deploy_partial() {
    info "  部署部分结果..."

    python3 "$GEN_PY" --configs "$OUTPUT_DIR" --output "$OUTPUT_DIR/config.json" || {
        warn "generate-config.py 失败，跳过本轮部署"
        return 1
    }

    if command -v systemctl &>/dev/null; then
        sudo systemctl restart sing-box 2>/dev/null || \
        sudo systemctl restart sing-box-chromego 2>/dev/null || true
        sleep 2
    fi

    auto_detect_proxies || true
    if [ -z "${PROXY_LIST:-}" ]; then
        warn "新配置部署后仍无可用代理，无法继续重试"
        return 1
    fi
    ok "部署完成，可用代理: $(echo "$PROXY_LIST" | wc -l | tr -d ' ') 个"
    return 0
}

# ═══════════════════════════════════════
# Main
# ═══════════════════════════════════════
main() {
    case "${1:-}" in -h|--help) usage ;; --) shift ;; esac

    if [ $# -ge 1 ] && [ "${1:0:1}" != "-" ]; then
        OUTPUT_DIR="$1"
    fi

    echo ""
    echo "══════════════════════════════════════"
    info "  source-chromego — proxy config fetch"
    echo "══════════════════════════════════════"
    echo ""
    ok "输出目录: $OUTPUT_DIR"

    mkdir -p "$OUTPUT_DIR"

    # 前置检查
    command -v python3 &>/dev/null || { err "需要 python3"; exit 1; }

    # 检测可用代理
    auto_detect_proxies || true
    if [ -n "${PROXY_ADDR:-}" ]; then
        ok "主代理: $PROXY_ADDR"
        local proxy_count
        proxy_count="$(echo "$PROXY_LIST" | sed '/^$/d' | wc -l | tr -d ' ')"
        ok "候选代理: ${proxy_count} 个"
    else
        info "  未检测到本地代理，将以直连方式下载"
    fi

    # ────────── Phase 1: 初始下载 ──────────
    echo ""
    echo "[1/2] 初始下载..."
    echo ""

    TOTAL=0
    SUCCESS=0
    FAIL=0
    FAIL_ENTRIES=()     # "protocol:batch" 字符串

    # 计算总 batch 数
    for entry in "${PROTOCOLS[@]}"; do
        local rest="${entry#*:}"
        local max="${rest%%:*}"
        TOTAL=$((TOTAL + max))
    done

    for entry in "${PROTOCOLS[@]}"; do
        local name="${entry%%:*}"
        local rest="${entry#*:}"
        local max="${rest%%:*}"
        local ext="${rest#*:}"

        local proto_dir="$OUTPUT_DIR/$name"
        mkdir -p "$proto_dir"

        info "[$name] 探测 batches 1-${max} ..."

        for ((batch=1; batch<=max; batch++)); do
            local outfile="$proto_dir/$batch.$ext"

            if try_batch_download "$name" "$batch" "$ext" "$outfile"; then
                ok "[$name] batch $batch"
                SUCCESS=$((SUCCESS + 1))
            else
                # HTTP 404 = 正常结束，不算失败
                local http_code
                http_code="$(curl -sL -o /dev/null -w "%{http_code}" \
                    --connect-timeout 5 --max-time 10 \
                    "${FALLBACK_BASE}/${name}/${batch}/config.${ext}" 2>/dev/null || true)"
                if [ "$http_code" != "404" ]; then
                    err "[$name] batch $batch 失败 (HTTP $http_code)"
                    FAIL=$((FAIL + 1))
                    FAIL_ENTRIES+=("${name}:${batch}")
                fi
                rm -f "$outfile" 2>/dev/null || true
            fi
        done

        # 清理空目录
        rmdir "$proto_dir" 2>/dev/null || true
    done

    echo ""
    echo "  初始下载: ${SUCCESS} 成功, ${FAIL} 失败"

    # Guard: 全部失败
    if [ "$SUCCESS" -eq 0 ]; then
        err "全部下载失败，无可用源可部署，退出"
        exit 1
    fi

    # ────────── Phase 2: 递归重试 ──────────
    local retry_round=0
    while [ "$FAIL" -gt 0 ] && [ "$retry_round" -lt "$MAX_RETRY" ]; do
        retry_round=$((retry_round + 1))
        echo ""
        echo "───────────────────────────────────────"
        info "  递归重试第 ${retry_round} 轮 (剩余 ${FAIL} 个 batch)"
        echo "───────────────────────────────────────"

        deploy_partial || break

        local new_success=0
        local still_fail=0
        local new_fail_entries=()

        echo ""
        echo "  重试失败 batch..."
        for fe in "${FAIL_ENTRIES[@]}"; do
            local proto="${fe%%:*}"
            local batchn="${fe#*:}"
            local fext=""
            # 找到对应的扩展名
            for e in "${PROTOCOLS[@]}"; do
                if [ "${e%%:*}" = "$proto" ]; then
                    local r="${e#*:}"
                    fext="${r#*:}"
                    break
                fi
            done
            [ -z "$fext" ] && continue

            local proto_dir="$OUTPUT_DIR/$proto"
            mkdir -p "$proto_dir"
            local outfile="$proto_dir/$batchn.$fext"

            if try_batch_download "$proto" "$batchn" "$fext" "$outfile"; then
                ok "[$proto] batch $batchn 重试成功"
                new_success=$((new_success + 1))
                SUCCESS=$((SUCCESS + 1))
            else
                still_fail=$((still_fail + 1))
                new_fail_entries+=("$fe")
            fi
        done

        if [ "$new_success" -eq 0 ]; then
            warn "本轮无新下载，停止递归"
            FAIL_ENTRIES=("${new_fail_entries[@]}")
            FAIL="$still_fail"
            break
        fi

        FAIL_ENTRIES=("${new_fail_entries[@]}")
        FAIL="$still_fail"
        ok "本轮下载 ${new_success} 个, 剩余失败 ${FAIL} 个"
    done

    # ────────── Phase 3: 结果报告 ──────────
    echo ""
    echo "══════════════════════════════════════"
    echo "  完成"
    echo ""
    echo "  总 batch: $TOTAL"
    [ "$SUCCESS" -gt 0 ]  && ok "${SUCCESS} 成功"
    [ "$FAIL"   -gt 0 ]  && err "${FAIL} 失败"
    echo ""

    echo "按协议:"
    for entry in "${PROTOCOLS[@]}"; do
        local name="${entry%%:*}"
        local proto_dir="$OUTPUT_DIR/$name"
        if [ -d "$proto_dir" ]; then
            local count
            count="$(find "$proto_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
            if [ "$count" -gt 0 ]; then
                ok "$name: $count batches"
            else
                warn "$name: 无可用"
            fi
        else
            warn "$name: 无可用"
        fi
    done
    echo ""
}

main "$@"
