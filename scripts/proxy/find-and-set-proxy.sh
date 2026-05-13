#!/usr/bin/env bash
# find-and-set-proxy.sh — 扫描 tailnet 发现可用代理并配置 git
#
# 用法:
#   source find-and-set-proxy.sh           # 扫描并设置代理
#   source find-and-set-proxy.sh --test    # 只测试不设置
#   source find-and-set-proxy.sh --show    # 显示当前代理状态
#
# 注意: 需要用 source 执行才能在当前 shell 设置环境变量

set -euo pipefail

# ===== 配置 =====
# 探测的代理端口:
#   7890  Clash/Stash 混合端口 (HTTP + SOCKS5)
#   7897  Clash HTTP 代理专用
#   7891  Clash 混合端口备用
#   1080  传统 SOCKS5
#   10808 Clash 新版本 SOCKS5
#   3128  Squid HTTP
#   8080  通用 HTTP
PROBE_PORTS="7890 7897 7891 1080 10808 3128 8080"
CONTAINER_NAME="ts-aliyun-basic"
TIMEOUT=3
SKIP_NODES="aliyun-basic cn-derp"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "${CYAN}$1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }

SHOW_ONLY=false
[[ $# -ge 1 ]] && {
  case "$1" in
    --show|--status)
      echo -e "${CYAN}当前代理状态:${NC}"
      echo "  http_proxy=${http_proxy:-未设置}"
      echo "  https_proxy=${https_proxy:-未设置}"
      echo "  git http.proxy=$(git config --global http.proxy 2>/dev/null || echo 未设置)"
      exit 0 ;;
    --test) SHOW_ONLY=true ;;
    -h|--help)
      echo "用法: source find-and-set-proxy.sh [--test|--show]"
      echo "  source 执行才能修改当前 shell 环境变量"
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
}

echo ""
info "══════════════════════════════════════"
info "  Tailnet 代理扫描"
info "══════════════════════════════════════"
echo ""

# ===== 1. 获取在线节点 =====
NODES=$(docker exec "$CONTAINER_NAME" tailscale status 2>/dev/null | \
  awk '/^100\./ && !/offline/ {print $1, $2}') || {
  err "无法获取 tailscale 节点列表，容器 $CONTAINER_NAME 是否在运行？"
  exit 1
}
[ -z "$NODES" ] && { warn "tailnet 中没有在线节点"; exit 1; }

TARGETS=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ip=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  skip=false
  for s in $SKIP_NODES; do [ "$name" = "$s" ] && skip=true; done
  $skip && continue
  TARGETS+="$ip $name"$'\n'
done <<< "$NODES"

echo "  在线节点: $(echo "$NODES" | wc -l) → 待扫描: $(echo "$TARGETS" | wc -l)"
if [ -z "$TARGETS" ]; then
  warn "没有需要扫描的节点（所有在线节点都在跳过列表中）"
  exit 1
fi
echo ""

# ===== 2. 扫描端口 =====
info "[1/3] 扫描代理端口..."
echo ""

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

scan_node() {
  local ip=$1 name=$2
  for port in $PROBE_PORTS; do
    timeout $TIMEOUT bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null && echo "FOUND|$ip|$name|$port"
  done
}

running=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ip=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  ( scan_node "$ip" "$name" > "$TMPDIR/scan_$(echo $ip | tr '.' '_')" ) &
  running=$((running + 1))
  [ $running -ge 6 ] && { wait -n 2>/dev/null || true; running=$((running - 1)); }
done <<< "$TARGETS"
wait

OPEN_PORTS=$(cat "$TMPDIR"/scan_* 2>/dev/null)

if [ -z "$OPEN_PORTS" ]; then
  warn "所有节点上的代理端口均未开放"
  echo ""
  echo "  ─── 问题排查 ───"
  echo "  扫描了以下节点:"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "    - $(echo "$line" | awk '{print $2}') ($(echo "$line" | awk '{print $1}'))"
  done <<< "$TARGETS"
  echo ""
  echo "  扫描了以下端口: $PROBE_PORTS"
  echo ""
  echo "  可能原因:"
  echo "    • Clash/Stash 未在这些机器上运行"
  echo "    • 代理端口不是上述默认端口（需你确认后修改 PROBE_PORTS）"
  echo "    • 防火墙/安全组阻止了端口访问"
  echo ""
  warn "无法自动设置代理，请手动配置:"
  echo "    export http_proxy=http://your-proxy-ip:port"
  echo "    export https_proxy=http://your-proxy-ip:port"
  echo ""
  exit 1
fi

echo "$OPEN_PORTS" | while IFS='|' read -r _ ip name port; do
  ok "$name ($ip:$port) 端口开放"
done
echo ""

# ===== 3. 测试代理（三关验证：GitHub + Google + Git clone）=====
info "[2/3] 验证代理功能（需同时通过 GitHub、Google、Git 三项测试）..."
echo ""

