#!/usr/bin/env bash
#
# channel.sh — 将 services.json 同步到 MIXAPI 渠道
#
# 读取 services.json 中的活跃服务，与 MIXAPI 现有渠道做 diff，
# 自动添加新渠道、更新模型列表、删除已下线的渠道。
#
# 用法:
#   ./channel.sh                          # 同步所有服务到 MIXAPI
#   ./channel.sh --dry-run                # 只显示 diff，不执行
#
# 依赖:
#   - ~/.mixapi/.credentials（sync-worker 凭证）
#   - services.json（由 discover.sh 生成）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"
source "${SCRIPT_DIR}/lib/lib-mixapi.sh"

# ==== Constants ====
readonly SYNC_TAG="auto-sync"
DRY_RUN=false

# ==== Argument Parsing ====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "用法: $(basename "$0") [选项]"
      echo
      echo "  --dry-run  只显示变更预览，不实际执行"
      exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# ==== Channel Config Builder ====

# Description: Build MIXAPI channel configs from services.json
# Output: JSON array of {type, name, key, base_url, models, group, tag, status}
build_channel_configs() {
  if [[ ! -f "$SERVICES_FILE" ]]; then
    ensure_services_json
  fi

  python3 -c "
import json, os

with open('${SERVICES_FILE}') as f:
    data = json.load(f)

services = data.get('services', [])
configs = []

for s in services:
    if s.get('status') != 'active':
        continue
    node = s.get('node', 'unknown')
    ip = s.get('ip', '')
    port = s.get('port', 0)
    svc_type = s.get('service', '')
    models = s.get('models', [])

    # Filter out '(running)' placeholder, extract basename
    real_models = [os.path.basename(m) if '/' in m else m for m in models if m != '(running)']

    if not real_models:
        continue

    # Determine channel type
    ctype = 4 if svc_type == 'ollama' else 1
    ckey = 'ollama' if ctype == 4 else 'sk-placeholder'
    ip_safe = ip.replace('.', '-')
    cname = f'{svc_type}-{ip_safe}:{port}'
    base_url = f'http://{ip}:{port}'

    configs.append({
        'type': ctype,
        'name': cname,
        'key': ckey,
        'base_url': base_url,
        'models': ','.join(real_models),
        'group': 'default',
        'tag': '${SYNC_TAG}',
        'status': 1
    })

print(json.dumps(configs, indent=2, ensure_ascii=False))
"
}

# ============ Diff Engine ============

# Description: Compute diff between desired configs and existing channels
# Arguments: $1 — desired configs JSON, $2 — existing channels JSON
# Output: JSON with add/update/delete arrays
compute_diff() {
  local desired_json="$1"
  local existing_json="$2"

  python3 - "$desired_json" "$existing_json" "${SYNC_TAG}" << 'PYEOF'
import json, sys

desired = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else []
existing = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else []
sync_tag = sys.argv[3] if len(sys.argv) > 3 else 'auto-sync'

to_add = []
to_update = []
to_delete = []

# Index existing channels by (type, base_url) for matching
existing_map = {}
for ch in existing:
    tag = ch.get('tag') or ''
    if tag != sync_tag:
        continue
    key = (ch.get('type', 0), ch.get('base_url', ''))
    existing_map[key] = ch

# Check desired against existing
seen_keys = set()
for cfg in desired:
    key = (cfg['type'], cfg['base_url'])
    seen_keys.add(key)
    if key in existing_map:
        # Existing channel — check if models changed
        old_models = existing_map[key].get('models', '')
        new_models = cfg['models']
        if old_models != new_models:
            to_update.append({
                'id': existing_map[key]['id'],
                'type': cfg['type'],
                'name': cfg['name'],
                'base_url': cfg['base_url'],
                'models': cfg['models'],
                'old_models': old_models,
                'group': cfg['group'],
                'tag': cfg['tag'],
                'status': cfg['status']
            })
    else:
        # New channel
        to_add.append(cfg)

# Check for channels to remove
for key, ch in existing_map.items():
    if key not in seen_keys:
        to_delete.append({
            'id': ch['id'],
            'name': ch.get('name', ''),
            'base_url': ch.get('base_url', ''),
            'models': ch.get('models', '')
        })

print(json.dumps({
    'add': to_add,
    'update': to_update,
    'delete': to_delete
}, indent=2, ensure_ascii=False))
PYEOF

  return 0
}

# ============ Sync Execution ============

# Description: Execute the sync operations against MIXAPI API
# Arguments: $1 — diff JSON
do_sync() {
  local diff="$1"

  local add_count update_count delete_count
  add_count=$(echo "$diff" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['add']))" 2>/dev/null || echo "0")
  update_count=$(echo "$diff" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['update']))" 2>/dev/null || echo "0")
  delete_count=$(echo "$diff" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['delete']))" 2>/dev/null || echo "0")

  if [[ "$add_count" -eq 0 && "$update_count" -eq 0 && "$delete_count" -eq 0 ]]; then
    ok "一切已同步，无变更"
    return 0
  fi

  # Login
  info "登录 MIXAPI..."
  local creds
  creds=$(load_credentials_raw)
  local worker_pass
  worker_pass=$(extract_credential "$creds" "sync-worker")
  if [[ -z "$worker_pass" ]]; then
    die "无法读取 sync-worker 凭证"
  fi
  mixapi_login "sync-worker" "$worker_pass" || die "登录失败"
  ok "登录成功"
  echo

  # --- Delete removed services ---
  if [[ "$delete_count" -gt 0 ]]; then
    section "删除已下线的渠道 (${delete_count})"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      local id
      local name
      id=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      name=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")

      if [[ "$DRY_RUN" == true ]]; then
        warn "[DRY-RUN] 将删除渠道: ${name} (id=${id})"
      else
        if channel_delete "$id"; then
          ok "已删除: ${name}"
        else
          warn "删除失败: ${name}"
        fi
      fi
    done <<< "$(echo "$diff" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['delete']:
    print(json.dumps(item))
