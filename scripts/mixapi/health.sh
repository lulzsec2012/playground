#!/usr/bin/env bash
#
# health.sh — MIXAPI 后端健康监控 + abilities 一致性修复
#
# 功能:
#   1. 检测并修复 abilities 表与 channels 表一致性（清理孤儿记录）
#   2. 探测所有 channel 的 /health 端点，自动禁用/启用后端
#
# 背景:
#   MixAPI (OneAPI) 使用 abilities 表存储模型到 channel 的映射。
#   当 channel 直接通过 SQLite 删除（非 API）时，abilities 表会
#   残留孤儿记录，导致 "数据库一致性已被破坏" 错误。health.sh
#   在每次健康检查前自动修复此问题。
#
# 用法:
#   bash health.sh
#
# 依赖: lib-mixapi.sh, lib-tailnet.sh, sqlite3
# 数据: ~/.mixapi_data/mix-api.db, ~/.mixapi/health_misses.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"
source "${SCRIPT_DIR}/lib/lib-tailnet.sh"
source "${SCRIPT_DIR}/lib/lib-mixapi.sh"

readonly MISSES_FILE="${HOME}/.mixapi/health_misses.json"
readonly MAX_MISSES=3

# ---------- Miss Counter Management ----------

# Description: 加载连续失败计数器
# Output:       JSON 字符串 (channel_id → miss_count)
load_misses() {
  if [[ -f "$MISSES_FILE" ]]; then
    cat "$MISSES_FILE"
  else
    echo "{}"
  fi
}

# Description: 保存连续失败计数器
# Arguments:   $1 — JSON 字符串
save_misses() {
  echo "$1" > "$MISSES_FILE"
}

# Description: 更新某个 channel 的 miss 计数器
# Arguments:   $1 — channel id, $2 — 当前 miss 值, $3 — 是否成功 (true/false)
# Output:      新的 miss 值
update_miss_counter() {
  local cid="$1" current="${2:-0}" ok="$3"
  if [[ "$ok" == "true" ]]; then
    echo 0
  else
    echo $((current + 1))
  fi
}

# ---------- Abilities Consistency Check ----------

# Description: 检测并修复 abilities 表与 channels 表的一致性
# 背景: channnel 通过非 API 方式删除后（如直接操作 SQLite），abilities
#       表仍保留指向已删除 channel 的孤儿记录。这些孤儿记录导致 MixAPI
#       distributor 查询时出现 "数据库一致性已被破坏" 错误。
# 修复: 删除 orphan abilities + 重启 MixAPI → in-memory 缓存重建
DB_PATH="${HOME}/.mixapi_data/mix-api.db"
MIXAPI_IMAGE="mixapi"

do_abilities_check() {
  if [[ ! -f "$DB_PATH" ]]; then
    return 0
  fi

  local orphan_count missing_count info_output=""
  orphan_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM abilities WHERE channel_id NOT IN (SELECT id FROM channels);" 2>/dev/null || echo "0")

  if [[ "$orphan_count" -gt 0 ]]; then
    info_output="${orphan_count} 条孤儿 abilities"
    info "发现 ${orphan_count} 条孤儿 abilities（指向已删除 channel），清理中..."
    sqlite3 "$DB_PATH" "DELETE FROM abilities WHERE channel_id NOT IN (SELECT id FROM channels);"
    ok "已清理孤儿 abilities"

    # 重启 MixAPI 重建 in-memory cache
    info "重启 MIXAPI..."
    docker restart "$(docker ps -q --filter ancestor=${MIXAPI_IMAGE})" 2>/dev/null || true
    sleep 2
    ok "MIXAPI 重启完成"
  fi

  # 同时检查 channel 是否有缺失的 abilities
  missing_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM channels c LEFT JOIN abilities a ON c.id = a.channel_id WHERE a.channel_id IS NULL AND c.status = 1;" 2>/dev/null || echo "0")

  if [[ "$missing_count" -gt 0 ]]; then
    if [[ -z "$info_output" ]]; then
      info_output="${missing_count} 个 channel 缺失 abilities"
    else
      info_output="${info_output}，${missing_count} 个 channel 缺失 abilities"
    fi
    warn "发现 ${missing_count} 个活跃 channel 缺少 abilities 记录"
    info "运行 channel 同步以重建 abilities..."
    bash "${SCRIPT_DIR}/channel.sh" 2>/dev/null || true
    docker restart "$(docker ps -q --filter ancestor=${MIXAPI_IMAGE})" 2>/dev/null || true
    sleep 2
    ok "channel 同步完成"
  fi

  if [[ -n "$info_output" ]]; then
    info "abilities 一致性修复: ${info_output}"
  fi
}

