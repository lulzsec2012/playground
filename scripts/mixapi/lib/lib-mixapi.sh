#!/usr/bin/env bash
#
# lib-mixapi.sh — MIXAPI API 封装 + 凭证管理
#
# Usage: source "$(dirname "$0")/lib/lib-mixapi.sh"
#
# 依赖: lib-format.sh（必须先 source）
# 环境变量:
#   MIXAPI_PORT       MIXAPI 端口（默认: 3000）
#   MIXAPI_DATA_DIR   数据目录（默认: $HOME/.mixapi）
#
# NOTE: This is a library sourced by other scripts. Do NOT add set -euo pipefail here;
# the sourcing script controls strict-mode settings.

# ============================================================
#  配置常量
# ============================================================

if [[ -z "${__LIB_MIXAPI_LOADED:-}" ]]; then
  readonly __LIB_MIXAPI_LOADED=1
fi

MIXAPI_PORT="${MIXAPI_PORT:-3000}"
MIXAPI_DATA_DIR="${MIXAPI_DATA_DIR:-${HOME}/.mixapi}"
readonly BASE_URL="http://localhost:${MIXAPI_PORT}"
readonly CREDENTIALS_FILE="${MIXAPI_DATA_DIR}/.credentials"
readonly SERVICES_FILE="${MIXAPI_DATA_DIR}/services.json"

# cookie jar 文件（由 mixapi_login 创建）
_COOKIE_JAR=""

# MIXAPI 用户 ID（由 mixapi_login 提取，用于 Admin API 的 New-Api-User 头）
_API_USER_ID=""
_CURL_ARGS=()


# ============================================================
#  凭证管理
# ============================================================

# Description: 确保 MIXAPI 数据目录存在
# Arguments:   None
# Output:      None (creates directory as side effect)
# Returns:     None
ensure_data_dir() {
  mkdir -p "${MIXAPI_DATA_DIR}"
}

# Description: 生成 16 字符随机十六进制密码（兼容 MIXAPI 最大 20 字符限制）
# Arguments:   None
# Output:      密码字符串（stdout）
# Returns:     0
generate_password() {
  python3 -c "import secrets, string; print(secrets.token_hex(8))"
}

# Description: 保存凭证 JSON 到文件，设置权限 600
# Arguments:   $1 — JSON 字符串
# Output:      None（写入文件）
# Returns:     None
save_credentials() {
  ensure_data_dir
  echo "$1" > "${CREDENTIALS_FILE}"
  chmod 600 "${CREDENTIALS_FILE}"
}

# Description: 读取凭证文件原始内容
# Arguments:   None
# Output:      文件全部 JSON 内容（stdout），文件不存在时无输出
# Returns:     0
load_credentials_raw() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    cat "${CREDENTIALS_FILE}"
  fi
}

# Description: 从凭证 JSON 中提取指定账号的密码
# Arguments:   $1 — JSON 字符串, $2 — 账号名
# Output:      密码字符串（stdout），找不到则为空
# Returns:     0
extract_credential() {
  local json="$1"
  local account="$2"
  # Use environment variable to pass account name safely into Python,
  # avoiding shell-injection risk from special characters in the value.
  _PY_ACCOUNT="$account" python3 -c "
import os, sys, json
try:
    data = json.loads(sys.stdin.read())
    print(data.get(os.environ['_PY_ACCOUNT'], {}).get('password', ''))
except:
    pass
" <<< "$json"
}


# ============================================================
#  Cookie / HTTP 辅助
# ============================================================

# Description: 创建临时 cookie jar 文件，注册 EXIT trap 自动清理
# Arguments:   None
# Output:      None（设置全局 _COOKIE_JAR）
# Returns:     None
_create_cookie_jar() {
  _COOKIE_JAR=$(mktemp)
  if [[ -z "${_MIXAPI_TRAP_SET:-}" ]]; then
    readonly _MIXAPI_TRAP_SET=1
    trap 'rm -f "${_COOKIE_JAR:-}"' EXIT
  fi
}

# Description: 构造 curl 公共参数数组（cookie jar + New-Api-User header）
# Arguments:   None（读取全局 _COOKIE_JAR, _API_USER_ID）
# Output:      None（设置全局 _CURL_ARGS）
# Returns:     None
_build_curl_args() {
  _CURL_ARGS=()
  if [[ -n "$_COOKIE_JAR" ]]; then
    _CURL_ARGS+=(-b "$_COOKIE_JAR" -c "$_COOKIE_JAR")
  fi
  if [[ -n "$_API_USER_ID" ]]; then
    _CURL_ARGS+=(-H "New-Api-User: ${_API_USER_ID}")
  fi
}

