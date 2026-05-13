#!/usr/bin/env bash
#
# mixapi.sh — MIXAPI 统一管理入口
#
# 用法:
#   mixapi.sh init              # 一键初始化（部署 + 随机凭证 + 首次发现）
#   mixapi.sh deploy            # 部署 MIXAPI
#   mixapi.sh discover          # 全量扫描 LLM 服务
#   mixapi.sh channel           # 同步渠道到 MIXAPI
#   mixapi.sh test              # 交互式测试模型
#   mixapi.sh add-account       # 添加管理员账号
#   mixapi.sh status            # 查看发现的 LLM 服务
#   mixapi.sh cron-install      # 安装 cron 自动同步
#   mixapi.sh cron-remove       # 移除 cron 自动同步
#   mixapi.sh --cron            # cron 入口（增量扫描 + 自动同步）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"
source "${SCRIPT_DIR}/lib/lib-mixapi.sh"

# ==== Constants ====
readonly LOCK_FILE="/tmp/mixapi.lock"
readonly CRON_LOG="${HOME}/.mixapi/cron.log"

# ============ Init ============

# Description: Full initialization — deploy, setup, create credentials
do_init() {
  section "MIXAPI 初始化"

  # Create data directory
  mkdir -p "${HOME}/.mixapi"

  # Step 1: Deploy
  info "Step 1: 部署 MIXAPI..."
  if ! bash "${SCRIPT_DIR}/setup.sh"; then
    die "部署失败"
  fi

  # Step 2: Wait for API
  info "Step 2: 等待 MIXAPI 就绪..."
  sleep 3
  if ! wait_for_api; then
    die "MIXAPI 启动超时"
  fi
  ok "MIXAPI 就绪"
  echo

  # Step 3: Setup root with random password
  section "Step 3: 初始化 root 账号"
  local root_pass
  root_pass=$(generate_password)
  info "生成随机 root 密码..."

  if check_setup_needed; then
    setup_root "root" "$root_pass" || die "初始设置失败"
    ok "root 账号创建完成"
  else
    # Try login with random password first (might fail on re-init)
    if ! mixapi_login "root" "$root_pass"; then
      # Prompt for existing root password
      warn "系统已初始化，需要提供现有 root 密码"
      local existing_root_pass
      read -s -p "  请输入现有 root 密码: " existing_root_pass
      echo
      root_pass="$existing_root_pass"
      mixapi_login "root" "$root_pass" || die "root 登录失败"
    fi
  fi

  # Step 4: Create sync-worker
  section "Step 4: 创建 sync-worker 账号"
  local worker_pass
  worker_pass=$(generate_password)
  info "生成 sync-worker 账号（随机密码）..."

  if mixapi_create_user "sync-worker" "$worker_pass"; then
    ok "sync-worker 账号创建成功"
  else
    # Maybe already exists — try to login
    info "sync-worker 可能已存在，尝试登录..."
    if ! mixapi_login "sync-worker" "$worker_pass"; then
      die "无法创建或登录 sync-worker"
    fi
  fi

  # Step 5: Get or create token
  section "Step 5: 生成 API Token"
  local token
  token=$(get_or_create_token)
  if [[ -n "$token" ]]; then
    ok "API Token 就绪: sk-...${token: -8}"
  else
    warn "无法获取 Token（非关键错误，后续可手动创建）"
  fi

  # Step 6: Save credentials
  section "Step 6: 保存凭证"
  local creds_json
  creds_json=$(python3 -c "
import json
creds = {
    'root': {
        'username': 'root',
        'password': '${root_pass}'
    },
    'sync_worker': {
        'username': 'sync-worker',
        'password': '${worker_pass}'
    }
}
print(json.dumps(creds, indent=2, ensure_ascii=False))
")
  save_credentials "$creds_json"
  ok "凭证已保存: ${CREDENTIALS_FILE}"

  echo
  section "✅ 初始化完成！"

  echo
  info "  凭证文件: ${CREDENTIALS_FILE}"
  info "  root 密码: ${root_pass}"
  info "  sync-worker 密码: ${worker_pass}"
  warn "  请妥善保管 root 密码！本脚本仅保留在 .credentials 文件中"
  echo

  # Step 7: Token reminder
  if [[ -n "$token" ]]; then
    info "  API Key: ${token}"
    echo
  fi

  info "下一步操作:"
  echo "  mixapi.sh discover    — 扫描 LLM 服务"
  echo "  mixapi.sh channel     — 同步到 MIXAPI"
  echo "  mixapi.sh cron-install — 安装自动同步"
  echo
}

# ============ Status ============

do_status() {
  if [[ ! -f "$SERVICES_FILE" ]]; then
    ensure_services_json
  fi

  python3 -c "
import json, sys
with open('${SERVICES_FILE}') as f:
    data = json.load(f)
services = data.get('services', [])
updated = data.get('updated_at', 'unknown')

active = [s for s in services if s.get('status') == 'active']
inactive = [s for s in services if s.get('status') != 'active']

print('')
print('services.json 状态')
print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
print(f'  更新时间:     {updated}')
print(f'  活跃服务:     {len(active)}')
print(f'  离线服务:     {len(inactive)}')
print('')
if active:
    print('  活跃服务列表:')
    for s in active:
        models = ', '.join(s.get('models', [])[:5])
        tail = '...' if len(s.get('models', [])) > 5 else ''
        interval_min = s.get('scan_interval', 0) // 60
        print(f'    {s[\"node\"]}:{s[\"port\"]} ({s[\"service\"]})')
        print(f'      模型: {models}{tail}')
        print(f'      扫描间隔: {interval_min} 分钟')
print('')
" 2>/dev/null || die "解析 services.json 失败"
}

# ============ Cron Management ============

do_cron_install() {
  local script_path
  script_path="$(readlink -f "$0")"
  local cron_job="*/5 * * * * ${script_path} --cron >> ${CRON_LOG} 2>&1"

  # Check if already installed
  if crontab -l 2>/dev/null | grep -qF "$script_path"; then
    warn "cron 任务已存在，跳过安装"
    info "当前 cron 配置:"
    crontab -l 2>/dev/null | grep "$script_path"
    return 0
  fi

  # Install
  { crontab -l 2>/dev/null || true; echo "$cron_job"; } | crontab -
  ok "cron 已安装（每 5 分钟运行 discover --cron + channel）"
  info "日志文件: ${CRON_LOG}"
  echo
  info "如需移除: mixapi.sh cron-remove"
}

do_cron_remove() {
  local script_path
  script_path="$(readlink -f "$0")"

  if crontab -l 2>/dev/null | grep -qvF "$script_path"; then
    crontab -l 2>/dev/null | grep -vF "$script_path" | crontab -
    ok "cron 任务已移除"
  else
    # No other entries — remove entire crontab
    crontab -r 2>/dev/null || true
    ok "cron 任务已移除（清空了 crontab）"
  fi
}

# ============ Cron Entry Point ============

do_cron() {
  # File lock to prevent concurrent runs
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    echo "[cron] $(date -u +%Y-%m-%dT%H:%M:%SZ) 已有进程在运行，跳过本次" >> "$CRON_LOG"
    exit 0
  fi

  echo "[cron] $(date -u +%Y-%m-%dT%H:%M:%SZ) 开始增量扫描..." >> "$CRON_LOG"

  # Run incremental discover
  local discover_exit=0
  bash "${SCRIPT_DIR}/discover.sh" --cron >> "$CRON_LOG" 2>&1 || discover_exit=$?

  if [[ $discover_exit -eq 0 ]]; then
    # Services changed — sync channels
    echo "[cron] services 有变更，同步渠道..." >> "$CRON_LOG"
    bash "${SCRIPT_DIR}/channel.sh" >> "$CRON_LOG" 2>&1 || true
  elif [[ $discover_exit -eq 1 ]]; then
    echo "[cron] services 无变更，跳过渠道同步" >> "$CRON_LOG"
  else
    echo "[cron] discover 执行异常 (exit=${discover_exit})" >> "$CRON_LOG"
  fi

  echo "[cron] $(date -u +%Y-%m-%dT%H:%M:%SZ) 完成" >> "$CRON_LOG"
  flock -u 200
}

# ============ Main ============

usage() {
  echo "用法: $(basename "$0") <子命令>"
  echo
  echo "  初始化:"
  echo "    init              一键初始化（部署 + 凭证 + 配置）"
  echo
  echo "  管理:"
  echo "    deploy            部署 MIXAPI 容器"
  echo "    discover          全量扫描 LLM 服务"
  echo "    channel           同步渠道到 MIXAPI"
  echo "    test              测试模型推理"
  echo "    add-account       添加管理员账号"
  echo
  echo "  监控:"
  echo "    status            查看 services 状态"
  echo "    cron-install      安装 cron 自动同步（每5分钟）"
  echo "    cron-remove       移除 cron 自动同步"
  echo
  echo "  内部:"
  echo "    --cron            cron 入口（增量扫描 + 自动同步）"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    init)
      do_init "$@"
      ;;
    deploy)
      exec bash "${SCRIPT_DIR}/setup.sh" "$@"
      ;;
    discover)
      exec bash "${SCRIPT_DIR}/discover.sh" --full "$@"
      ;;
    channel)
      exec bash "${SCRIPT_DIR}/channel.sh" "$@"
      ;;
    test)
      exec bash "${SCRIPT_DIR}/test.sh" "$@"
      ;;
    add-account)
      exec bash "${SCRIPT_DIR}/add-account.sh" "$@"
      ;;
    status)
      do_status
      ;;
    cron-install)
      do_cron_install
      ;;
    cron-remove)
      do_cron_remove
      ;;
    --cron)
      do_cron "$@"
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "未知子命令: ${cmd}\n使用 -h 查看帮助" ;;
  esac
}

main "$@"