# ---------- Health Check ----------

do_health_check() {
  section "后端健康检查"

  # Step 0: 修复 abilities 表一致性
  do_abilities_check

  # Login
  info "登录 MIXAPI..."
  local creds worker_pass
  creds=$(load_credentials_raw)
  worker_pass=$(extract_credential "$creds" "sync-worker")
  if [[ -z "$worker_pass" ]]; then
    die "无法读取 sync-worker 凭证"
  fi
  mixapi_login "sync-worker" "$worker_pass" || die "登录失败"
  ok "登录成功"

  # 1. 获取所有 channels
  info "获取 channel 列表..."
  local channels
  channels=$(channel_list || true)
  if [[ -z "$channels" ]]; then
    warn "无法获取 channel 列表或为空"
    return 1
  fi

  local total changed=0 disabled=0 enabled=0
  total=$(echo "$channels" | python3 -c "import json,sys; data=json.load(sys.stdin); items=data.get('data',{}).get('items',[]); print(len(items))" 2>/dev/null)
  info "共 ${total} 个 channel"

  # 2. 加载 miss 计数器
  local misses_json
  misses_json=$(load_misses)

  # 3. 遍历每个 channel
  local idx=0 channel_json eid etype ename ebase_url estatus
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    idx=$((idx + 1))
    channel_json="$line"

    eid=$(echo "$channel_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
    etype=$(echo "$channel_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || echo "")
    ename=$(echo "$channel_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
    ebase_url=$(echo "$channel_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('base_url',''))" 2>/dev/null || echo "")
    estatus=$(echo "$channel_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',1))" 2>/dev/null || echo "1")

    if [[ -z "$eid" ]]; then
      continue
    fi

    echo -n "  [${idx}/${total}] #${eid} ${ename} (${ebase_url}) ... "

    local healthy=false
    local status_code
    status_code=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 5 \
      "$ebase_url/health" 2>/dev/null || true)
    if [[ "$status_code" == "200" ]]; then
      healthy=true
    fi

    # 5. 更新 miss 计数器
    local current_miss
    current_miss=$(echo "$misses_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$eid', 0))" 2>/dev/null || echo "0")
    local new_miss
    new_miss=$(update_miss_counter "$eid" "$current_miss" "$healthy")
    misses_json=$(echo "$misses_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['$eid'] = $new_miss
print(json.dumps(d))
" 2>/dev/null || echo "$misses_json")

    # 6. 判断是否需要切换状态
    if [[ "$healthy" == "true" ]]; then
      # 后端正常
      if [[ "$estatus" == "2" ]]; then
        # 之前被禁用了 → 恢复
        echo "健康 ✅ (已恢复，启用中...)" >&2
        if channel_update "$eid" "$ename" "$etype" "$ebase_url" "" "ollama" "" "1"; then
          enabled=$((enabled + 1))
          changed=$((changed + 1))
        fi
      else
        echo "健康 ✅"
      fi
    else
      # 后端异常
      echo -n "异常 ❌ (${new_miss}/${MAX_MISSES})"
      if [[ "$new_miss" -ge "$MAX_MISSES" ]] && [[ "$estatus" != "2" ]]; then
        echo ", 连续 ${MAX_MISSES} 次失败，禁用中..."
        if channel_update "$eid" "$ename" "$etype" "$ebase_url" "" "ollama" "" "2"; then
          disabled=$((disabled + 1))
          changed=$((changed + 1))
        fi
      else
        echo ""
      fi
    fi

    echo

  done <<< "$(echo "$channels" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('data', {}).get('items', [])
for item in items:
    print(json.dumps(item))
" 2>/dev/null)"

  # 7. 保存 misses 文件
  save_misses "$misses_json"

  if [[ $changed -gt 0 ]]; then
    ok "健康检查完成：${enabled} 个恢复，${disabled} 个禁用，共 ${changed} 个变更"
  else
    ok "健康检查完成：所有 channel 状态正常，无变更"
  fi
}

# ============ Main ============

case "${1:-}" in
  --help|-h)
    echo "用法: $(basename "$0")"
    echo
    echo "探测所有 MIXAPI channel 后端健康状态，自动禁用/启用 channel。"
    ;;
  *)
    do_health_check
    ;;
esac