# Description: 向 MIXAPI 发起已认证的 JSON POST 请求
# Arguments:   $1 — API 路径, $2 — JSON 请求体
# Output:      API 响应（stdout）
# Returns:     None（curl 退出码被 || true 吞掉，调用方自行解析响应）
_api_post() {
  local path="$1"
  local json_body="$2"
  _build_curl_args
  curl -s -X POST "${BASE_URL}${path}" \
    -H "Content-Type: application/json" \
    "${_CURL_ARGS[@]}" \
    -d "${json_body}" 2>/dev/null || true
}

# Description: 向 MIXAPI 发起已认证的 JSON PUT 请求
# Arguments:   $1 — API 路径, $2 — JSON 请求体
# Output:      API 响应（stdout）
# Returns:     None
_api_put() {
  local path="$1"
  local json_body="$2"
  _build_curl_args
  curl -s -X PUT "${BASE_URL}${path}" \
    -H "Content-Type: application/json" \
    "${_CURL_ARGS[@]}" \
    -d "${json_body}" 2>/dev/null || true
}

# Description: 向 MIXAPI 发起已认证的 GET 请求
# Arguments:   $1 — API 路径
# Output:      API 响应（stdout）
# Returns:     None
_api_get() {
  local path="$1"
  _build_curl_args
  curl -s "${BASE_URL}${path}" \
    "${_CURL_ARGS[@]}" 2>/dev/null || true
}

# Description: 向 MIXAPI 发起已认证的 DELETE 请求
# Arguments:   $1 — API 路径
# Output:      API 响应（stdout）
# Returns:     None
_api_delete() {
  local path="$1"
  _build_curl_args
  curl -s -X DELETE "${BASE_URL}${path}" \
    "${_CURL_ARGS[@]}" 2>/dev/null || true
}

# Description: 检查 API 响应是否包含 "success":true
# Arguments:   $1 — API 响应字符串
# Output:      None
# Returns:     0=成功, 1=失败
_is_success() {
  echo "$1" | grep -q '"success":true'
}


# ============================================================
#  MIXAPI 业务 API
# ============================================================

# Description: 轮询 MIXAPI status endpoint 直到就绪或超时
# Arguments:   $1 — 最大重试次数（默认 30）, $2 — 轮询间隔秒（默认 2）
# Output:      None
# Returns:     0=就绪, 1=超时
wait_for_api() {
  local max_retries="${1:-30}"
  local interval="${2:-2}"
  local _i
  for _i in $(seq 1 "${max_retries}"); do
    if curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/status" 2>/dev/null \
      | grep -q 200; then
      return 0
    fi
    sleep "${interval}"
  done
  return 1
}

# Description: 检查 MIXAPI 是否需要初始设置
# Arguments:   None
# Output:      None
# Returns:     0=需要设置, 1=已初始化
check_setup_needed() {
  local resp
  resp=$(curl -s "${BASE_URL}/api/setup" 2>/dev/null)
  echo "$resp" | grep -q '"setup"'
}

