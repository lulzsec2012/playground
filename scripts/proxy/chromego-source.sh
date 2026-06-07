#!/usr/bin/env bash
# chromego-source.sh — 从 ChromeGo 上游 GitLab 源下载免费代理配置
#
# ChromeGo 项目（bannedbook/fanqiang）在 GitLab 维护了多个协议的最新可用代理，
# 包含 VLESS+REALITY+XHTTP、Hysteria2、Sing-box 等新一代协议的原生配置。
# 本脚本直接从该源下载配置，无需 700MB 的 ChromeGo 分发包。
#
# Usage:
#   bash chromego-source.sh                          # download to default dir
#   bash chromego-source.sh ./my_configs              # custom output dir
#   bash chromego-source.sh --help                    # show help
#
# Output structure:
#   <output_dir>/<protocol>/<batch>.<ext>
#   e.g. chromego_configs/xray/1.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/chromego_configs}"

# www.gitlabip.xyz is a GitLab reverse proxy with better reachability inside CN
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
        name="${entry%%:*}"
        rest="${entry#*:}"
        max="${rest%%:*}"
        ext="${rest#*:}"
        echo "  - $name  (up to $max batches, .$ext)"
    done
    echo ""
    echo "Primary: $PRIMARY_BASE"
    echo "Fallback: $FALLBACK_BASE"
    exit 0
}

main() {
    case "${1:-}" in -h|--help) usage ;; --) shift ;; esac

    if [ $# -ge 1 ] && [ "${1:0:1}" != "-" ]; then
        OUTPUT_DIR="$1"
    fi

    echo ""
    echo "══════════════════════════════════════"
    echo "  chromego-source — proxy config fetch"
    echo "══════════════════════════════════════"
    echo ""
    echo "  output: $OUTPUT_DIR"
    echo ""

    mkdir -p "$OUTPUT_DIR"

    TOTAL=0
    SUCCESS=0
    FAIL=0
    FAIL_DETAILS=""

    for entry in "${PROTOCOLS[@]}"; do
        name="${entry%%:*}"
        rest="${entry#*:}"
        max="${rest%%:*}"
        ext="${rest#*:}"

        PROTO_DIR="$OUTPUT_DIR/$name"
        mkdir -p "$PROTO_DIR"

        info "[$name] probing batches 1-$max ..."

        for ((batch=1; batch<=max; batch++)); do
            TOTAL=$((TOTAL + 1))
            OUTFILE="$PROTO_DIR/$batch.$ext"

            primary_url="${PRIMARY_BASE}/${name}/${batch}/config.${ext}"
            fallback_url="${FALLBACK_BASE}/${name}/${batch}/config.${ext}"

            HTTP_CODE=$(curl -sL -o "$OUTFILE" -w "%{http_code}" \
                --connect-timeout 8 --max-time 15 \
                --retry 2 --retry-delay 2 \
                "$primary_url" 2>/dev/null || true)

            if [ "$HTTP_CODE" = "200" ]; then
                ok "[$name] batch $batch  (primary)"
                SUCCESS=$((SUCCESS + 1))
                continue
            fi

            rm -f "$OUTFILE"
            HTTP_CODE=$(curl -sL -o "$OUTFILE" -w "%{http_code}" \
                --connect-timeout 8 --max-time 15 \
                --retry 2 --retry-delay 2 \
                "$fallback_url" 2>/dev/null || true)

            if [ "$HTTP_CODE" = "200" ]; then
                ok "[$name] batch $batch  (fallback)"
                SUCCESS=$((SUCCESS + 1))
                continue
            fi

            rm -f "$OUTFILE"
            if [ "$HTTP_CODE" != "404" ]; then
                err "[$name] batch $batch  failed (HTTP $HTTP_CODE)"
                FAIL=$((FAIL + 1))
                FAIL_DETAILS+="  [$name] batch $batch → HTTP $HTTP_CODE"$'\n'
            fi
        done

        rmdir "$PROTO_DIR" 2>/dev/null || true
    done

    echo ""
    echo "══════════════════════════════════════"
    echo "  done"
    echo ""
    echo "  total: $TOTAL batches"
    [ "$SUCCESS" -gt 0 ] && ok "$SUCCESS succeeded"
    [ "$FAIL" -gt 0 ] && err "$FAIL failed"
    echo ""

    echo "by protocol:"
    for entry in "${PROTOCOLS[@]}"; do
        name="${entry%%:*}"
        PROTO_DIR="$OUTPUT_DIR/$name"
        if [ -d "$PROTO_DIR" ]; then
            count=$(find "$PROTO_DIR" -type f | wc -l)
            if [ "$count" -gt 0 ]; then
                ok "$name: $count batches"
            else
                warn "$name: none available"
            fi
        else
            warn "$name: none available"
        fi
    done
    echo ""

    if [ -n "$FAIL_DETAILS" ]; then
        echo "failures:"
        echo -n "$FAIL_DETAILS"
        echo ""
    fi

    if [ "$SUCCESS" -eq 0 ]; then
        err "all downloads failed"
        echo ""
        echo "possible causes:"
        echo "  • cannot reach GitLab (try different network)"
        echo "  • upstream source moved or shut down"
        echo "  • proxy/VPN is blocking GitLab"
        exit 1
    fi
}

main "$@"