BEST_PROXY=""
BEST_TYPE=""
BEST_NAME=""

while IFS='|' read -r _ ip name port; do
  # 已找到代理则跳过
  [ -n "$BEST_PROXY" ] && continue

    flag=""
    url_prefix=""
    if [ "$proxy_type" = "http" ]; then
      flag="-x http://$ip:$port"
      url_prefix="http"
    else
      flag="--socks5 $ip:$port"
      url_prefix="socks5"
    fi

    # ---- 第一关: GitHub 可达 ----
    gh_code=$(curl -s --connect-timeout 3 --max-time 5 $flag \
      -o /dev/null -w "%{http_code}" "https://github.com" 2>/dev/null || true)
    [ "$gh_code" != "200" ] && continue

    # ---- 第二关: Google 可达 ----
    gg_code=$(curl -s --connect-timeout 3 --max-time 5 $flag \
      -o /dev/null -w "%{http_code}" "https://www.google.com" 2>/dev/null || true)
    [ "$gg_code" != "200" ] && { err "$name ($ip:$port) → $proxy_type 测试: GitHub ✅ Google ❌"; continue; }

    # ---- 第三关: Git clone 可用 ----
    if ! git -c http.proxy="$url_prefix://$ip:$port" \
      ls-remote --heads https://github.com/aiprodcoder/MIXAPI.git \
      &>/dev/null; then
      err "$name ($ip:$port) → $proxy_type 测试: GitHub ✅ Google ✅ Git ❌"
      continue
    fi

    # 三项全过！
    ok "$name ($ip:$port) → $proxy_type 代理 ✅ (GitHub+Google+Git 全部通过)"
    BEST_PROXY="$ip:$port"
    BEST_TYPE="$proxy_type"
    BEST_NAME="$name"
    break
  done
done <<< "$OPEN_PORTS"
echo ""

# ===== 4. 结果处理 =====
if [ -z "$BEST_PROXY" ]; then
  open_count=$(echo "$OPEN_PORTS" | wc -l)
  err "找到 $open_count 个开放端口，但没有一个通过全部三项验证"
  echo ""
  echo "  ─── 验证标准 ───"
  echo "  三项验证必须全部通过:"
  echo "    ✓ https://github.com    → HTTP 200"
  echo "    ✓ https://www.google.com → HTTP 200"
  echo "    ✓ git ls-remote          → 成功"
  echo ""
  echo "  ─── 可能原因 ───"
  echo "  • 端口开放但不是代理（Web 服务器等）"
  echo "  • 代理规则限制了 Google/Git"
  echo "  • 代理出口受限"
  echo ""
  warn "请手动检查并设置: export http_proxy=http://your-proxy-ip:port"
  echo ""
  exit 1
fi

# ===== 5. 配置 =====
info "[3/3] 配置代理..."

PROXY_URL="$([ "$BEST_TYPE" = "http" ] && echo "http://$BEST_PROXY" || echo "socks5://$BEST_PROXY")"

if [ "$SHOW_ONLY" = true ]; then
  ok "发现可用代理: $PROXY_URL (来自 $BEST_NAME)"
  echo ""
  echo "  执行以下命令设置:"
  echo "    export http_proxy=$PROXY_URL"
  echo "    export https_proxy=$PROXY_URL"
  echo "    git config --global http.proxy $PROXY_URL"
  echo "    git config --global https.proxy $PROXY_URL"
  exit 0
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  warn "脚本直接执行（bash script.sh），环境变量只在此脚本内生效"
  echo ""
  echo "  已执行:"
  echo "    ✓ git config --global http.proxy = $PROXY_URL"
  echo "    ✓ git config --global https.proxy = $PROXY_URL"
  echo ""
  echo "  如需设置环境变量，请重新用 source 执行:"
  echo "    source find-and-set-proxy.sh"
  echo ""
  git config --global http.proxy "$PROXY_URL"
  git config --global https.proxy "$PROXY_URL"
else
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  git config --global http.proxy "$PROXY_URL"
  git config --global https.proxy "$PROXY_URL"

  ok "代理已配置: $PROXY_URL (来自 $BEST_NAME)"
  echo ""
  echo "  http_proxy=$PROXY_URL"
  echo "  https_proxy=$PROXY_URL"
  echo "  git 全局代理已设置"
fi
echo ""

# ===== 6. 验证 =====
echo -n "  验证 git 访问 GitHub..."
if timeout 15 git ls-remote --heads https://github.com/aiprodcoder/MIXAPI.git 2>/dev/null | grep -q .; then
  echo " ✅"
  ok "Git 可通过代理正常访问 GitHub"
else
  echo " ❌"
  warn "Git 访问 GitHub 失败"
  echo "    可能代理不支持 git 协议，尝试用 curl 下载代替:"
  echo "    curl -L -o repo.zip https://github.com/aiprodcoder/MIXAPI/archive/refs/heads/main.zip"
fi
echo ""