# Description: 执行初始设置，创建 root 账号
# Arguments:   $1 — username, $2 — password
# Output:      失败时输出错误响应到 stderr
# Returns:     0=成功, 1=失败
setup_root() {
  local username="$1"
  local password="$2"
  local json
  # Pass credentials via environment to avoid shell-injection in heredoc.
  json=$(_PY_USERNAME="$username" _PY_PASSWORD="$password" python3 -c "
import json, os
print(json.dumps({
    'username': os.environ['_PY_USERNAME'],
    'password': os.environ['_PY_PASSWORD']
}))
")
  local resp
  resp=$(curl -s -X POST "${BASE_URL}/api/setup" \
    -H "Content-Type: application/json" \
    -d "${json}" 2>/dev/null)
  if _is_success "$resp"; then
    return 0
  else
    echo "$resp" >&2
    return 1
  fi
}

# Description: 登录 MIXAPI，保存 cookie 并提取用户 ID
# Arguments:   $1 — username, $2 — password
# Output:      None
# Returns:     0=成功, 1=失败
mixapi_login() {
  local username="$1"
  local password="$2"
  _create_cookie_jar
  local json
  json=$(_PY_USERNAME="$username" _PY_PASSWORD="$password" python3 -c "
import json, os
print(json.dumps({
    'username': os.environ['_PY_USERNAME'],
    'password': os.environ['_PY_PASSWORD']
}))
")
  local resp
  resp=$(curl -s -X POST "${BASE_URL}/api/user/login" \
    -H "Content-Type: application/json" \
    -c "$_COOKIE_JAR" \
    -d "${json}" 2>/dev/null)

  if _is_success "$resp"; then
    # 提取用户 ID（登录响应包含 "id":N）
    _API_USER_ID=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo)
    return 0
  else
    rm -f "$_COOKIE_JAR"
    _COOKIE_JAR=""
    _API_USER_ID=""
    return 1
  fi
}

# Description: 获取或创建访问令牌（token）
# Arguments:   $1 — token 名称
# Output:      token key 字符串（如 "sk-..."）（stdout）
# Returns:     0=成功, 1=失败（已有 token 则返回 0）
get_or_create_token() {
  local token_name="$1"
  local tokens_resp
  tokens_resp=$(_api_get "/api/token/")
  local existing
  existing=$(echo "$tokens_resp" | grep -o '"key":"sk-[^"]*"' | head -1 | sed 's/"key":"//;s/"//')
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return 0
  fi
  local json
  json=$(_PY_TOKEN_NAME="$token_name" python3 -c "
import json, os
print(json.dumps({
    'name': os.environ['_PY_TOKEN_NAME'],
    'remain_quota': 0,
    'unlimited_quota': True
}))
")
  local resp
  resp=$(_api_post "/api/token/" "${json}")
  local new_key
  new_key=$(echo "$resp" | grep -o '"key":"sk-[^"]*"' | head -1 | sed 's/"key":"//;s/"//')
  if [[ -n "$new_key" ]]; then
    echo "$new_key"
    return 0
  fi
  return 1
}


# ============================================================
#  渠道管理
# ============================================================

# Description: 列出所有渠道
# Arguments:   None
# Output:      原始 JSON 响应（stdout）
# Returns:     None
channel_list() {
  _api_get "/api/channel/?page_size=100"
}

# Description: 添加新渠道
# Arguments:   $1 name, $2 type, $3 base_url, $4 models_csv, $5 key
#              $6 tag（可选，用于 channel.sh 自动同步标记）
# Output:      失败时输出错误消息到 stderr
# Returns:     0=成功, 1=失败
channel_add() {
  local name="$1" type="$2" base_url="$3" models_csv="$4" key="$5"
  local tag="${6:-}"
  local json
  # type is numeric; pass all values via environment to avoid quoting issues
  # with special characters in names, URLs, or keys.
  json=$(_PY_TYPE="$type" _PY_NAME="$name" _PY_KEY="$key" \
    _PY_BASE_URL="$base_url" _PY_MODELS="$models_csv" _PY_TAG="$tag" python3 -c "
import json, os
channel = {
    'type': int(os.environ['_PY_TYPE']),
    'name': os.environ['_PY_NAME'],
    'key': os.environ['_PY_KEY'],
    'base_url': os.environ['_PY_BASE_URL'],
    'models': os.environ['_PY_MODELS'],
    'group': 'default',
    'status': 1
}
tag = os.environ.get('_PY_TAG', '')
if tag:
    channel['tag'] = tag
body = {'mode': 'single', 'channel': channel}
print(json.dumps(body, ensure_ascii=False))
")
  local resp
  resp=$(_api_post "/api/channel/" "${json}")
  if _is_success "$resp"; then
    return 0
  else
    local msg
    msg=$(echo "$resp" | extract_json_str "message")
    echo "[channel_add] ${msg:-$resp}" >&2
    return 1
  fi
}

# Description: 更新渠道（全量替换）
# Arguments:   $1 id, $2 name, $3 type, $4 base_url, $5 models_csv, $6 key
#              $7 tag（可选，用于 channel.sh 自动同步标记）
#              $8 status（可选，1=active, 2=disabled，用于 health.sh）
# Output:      失败时输出错误消息到 stderr
# Returns:     0=成功, 1=失败
channel_update() {
  local id="$1" name="$2" type="$3" base_url="$4" models_csv="$5" key="$6"
  local tag="${7:-}"
  local status="${8:-1}"
  local json
  json=$(_PY_ID="$id" _PY_TYPE="$type" _PY_NAME="$name" _PY_KEY="$key" \
    _PY_BASE_URL="$base_url" _PY_MODELS="$models_csv" _PY_TAG="$tag" \
    _PY_STATUS="$status" python3 -c "
import json, os
channel = {
    'id': int(os.environ['_PY_ID']),
    'type': int(os.environ['_PY_TYPE']),
    'name': os.environ['_PY_NAME'],
    'key': os.environ['_PY_KEY'],
    'base_url': os.environ['_PY_BASE_URL'],
    'models': os.environ['_PY_MODELS'],
    'group': 'default',
    'status': int(os.environ.get('_PY_STATUS', '1'))
}
tag = os.environ.get('_PY_TAG', '')
if tag:
    channel['tag'] = tag
print(json.dumps(channel, ensure_ascii=False))
")
  local resp
  resp=$(_api_put "/api/channel/" "${json}")
  if _is_success "$resp"; then
    return 0
  else
    local msg
    msg=$(echo "$resp" | extract_json_str "message")
    echo "[channel_update] ${msg:-$resp}" >&2
    return 1
  fi
}

# Description: 删除渠道
# Arguments:   $1 — channel id
# Output:      失败时输出错误消息到 stderr
# Returns:     0=成功, 1=失败
channel_delete() {
  local id="$1"
  local resp
  resp=$(_api_delete "/api/channel/${id}")
  if _is_success "$resp"; then
    return 0
  else
    local msg
    msg=$(echo "$resp" | extract_json_str "message")
    echo "[channel_delete] ${msg:-$resp}" >&2
    return 1
  fi
}

# Description: 添加新渠道（接受完整 JSON 配置，提取字段后委托 channel_add）
# Arguments:   $1 — JSON 配置字符串
# Output:      None
# Returns:     0=成功, 1=失败（委托 channel_add 的返回值）
channel_add_json() {
  local config="$1"
  local type name base_url models_csv key tag
  type=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',1))")
  name=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
  base_url=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('base_url',''))")
  models_csv=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('models',''))")
  key=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key','ollama'))")
  tag=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag',''))")
  channel_add "$name" "$type" "$base_url" "$models_csv" "$key" "$tag"
}

# Description: 更新渠道（接受完整 JSON 配置，提取字段后委托 channel_update）
# Arguments:   $1 — JSON 配置字符串
# Output:      None
# Returns:     0=成功, 1=失败（委托 channel_update 的返回值）
channel_update_json() {
  local config="$1"
  local id type name base_url models_csv key tag status
  id=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',0))")
  type=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',1))")
  name=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
  base_url=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('base_url',''))")
  models_csv=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('models',''))")
  key=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key','ollama'))")
  tag=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag',''))")
  status=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',1))")
  channel_update "$id" "$name" "$type" "$base_url" "$models_csv" "$key" "$tag" "$status"
}


