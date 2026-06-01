#!/usr/bin/env bash
#
# fetch.sh — 从公开 GitHub 源下载免费 Clash 代理，合并到模板
#
# 用法: bash fetch.sh
#        bash fetch.sh --dry-run      # 只下载不合并，预览结果
#        bash fetch.sh --show         # 显示当前配置信息
#
# 输出: $SCRIPT_DIR/config.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGE_PY="$SCRIPT_DIR/merge.py"
OUTPUT="$SCRIPT_DIR/config.yaml"
TMPDIR=""
# 模板路径：优先脚本同目录，也可通过 TEMPLATE 环境变量覆盖
TEMPLATE="${TEMPLATE:-$SCRIPT_DIR/template.yaml}"
DRY_RUN=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}$1${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1" >&2; }
err()   { echo -e "  ${RED}✗${NC} $1" >&2; }

SOURCES=(
  "https://raw.githubusercontent.com/hello-world-1989/cn-news/refs/heads/main/clash.yaml"
  "https://github.com/Au1rxx/free-vpn-subscriptions/raw/main/output/clash.yaml"
  "https://raw.githubusercontent.com/awesome-vpn/awesome-vpn/master/clash.yaml"
  "https://raw.githubusercontent.com/PuddinCat/BestClash/refs/heads/main/proxies.yaml"
  "https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/clash.yml"
)

usage() {
    cat <<EOF
从多个 GitHub 源下载免费 Clash 代理配置，合并到模板。

用法: bash $(basename "$0") [选项]

选项:
  --dry-run   只下载预览，不执行合并
  --show      显示当前配置的节点数和来源
  -h, --help  显示此帮助

输出: ${OUTPUT}
模板: ${TEMPLATE}
EOF
    exit 1
}

cleanup() { rm -rf "$TMPDIR"; }

main() {
    case "${1:-}" in
        -h|--help) usage ;;
        --dry-run) DRY_RUN=true ;;
        --show)
            if [ -f "$OUTPUT" ]; then
                NODES=$(grep -c '^- name:' "$OUTPUT" 2>/dev/null || echo 0)
                echo "配置文件: $OUTPUT"
                echo "节点数:    $NODES"
                echo "更新于:    $(stat -f '%Sm' "$OUTPUT" 2>/dev/null || echo "未知")"
            else
                echo "配置文件不存在: $OUTPUT"
            fi
            exit 0 ;;
        '') ;;
        *) echo "未知选项: $1"; usage ;;
    esac

    echo ""
    echo "══════════════════════════════════════"
    echo "  proxy-fetch — 免费代理配置生成"
    echo "══════════════════════════════════════"
    echo ""

    if [ ! -f "$TEMPLATE" ]; then
        echo "错误: 模板不存在: $TEMPLATE" >&2
        exit 1
    fi
    if ! command -v python3 &>/dev/null; then
        echo "错误: 需要 python3" >&2
        exit 1
    fi
    echo "  OK  模板就绪"

    TMPDIR=$(mktemp -d)
    trap cleanup EXIT

    echo ""
    echo "[1/3] 下载 ${#SOURCES[@]} 个源..."
    echo ""

    DOWNLOADED=()
    SUCCESS=0
    FAIL=0

    for URL in "${SOURCES[@]}"; do
        NAME=$(echo "$URL" | sed -E 's|https?://[^/]+/||' | sed 's|/refs/heads/main/|/|' | sed 's|/raw/|/|' | cut -d'/' -f1-2)
        TMPFILE=$(mktemp "$TMPDIR/__src.XXXXXX")
        HTTP_CODE=$(curl -sL -o "$TMPFILE" -w "%{http_code}" --connect-timeout 10 --max-time 20 "$URL" 2>/dev/null)

        if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMPFILE" ]; then
            echo "  !! [$NAME] 下载失败 (HTTP $HTTP_CODE)"
            rm -f "$TMPFILE"
            FAIL=$((FAIL + 1))
            continue
        fi

        if ! grep -q '^proxies:' "$TMPFILE" 2>/dev/null; then
            echo "  !! [$NAME] 格式无效（无 proxies: 段）"
            rm -f "$TMPFILE"
            FAIL=$((FAIL + 1))
            continue
        fi

        DOWNLOADED+=("$TMPFILE")
        SUCCESS=$((SUCCESS + 1))
        echo "  OK  [$NAME]"
    done

    echo ""
    echo "  下载完成: ${SUCCESS} 成功, ${FAIL} 失败"

    if [ "$SUCCESS" -eq 0 ]; then
        echo "错误: 全部下载失败，保留旧配置" >&2
        exit 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "  DRY RUN 模式，跳过合并"
        echo "  共 ${#DOWNLOADED[@]} 个源文件已下载到 $TMPDIR"
        exit 0
    fi

    echo ""
    echo "[2/3] 合并代理到模板..."
    python3 "$MERGE_PY" "$TEMPLATE" "$OUTPUT" "${DOWNLOADED[@]}" || {
        echo "错误: 合并失败" >&2
        exit 1
    }
    echo "  OK  合并完成"

    echo ""
    echo "[3/3] 输出配置"
    NODE_COUNT=$(grep -c '^- name:' "$OUTPUT" 2>/dev/null || echo 0)
    echo "  OK  配置文件: $OUTPUT"
    echo "  OK  节点数:   ${NODE_COUNT}"
}

main "$@"