")"
    echo
  fi

  # --- Add new services ---
  if [[ "$add_count" -gt 0 ]]; then
    section "添加新渠道 (${add_count})"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      local name
      name=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")

      if [[ "$DRY_RUN" == true ]]; then
        warn "[DRY-RUN] 将添加渠道: ${name}"
        echo "$item" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))" | sed 's/^/    /'
      else
        if channel_add_json "$item"; then
          ok "已添加: ${name}"
        else
          warn "添加失败: ${name}"
        fi
      fi
    done <<< "$(echo "$diff" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['add']:
    print(json.dumps(item))
")"
    echo
  fi

  # --- Update changed services ---
  if [[ "$update_count" -gt 0 ]]; then
    section "更新渠道配置 (${update_count})"

    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      local id name old_models new_models
      id=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      name=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
      old_models=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin).get('old_models',''))")
      new_models=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['models'])")

      if [[ "$DRY_RUN" == true ]]; then
        warn "[DRY-RUN] 将更新渠道: ${name}"
        echo "    旧模型: ${old_models}"
        echo "    新模型: ${new_models}"
      else
        if channel_update_json "$item"; then
          ok "已更新: ${name}  (${old_models} → ${new_models})"
        else
          warn "更新失败: ${name}"
        fi
      fi
    done <<< "$(echo "$diff" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['update']:
    print(json.dumps(item))
")"
    echo
  fi

  # Summary
  section "同步完成"
  [[ "$add_count" -gt 0 ]]    && ok "新增: ${add_count}"
  [[ "$update_count" -gt 0 ]] && ok "更新: ${update_count}"
  [[ "$delete_count" -gt 0 ]] && ok "删除: ${delete_count}"
  [[ "$DRY_RUN" == true ]]    && warn "这是 DRY-RUN，未实际执行"
}

# ============ Main ============
main() {
  section "Channel Sync — services.json → MIXAPI"

  # Build desired configs from services.json
  info "读取 services.json..."
  local desired
  desired=$(build_channel_configs)

  local desired_count
  desired_count=$(echo "$desired" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  info "services.json 中包含 ${desired_count} 个有效服务"
  echo

  # Get existing channels from MIXAPI
  info "获取 MIXAPI 现有渠道列表..."

  local creds
  creds=$(load_credentials_raw)
  local worker_pass
  worker_pass=$(extract_credential "$creds" "sync-worker")
  if [[ -z "$worker_pass" ]]; then
    die "无法读取 sync-worker 凭证"
  fi
  mixapi_login "sync-worker" "$worker_pass" || die "登录失败"

  local existing_raw
  existing_raw=$(channel_list)
  if [[ -z "$existing_raw" ]]; then
    warn "无法获取渠道列表或没有渠道"
    existing="[]"
  else
    # 从响应中提取 items 数组
    existing=$(echo "$existing_raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('data', {}).get('items', [])
print(json.dumps(items, ensure_ascii=False))
" 2>/dev/null || echo "[]")
  fi

  local existing_count
  existing_count=$(echo "$existing" | python3 -c "
import json, sys
items = json.load(sys.stdin)
tagged = [c for c in items if c.get('tag') == '${SYNC_TAG}']
print(len(tagged))
" 2>/dev/null || echo "0")
  info "MIXAPI 中 tag='${SYNC_TAG}' 的渠道: ${existing_count}"
  echo

  # Compute diff — passes JSON strings as arguments (no fragile DLM delimiter)
  info "计算变更..."
  local diff
  diff=$(compute_diff "$desired" "$existing")
  local change_count
  change_count=$(echo "$diff" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(len(data['add']) + len(data['update']) + len(data['delete']))
" 2>/dev/null || echo "0")

  if [[ "$change_count" -eq 0 ]]; then
    ok "一切已同步，无变更"
    exit 0
  fi

  # Preview
  echo
  echo "$diff" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['add']:
    print(f'  {chr(0x2795)} 新增: {item[\"name\"]}  ({item[\"models\"]})')
for item in data['update']:
    print(f'  {chr(0x1f504)} 更新: {item[\"name\"]}  ({item[\"old_models\"]} -> {item[\"models\"]})')
for item in data['delete']:
    print(f'  {chr(0x2796)} 删除: {item[\"name\"]}  ({item[\"base_url\"]})')
" 2>/dev/null || true
  echo

  # Execute
  if [[ "$DRY_RUN" == true ]]; then
    warn "DRY-RUN 模式，不执行变更"
    exit 0
  fi

  do_sync "$diff"
}

main "$@"