# ============================================================
#  用户管理
# ============================================================

# Description: 创建新用户（不传 role 字段，避免 MIXAPI 验证失败）
# Arguments:   $1 — username, $2 — password
# Output:      失败时输出错误消息到 stderr
# Returns:     0=成功, 1=失败
mixapi_create_user() {
  local username="$1" password="$2"
  local json
  json=$(_PY_USERNAME="$username" _PY_PASSWORD="$password" python3 -c "
import json, os
print(json.dumps({
    'username': os.environ['_PY_USERNAME'],
    'password': os.environ['_PY_PASSWORD']
}))
")
  local resp
  resp=$(_api_post "/api/user/" "${json}")
  if _is_success "$resp"; then
    return 0
  else
    local msg
    msg=$(echo "$resp" | extract_json_str "message")
    echo "[create_user] ${msg:-$resp}" >&2
    return 1
  fi
}


# ============================================================
#  JSON 文件操作
# ============================================================

# Description: 原子写入 services.json（先写临时文件再 mv）
# Arguments:   $1 — JSON 内容字符串
# Output:      None
# Returns:     None
write_services_file() {
  ensure_data_dir
  local tmp_file
  tmp_file=$(mktemp "${MIXAPI_DATA_DIR}/services.json.XXXXXXXX")
  echo "$1" > "${tmp_file}"
  mv "${tmp_file}" "${SERVICES_FILE}"
}


# ============================================================
#  自动发现（当 services.json 缺失时）
# ============================================================
#
# CAUTION: This function may be called inside $() capture context.
# ALL user-facing output MUST go through ok/warn/info/die (all stderr).
# NEVER add bare echo or commands that write to stdout here.
# ============================================================

# Description: 确保 services.json 存在，不存在则自动触发全量 LLM 节点扫描
# Arguments:   None
# Output:      用户提示走 stderr（warn/info），不污染 stdout 数据通道
# Returns:     None
ensure_services_json() {
  if [[ ! -f "${SERVICES_FILE}" ]]; then
    local discover_script
    discover_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/discover.sh"
    # discover.sh uses ok/info/warn (all stderr now).
    # Redirect its remaining stdout to stderr anyway for safety.
    bash "$discover_script" --full 1>&2 || true
    if [[ ! -f "${SERVICES_FILE}" ]]; then
      # If scan still didn't create it (e.g. no nodes), write empty file
      local now
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      write_services_file "{\"updated_at\":\"$now\",\"services\":[]}"
      warn "未发现 LLM 服务，已生成空的 services.json"
    fi
  fi
}
