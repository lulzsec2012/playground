#!/usr/bin/env bash
#
# add-account.sh — MIXAPI 管理员账号管理
#
# 用法:
#   ./add-account.sh                          # 交互式创建新管理员
#   ./add-account.sh --only-change-root       # 只改 root 密码
#
# 依赖凭证: ~/.mixapi/.credentials（由 mixapi.sh init 生成）
#   创建新管理员 → 使用 sync-worker 登录
#   修改 root   → 使用 root 登录

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"
source "${SCRIPT_DIR}/lib/lib-mixapi.sh"

# ==== 参数 ====
ONLY_CHANGE_ROOT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only-change-root) ONLY_CHANGE_ROOT=true; shift ;;
    -h|--help)
      echo "用法: $0 [--only-change-root]"
      echo ""
      echo "  --only-change-root  只修改 root 密码，不创建新账号"
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ==== 加载凭证 ====
CRED_JSON=$(load_credentials_raw)
if [[ -z "$CRED_JSON" ]]; then
  die "未找到凭证文件 ${CREDENTIALS_FILE}，请先运行 mixapi.sh init"
fi

# ==== 主流程 ====
main() {
  if [[ "$ONLY_CHANGE_ROOT" == true ]]; then
    change_root_password
  else
    create_admin_user
  fi
}

# ---- 修改 root 密码 ----
change_root_password() {
  section "修改 root 密码"

  local root_pass
  root_pass=$(extract_credential "$CRED_JSON" "root")
  if [[ -z "$root_pass" ]]; then
    die "无法从凭证文件中读取 root 密码"
  fi

  # 登录
  info "  使用 root 身份登录..."
  if ! mixapi_login "root" "$root_pass"; then
    die "root 登录失败，请检查凭证或 MIXAPI 状态"
  fi
  ok "root 登录成功"
  echo ""

  # 输入新密码
  local new_pass new_confirm
  read -s -p "  输入新 root 密码: " new_pass
  echo ""
  read -s -p "  确认新 root 密码: " new_confirm
  echo ""
  echo ""

  [[ -z "$new_pass" ]] && die "密码不能为空"
  [[ "$new_pass" != "$new_confirm" ]] && die "两次密码不一致"

  # 获取 root 用户 ID
  local root_id
  root_id=$(curl -s "${BASE_URL}/api/user/" -b "$_COOKIE_JAR" 2>/dev/null \
    | grep -o '"id":[0-9]*,"username":"root"' \
    | grep -o '"id":[0-9]*' \
    | grep -o '[0-9]*' \
    | head -1)

  if [[ -z "$root_id" ]]; then
    die "无法获取 root 用户 ID"
  fi

  # 更新密码
  local json
  json=$(python3 -c "
import json
print(json.dumps({'id': ${root_id}, 'username': 'root', 'password': '${new_pass}'}))
")
  local resp
  resp=$(curl -s -X PUT "${BASE_URL}/api/user/" \
    -H "Content-Type: application/json" \
    -b "$_COOKIE_JAR" \
    -d "${json}" 2>/dev/null)

  if echo "$resp" | grep -q '"success":true'; then
    ok "root 密码已修改"
    # 更新凭证文件
    local updated_creds
    updated_creds=$(python3 <<- 'PYEOF'
import sys, json
data = json.loads(sys.stdin.read())
data['root']['password'] = '${new_pass}'
print(json.dumps(data, indent=2, ensure_ascii=False))
PYEOF
    )
    save_credentials "$updated_creds"
    ok "凭证文件已更新"
    warn "请记住新密码！旧密码已失效"
  else
    local err
    err=$(echo "$resp" | head -c 150)
    die "修改失败: ${err}"
  fi
}

# ---- 创建新管理员 ----
create_admin_user() {
  section "创建新管理员账号"

  # 用 sync-worker 登录
  local worker_pass
  worker_pass=$(extract_credential "$CRED_JSON" "sync-worker")
  if [[ -z "$worker_pass" ]]; then
    die "无法从凭证文件中读取 sync-worker 密码"
  fi

  info "  使用 sync-worker 登录..."
  if ! mixapi_login "sync-worker" "$worker_pass"; then
    die "sync-worker 登录失败，请检查凭证"
  fi
  ok "sync-worker 登录成功"
  echo ""

  info "  即将创建一个独立的管理员账号，用于日常管理操作。"
  echo ""

  # 输入用户名
  local default_user="admin"
  local new_user
  read -p "  用户名 (默认: ${default_user}): " new_user
  new_user="${new_user:-${default_user}}"

  # 输入密码
  local new_pass new_confirm
  while true; do
    read -s -p "  密码: " new_pass
    echo ""
    [[ -z "$new_pass" ]] && { warn "密码不能为空"; continue; }
    [[ ${#new_pass} -lt 8 ]] && { warn "密码至少 8 位"; continue; }

    read -s -p "  确认密码: " new_confirm
    echo ""
    [[ "$new_pass" != "$new_confirm" ]] && { warn "两次密码不一致，重新输入"; continue; }
    break
  done
  echo ""

  # 提交创建
  section "提交创建"

  if mixapi_create_user "$new_user" "$new_pass"; then
    ok "账号创建成功！"
    echo ""
    echo "  ┌──────────────────────────────────────"
    echo "  │  用户名:   ${new_user}"
    echo "  │  密码:     (已设置)"
    echo "  └──────────────────────────────────────"
    echo ""
    warn "建议：用此账号登录管理后台，root 账号仅在必要时使用。"
  else
    die "账号创建失败"
  fi
}

main "$@"
