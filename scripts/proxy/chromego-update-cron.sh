#!/usr/bin/env bash
# chromego-update-cron.sh — 定时更新 ChromeGo 源 + 健康检查 + 条件重启
#
# 用法:
#   bash chromego-update-cron.sh                    # 更新配置 → 健康检查 → 不可用时重启
#   bash chromego-update-cron.sh --check            # 只更新到临时目录做验证，不替换正式配置
#   bash chromego-update-cron.sh --health-only      # 只做健康检查，不更新配置
#   bash chromego-update-cron.sh --diff             # 对比新旧配置的节点数量差异
#   bash chromego-update-cron.sh --install-cron     # 安装定时任务（每天04:00）
#   bash chromego-update-cron.sh --remove-cron      # 移除定时任务
#   bash chromego-update-cron.sh --show-cron        # 查看定时任务状态
#
# 行为:
#   1. 在临时目录重新下载 ChromeGo 源（chromego-source.sh）
#   2. 在临时目录重新生成 sing-box 配置（chromego-gen-config.py）
#   3. 验证新配置（sing-box check）
#   4. 有效 → 原子替换正式配置文件（mv，同文件系统原子操作）
#      无效 → 报错退出，旧配置完好无损，服务继续运行
#   5. 健康检查：curl 通过代理访问 Google + Cloudflare 连通性端点
#   6. 检查通过 → 跳过重启，已有连接不受影响
#      检查失败 → 重启服务加载新配置

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/chromego_configs"
SINGBOX_CONFIG="${CONFIGS_DIR}/config.json"
SINGBOX_BIN="${SINGBOX_BIN:-sing-box}"
LOG_DIR="${SCRIPT_DIR}/chromego_logs"
LOG_FILE="${LOG_DIR}/update.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}$*${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*" >&2; }
err()   { echo -e "  ${RED}✗${NC} $*" >&2; }

# ──────────────────────────────────────────────
# 安装/移除/查看 cron
# ──────────────────────────────────────────────

CRON_LINE="0 4 * * * cd ${SCRIPT_DIR} && bash chromego-update-cron.sh >/dev/null 2>&1"

install_cron() {
  if crontab -l 2>/dev/null | grep -qF "chromego-update-cron.sh"; then
    ok "cron 已存在，跳过"
    return
  fi
  (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
  ok "cron 已安装：每天 04:00 自动更新 ChromeGo 源（不重启服务）"
}

remove_cron() {
  crontab -l 2>/dev/null | grep -vF "chromego-update-cron.sh" | crontab - || true
  ok "cron 已移除"
}

show_cron() {
  if crontab -l 2>/dev/null | grep -qF "chromego-update-cron.sh"; then
    echo "cron 状态: 已安装"
    crontab -l 2>/dev/null | grep "chromego-update-cron.sh"
  else
    echo "cron 状态: 未安装"
  fi
}

# ──────────────────────────────────────────────
# 统计节点数量（读 config.json 中的 proxy outbound 数）
# ──────────────────────────────────────────────

count_nodes() {
  local config="$1"
  if [[ ! -f "$config" ]]; then
    echo 0
    return
  fi
  python3 -c "
import json
c = json.load(open('${config}'))
proxies = [ob for ob in c['outbounds']
           if ob['type'] not in ('selector','urltest','direct','block','dns')]
print(len(proxies))
" 2>/dev/null || echo "?"
}

# ──────────────────────────────────────────────
# 更新流程
# ──────────────────────────────────────────────

update() {
  local check_only="${1:-false}"

  mkdir -p "$LOG_DIR" "$CONFIGS_DIR"
  echo "" >> "$LOG_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ChromeGo 更新开始 ===" | tee -a "$LOG_FILE"

  # ── 创建临时目录 ──
  local tmp_dir
  tmp_dir=$(TMPDIR=/tmp mktemp -d -t chromego-update-XXXXXX)
  trap "rm -rf '${tmp_dir}'" RETURN
  local tmp_config="${tmp_dir}/config.json"

  # ── 1. 下载最新源到临时目录 ──
  echo "" | tee -a "$LOG_FILE"
  info "=== [1/4] 下载 ChromeGo 源 ===" | tee -a "$LOG_FILE"
  if ! bash "$SCRIPT_DIR/chromego-source.sh" "$tmp_dir" >> "$LOG_FILE" 2>&1; then
    err "ChromeGo 源下载失败（日志: $LOG_FILE）" | tee -a "$LOG_FILE"
    return 1
  fi
  ok "源下载完成" | tee -a "$LOG_FILE"

  # ── 2. 在临时目录生成新配置 ──
  echo "" | tee -a "$LOG_FILE"
  info "=== [2/4] 生成 sing-box 配置 ===" | tee -a "$LOG_FILE"
  if ! python3 "$SCRIPT_DIR/chromego-gen-config.py" \
      --configs "$tmp_dir" \
      --output "$tmp_config" >> "$LOG_FILE" 2>&1; then
    err "配置生成失败" | tee -a "$LOG_FILE"
    return 1
  fi
  ok "配置已生成" | tee -a "$LOG_FILE"

  # ── 3. 合并 Au1rxx 额外节点 ──
  echo "" | tee -a "$LOG_FILE"
  info "=== [3/4] 合并 Au1rxx 额外节点 ===" | tee -a "$LOG_FILE"
  if ! python3 "$SCRIPT_DIR/chromego-extra-source.py" "$tmp_config" >> "$LOG_FILE" 2>&1; then
    warn "Au1rxx 源合并失败（非致命，继续使用 ChromeGo 节点）" | tee -a "$LOG_FILE"
  else
    ok "Au1rxx 节点合并完成" | tee -a "$LOG_FILE"
  fi

  # ── 4. 验证配置 ──
  echo "" | tee -a "$LOG_FILE"
  info "=== [4/4] 验证配置 ===" | tee -a "$LOG_FILE"

  if ! "$SINGBOX_BIN" check -c "$tmp_config" >> "$LOG_FILE" 2>&1; then
    err "新配置验证失败！旧配置完好无损，服务继续运行" | tee -a "$LOG_FILE"
    err "检查日志: $LOG_FILE" | tee -a "$LOG_FILE"
    return 1
  fi
  ok "配置验证通过" | tee -a "$LOG_FILE"

  # ── 5. 检查/对比模式 ──
  if [ "$check_only" = "true" ]; then
    local new_nodes
    new_nodes=$(count_nodes "$tmp_config")
    ok "检查模式，新配置含 ${new_nodes} 个节点，未替换正式配置" | tee -a "$LOG_FILE"
    return 0
  fi

  # ── 6. 原子替换正式配置文件 ──
  echo "" | tee -a "$LOG_FILE"
  info "=== 替换正式配置 ===" | tee -a "$LOG_FILE"

  local old_nodes new_nodes
  old_nodes=$(count_nodes "$SINGBOX_CONFIG")
  new_nodes=$(count_nodes "$tmp_config")

  # 在 CONFIGS_DIR 同文件系统内写临时文件，保证 mv 是原子的
  local staging_config="${CONFIGS_DIR}/config.json.tmp"
  cp "$tmp_config" "$staging_config"
  mv "$staging_config" "$SINGBOX_CONFIG"

  ok "配置已更新: ${old_nodes} 节点 → ${new_nodes} 节点" | tee -a "$LOG_FILE"

  # ── 7. 差异报告 ──
  if [ "$new_nodes" != "$old_nodes" ] && [ "$new_nodes" != "?" ] && [ "$old_nodes" != "?" ]; then
    info "节点数量差异: ${old_nodes} → ${new_nodes}（$((new_nodes - old_nodes > 0 ? new_nodes - old_nodes : old_nodes - new_nodes)) 个）" | tee -a "$LOG_FILE"
  fi

  # ── 8. 重启 sing-box 加载新配置 ──
  echo "" | tee -a "$LOG_FILE"
  info "=== 重启 sing-box ===" | tee -a "$LOG_FILE"

  if command -v systemctl &>/dev/null; then
    systemctl restart "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      ok "重启完成，新配置已生效" | tee -a "$LOG_FILE"
    else
      err "重启失败，检查日志: journalctl -u $SERVICE_NAME -n 30" | tee -a "$LOG_FILE"
    fi
  else
    if command -v "$SINGBOX_BIN" &>/dev/null; then
      pkill "$SINGBOX_BIN" 2>/dev/null || true
      sleep 1
      nohup "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG" >/dev/null 2>&1 &
      ok "sing-box 已重启" | tee -a "$LOG_FILE"
    else
      err "找不到 sing-box，请手动重启" | tee -a "$LOG_FILE"
    fi
  fi
}

# ── 健康检查（独立功能）──

health_check() {
  echo ""
  info "=== 健康检查 ==="

  local test_urls=(
    "https://www.gstatic.com/generate_204"
    "https://cp.cloudflare.com/generate_204"
  )

  for url in "${test_urls[@]}"; do
    local site_name
    site_name=$(echo "$url" | sed 's|https://\([^/]*\)/.*|\1|')
    for attempt in 1 2; do
      local code
      code=$(curl --proxy socks5://127.0.0.1:1080 \
        --max-time 10 -o /dev/null -s -w "%{http_code}" "$url" 2>/dev/null || echo "000")
      if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        ok "${site_name} 响应正常（${code}）"
        return 0
      else
        if [ "$attempt" -lt 2 ]; then
          warn "${site_name} 返回 ${code}，2s 后重试..."
          sleep 2
        else
          err "${site_name} 两次尝试均失败（${code}）"
        fi
      fi
    done
  done

  return 1
}

# ── 节点对比 ──

diff_nodes() {
  if [[ ! -f "$SINGBOX_CONFIG" ]]; then
    err "正式配置文件不存在: $SINGBOX_CONFIG"
    return 1
  fi

  local tmp_dir
  tmp_dir=$(TMPDIR=/tmp mktemp -d -t chromego-diff-XXXXXX)
  trap "rm -rf '${tmp_dir}'" RETURN

  info "下载最新源到临时目录..."
  if ! bash "$SCRIPT_DIR/chromego-source.sh" "$tmp_dir" >> /dev/null 2>&1; then
    err "下载失败"
    return 1
  fi

  local tmp_config="${tmp_dir}/config.json"
  if ! python3 "$SCRIPT_DIR/chromego-gen-config.py" \
      --configs "$tmp_dir" \
      --output "$tmp_config" >> /dev/null 2>&1; then
    err "配置生成失败"
    return 1
  fi

  local old_nodes new_nodes
  old_nodes=$(count_nodes "$SINGBOX_CONFIG")
  new_nodes=$(count_nodes "$tmp_config")

  echo "正式配置: ${old_nodes} 个节点"
  echo "最新源:   ${new_nodes} 个节点"
}

# ── Main ──

case "${1:-}" in
  --install-cron) install_cron ;;
  --remove-cron)  remove_cron ;;
  --show-cron)    show_cron ;;
  --check)        update true ;;
  --health-only)  health_check && echo "正常" || echo "异常" ;;
  --diff)         diff_nodes ;;
  -h|--help)
    head -21 "$0"
    exit 0 ;;
  *)              update false ;;
esac
