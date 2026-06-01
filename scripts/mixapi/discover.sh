#!/usr/bin/env bash
#
# discover.sh — 扫描 tailscale 网络中的 LLM 推理服务
#
# 用法:
#   ./discover.sh --full              # 全量扫描（发现所有节点+端口+模型）
#   ./discover.sh --cron              # 自适应增量扫描（按 scan_interval）
#   ./discover.sh --cron --force      # cron 模式下强制全量
#
# 输出: ~/.mixapi/services.json（JSON 格式）
# 返回值: 0 = 有变更, 1 = 无变更（cron 模式用于判断是否需要调用 channel.sh）

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==== Library Sources ====
source "${SCRIPT_DIR}/lib/lib-format.sh"
source "${SCRIPT_DIR}/lib/lib-tailnet.sh"
source "${SCRIPT_DIR}/lib/lib-mixapi.sh"

# ==== Cleanup Infrastructure ====
_CLEANUP_DIRS=()

# Description: Remove all registered temporary directories on script exit.
#              Called automatically by the EXIT trap.
# Output: none (side-effect only)
_cleanup() {
  local dir
  for dir in "${_CLEANUP_DIRS[@]}"; do
    rm -rf -- "$dir" || true
  done
}
trap _cleanup EXIT

# ==== Constants ====
# MIXAPI_DATA_DIR and SERVICES_FILE are defined in lib-mixapi.sh

# Probe definitions: PORT:TYPE:API_PATH:MODEL_KEY
# MODEL_KEY: field name for models in JSON response
#   "field_name" — extract field from JSON objects
#   "id"         — data[].id format (vLLM/OpenAI)
#   "null"       — no model list endpoint
readonly PROBES=(
  "11434:ollama:/api/tags:name"
  "8000:vllm:/v1/models:id"
  "8001:vllm:/v1/models:id"
  "8002:vllm:/v1/models:id"
  "8003:vllm:/v1/models:id"
  "8004:vllm:/v1/models:id"
  "8005:vllm:/v1/models:id"
  "80:tgi:/info:model_id"
  "8080:tgi-alt:/info:model_id"
  "8188:comfyui:/system_stats:null"
  "3000:open-webui:/api/models:id"
  "5000:text-gen:/v1/models:id"
)

readonly SKIP_NODES="aliyun-basic cn-derp lizhi desktop"
readonly INTERVAL_ACTIVE=300
readonly INTERVAL_INACTIVE=1800
readonly ACTIVE_MISS_THRESHOLD=3
# 每轮 cron 至少扫描 N 个服务（防止全部 inactive 时 zero-probe 窗口）
readonly MIN_SCAN_PER_CYCLE=2

# ============ State Management ============

# Description: Read services.json, return empty JSON if not exists
# Output: JSON content on stdout
read_services() {
  if [[ -f "$SERVICES_FILE" ]]; then
    cat "$SERVICES_FILE"
  else
    echo '{"updated_at":"","services":[]}'
  fi
}

# ============ Probe Engine ============

# Description: Extract models list from API response JSON.
# Arguments: $1 — API response body, $2 — model_key, $3 — service type
# Output: JSON array of model names on stdout
extract_models() {
  local resp="$1"
  local model_key="$2"
  local svc="$3"

  if [[ "$model_key" == "null" ]]; then
    echo '["(running)"]'
    return
  fi

  python3 -c "
import json, os, sys

resp = json.loads(sys.stdin.read())
model_key = '${model_key}'
models = []

if model_key == 'id':
    # vLLM/OpenAI: {'data': [{'id': 'model1', ...}]}
    for item in resp.get('data', []):
        if isinstance(item, dict) and 'id' in item:
            models.append(os.path.basename(item['id']))
else:
    # Try common response structures
    for key in ['models', 'data', 'model_info', 'system_stats']:
        if key not in resp:
            continue
        val = resp[key]
        if isinstance(val, list):
            for item in val:
                if isinstance(item, dict) and model_key in item:
                    models.append(item[model_key])
            if models:
                break
        elif isinstance(val, dict):
            if model_key in val:
                models.append(str(val[model_key]))
                break

    # Top-level fallback
    if not models and model_key in resp:
        models.append(str(resp[model_key]))

print(json.dumps(models, ensure_ascii=False))
" <<< "$resp" 2>/dev/null || echo "[]"
}

# Description: Probe a single service on a single port.
# Arguments: $1 — ip, $2 — node_name, $3 — port, $4 — svc_name, $5 — api_path, $6 — model_key
# Output: JSON object for the service on stdout, or empty string if port unreachable
probe_service() {
  local ip="$1"
  local name="$2"
  local port="$3"
  local svc="$4"
  local api_path="$5"
  local model_key="$6"

  if ! check_port "$ip" "$port"; then
    echo
    return
  fi

  if [[ -z "$api_path" ]]; then
    # Quick scan mode — only port check
    python3 -c "
import json
print(json.dumps({'node': '$name', 'ip': '$ip', 'port': $port, 'service': '$svc', 'models': [], 'status': 'active'}, ensure_ascii=False))
"
    return
  fi

  local resp
  resp=$(http_get "$ip" "$port" "$api_path" 5 || true)

  if [[ -z "$resp" ]]; then
    # Port open but API unresponsive - check /health for vLLM
    if [[ "$svc" == "vllm" ]]; then
      local health_resp
      health_resp=$(http_get "$ip" "$port" "/health" 3 || true)
      if [[ -z "$health_resp" ]] || [[ "$health_resp" != *"healthy"* ]] && [[ "$health_resp" != "OK" ]]; then
        echo
        return
      fi
    fi
    python3 -c "
import json
print(json.dumps({'node': '$name', 'ip': '$ip', 'port': $port, 'service': '$svc', 'models': [], 'status': 'active'}, ensure_ascii=False))
"
    return
  fi

  local models
  models=$(extract_models "$resp" "$model_key" "$svc")

  # For vLLM: if /v1/models returned empty, also probe /health
  if [[ "$svc" == "vllm" ]]; then
    local models_json
    models_json=$(echo "$models" | python3 -c "import json,sys; d=json.load(sys.stdin); print('empty' if len(d)==0 else 'ok')" 2>/dev/null)
    if [[ "$models_json" == "empty" ]]; then
      local health_resp
      health_resp=$(http_get "$ip" "$port" "/health" 3 || true)
      if [[ -z "$health_resp" ]] || [[ "$health_resp" != *"healthy"* ]] && [[ "$health_resp" != "OK" ]]; then
        echo
        return
      fi
    fi
  fi

  python3 -c "
import json, sys
models = json.load(sys.stdin)
print(json.dumps({'node': '$name', 'ip': '$ip', 'port': $port, 'service': '$svc', 'models': models, 'status': 'active'}, ensure_ascii=False))
" <<< "$models"
}

# Description: Scan all probes on a single node.
# Arguments: $1 — ip, $2 — node_name, $3 — mode ("full" or "quick")
# Output: JSON lines (one per service found) on stdout
scan_node_probes() {
  local ip="$1"
  local name="$2"
  local mode="${3:-full}"

  local probe
  for probe in "${PROBES[@]}"; do
    IFS=: read -r port svc api_path model_key <<< "$probe"

    if [[ "$mode" == "quick" ]]; then
      if check_port "$ip" "$port"; then
        python3 -c "
import json
print(json.dumps({'node': '$name', 'ip': '$ip', 'port': $port, 'service': '$svc', 'status': 'active'}, ensure_ascii=False))
"
      fi
    else
      local result
      result=$(probe_service "$ip" "$name" "$port" "$svc" "$api_path" "$model_key")
      if [[ -n "$result" ]]; then
        echo "$result"
      fi
    fi
  done
}

# ============ Full Scan ============

# Description: Full scan — discover all tailscale nodes, probe all ports,
#              collect models, and write services.json atomically.
# Output: services.json updated, scan summary to stderr
# Exit: 0 on success, non-zero on fatal errors
do_full_scan() {
  section "LLM Service Discovery — Full Scan"

  info "[1/3] 获取在线节点列表..."
  local nodes
  nodes=$(ts_nodes)
  if [[ -z "$nodes" ]]; then
    die "无法获取 tailscale 节点列表，容器是否在运行？"
  fi

  local targets=()
  while IFS=' ' read -r ip name rest; do
    [[ -z "$ip" ]] && continue
    local skip=false
    local s
    for s in $SKIP_NODES; do
      [[ "$name" == "$s" ]] && { skip=true; break; }
    done
    $skip && continue
    targets+=("$ip $name")
  done <<< "$nodes"

  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "没有需要扫描的节点，生成空配置"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_services_file "{\"updated_at\":\"$now\",\"services\":[]}"
    ok "已生成空的 services.json"
    exit 0
  fi

  info "发现 $(echo "$nodes" | wc -l) 个在线节点，跳过 ${SKIP_NODES}"
  ok "将扫描 ${#targets[@]} 个潜在 LLM 节点"
  echo

  info "[2/3] 扫描端口和服务..."
  local tmpdir
  tmpdir=$(mktemp -d)
  _CLEANUP_DIRS+=("$tmpdir")

  local running=0
  local max_parallel=${PARALLEL:-6}
  local target
  for target in "${targets[@]}"; do
    local ip
    ip=$(echo "$target" | awk '{print $1}')
    local name
    name=$(echo "$target" | awk '{print $2}')

    (
      scan_node_probes "$ip" "$name" "full" > "${tmpdir}/res_${ip//./_}"
    ) &
    running=$((running + 1))

    if [[ $running -ge $max_parallel ]]; then
      wait -n 2>/dev/null || true
      running=$((running - 1))
    fi
  done
  wait

  local all_services=()
  local f
  for f in "${tmpdir}"/*; do
    [[ ! -f "$f" ]] && continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && all_services+=("$line")
    done < "$f"
  done

  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local output_json
  output_json=$(python3 -c "
import json, sys

now = '${now_ts}'
lines = [l for l in sys.stdin.read().strip().split('\n') if l.strip()]
services = []
seen = set()

for line in lines:
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        continue
    key = (entry.get('ip',''), entry.get('port',0))
    if key in seen:
        continue
    seen.add(key)

    services.append({
        'node': entry.get('node',''),
        'ip': entry.get('ip',''),
        'port': entry.get('port',0),
        'service': entry.get('service',''),
        'models': entry.get('models', []),
        'models_updated_at': now,
        'last_scan': now,
        'last_seen': now,
        'miss_count': 0,
        'status': 'active'
    })

# Build active_serve_port: all freshly scanned services are active
active_serve_port = sorted([f\"{s['node']}:{s['port']}\" for s in services])

print(json.dumps({
    'updated_at': now,
    'active_serve_port': active_serve_port,
    'services': services
}, indent=2, ensure_ascii=False))
" <<< "$(printf '%s\n' "${all_services[@]}")")

  write_services_file "$output_json"
  ok "扫描完成，发现 ${#all_services[@]} 个服务"
  info "[3/3] 结果已保存: ${SERVICES_FILE}"
  echo
  echo "$output_json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for s in data['services']:
    models = ', '.join(s.get('models', []))
    print(f\"  {s['node']}:{s['port']} ({s['service']})  ->  {models}\")
" 2>/dev/null || true
}

# ============ Cron Scan ============

# Description: Incremental scan — only check due services based on scan_interval,
#              detect new services on known nodes, merge results, and rebuild
#              active_serve_port.
# Arguments: $1 — force_full ("true" to bypass incremental logic)
# Returns: 0 = services changed, 1 = unchanged
do_cron_scan() {
  local force_full="${1:-false}"

  section "LLM Service Discovery — Incremental Scan"

  local json_data
  json_data=$(read_services)

  local has_services
  has_services=$(echo "$json_data" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
svc = data.get('services', [])
print('yes' if svc else 'no')
" 2>/dev/null)

  if [[ "$has_services" != "yes" || "$force_full" == "true" ]]; then
    warn "services.json 为空或强制全量，执行全量扫描"
    do_full_scan
    return 0
  fi

  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local now_epoch
  now_epoch=$(date +%s)
  local tmpdir
  tmpdir=$(mktemp -d)
  _CLEANUP_DIRS+=("$tmpdir")

  # Find due services using active_serve_port + minimum per-cycle guarantee
  local due_list
  due_list=$(python3 << PYEOF
import json, time, sys, os

now_epoch = ${now_epoch}
data = json.loads("""${json_data}""")
services = data.get('services', [])
active_set = set(data.get('active_serve_port', []))

# Migrate: if services.json has no active_serve_port, derive from active services
if not active_set:
    for s in services:
        if s.get('status') == 'active':
            active_set.add(f"{s.get('node','')}:{s.get('port',0)}")

# Pass 1: due list by interval
due = []
for s in services:
    last_scan = s.get('last_scan', '')
    key = f"{s.get('node','')}:{s.get('port',0)}"
    # IN active_serve_port → 5min, NOT IN → 30min
    interval = ${INTERVAL_ACTIVE} if key in active_set else ${INTERVAL_INACTIVE}
    try:
        last_epoch = int(time.mktime(time.strptime(last_scan, '%Y-%m-%dT%H:%M:%SZ')))
    except Exception:
        last_epoch = 0
    if (now_epoch - last_epoch) >= interval:
        due.append(s)

# Pass 2: fallback — if fewer than MIN_SCAN_PER_CYCLE are due, scan the oldest
#          unprobed services to guarantee continuous probing
min_scan = ${MIN_SCAN_PER_CYCLE}
if len(due) < min_scan:
    # Build set of already-selected keys
    selected_keys = set()
    for s in due:
        selected_keys.add((s.get('ip',''), s.get('port',0)))
    # Sort remaining services by last_scan (oldest first), pick fillers
    remaining = [s for s in services
                 if (s.get('ip',''), s.get('port',0)) not in selected_keys]
    remaining.sort(key=lambda s: s.get('last_scan', ''))
    fillers = remaining[:min_scan - len(due)]
    due.extend(fillers)

for s in due:
    print(f"{s['ip']}:{s['port']}:{s.get('node','')}:{s.get('service','')}")
PYEOF
)

  # Scan due services
  local scan_count=0
  local pids=()

  if [[ -z "$due_list" ]]; then
    ok "没有待扫描的服务（按扫描间隔跳过）"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      IFS=: read -r ip port name svc <<< "$line"

      (
        local probe_entry api_path model_key
        # Look up probe definition by port to get api_path and model_key
        probe_entry=$(printf '%s\n' "${PROBES[@]}" | grep "^${port}:")
        if [[ -n "$probe_entry" ]]; then
          IFS=: read -r _ _ api_path model_key <<< "$probe_entry"
        else
          api_path=""
          model_key=""
        fi
        local result
        result=$(probe_service "$ip" "$name" "$port" "$svc" "$api_path" "$model_key")
        if [[ -n "$result" ]]; then
          echo "$result" > "${tmpdir}/res_${ip//./_}_${port}"
        else
          echo "MISS|${ip}|${port}|${name}" > "${tmpdir}/res_${ip//./_}_${port}"
        fi
      ) &
      pids+=($!)
      scan_count=$((scan_count + 1))
    done <<< "$due_list"
    ok "正在扫描 ${scan_count} 个到期的服务..."
    wait
  fi

  # New service detection: for each due node, quick-check other ports
  local due_nodes
  due_nodes=$(python3 << PYEOF
import json, sys, time

data = json.loads("""${json_data}""")
services = data.get('services', [])
now_epoch = ${now_epoch}
active_set = set(data.get('active_serve_port', []))

# Migrate: if no active_serve_port, derive from active services
if not active_set:
    for s in services:
        if s.get('status') == 'active':
            active_set.add(f"{s.get('node','')}:{s.get('port',0)}")

# Pass 1: due IPs by interval
due_ips = []
seen_ips = set()
for s in services:
    last_scan = s.get('last_scan', '')
    key = f"{s.get('node','')}:{s.get('port',0)}"
    interval = ${INTERVAL_ACTIVE} if key in active_set else ${INTERVAL_INACTIVE}
    try:
        last_epoch = int(time.mktime(time.strptime(last_scan, '%Y-%m-%dT%H:%M:%SZ')))
    except Exception:
        last_epoch = 0
    ip = s.get('ip', '')
    if ip not in seen_ips and (now_epoch - last_epoch) >= interval:
        due_ips.append(ip)
        seen_ips.add(ip)

# Pass 2: fallback — if fewer than MIN_SCAN_PER_CYCLE nodes, scan oldest
min_scan = ${MIN_SCAN_PER_CYCLE}
if len(due_ips) < min_scan:
    remaining = [s for s in services if s.get('ip','') not in seen_ips]
    remaining.sort(key=lambda s: s.get('last_scan', ''))
    for s in remaining[:min_scan - len(due_ips)]:
        ip = s.get('ip','')
        if ip not in seen_ips:
            due_ips.append(ip)
            seen_ips.add(ip)

for ip in due_ips:
    print(ip)
PYEOF
)

  while IFS= read -r node_ip; do
    [[ -z "$node_ip" ]] && continue

    local existing_ports
    existing_ports=$(python3 << PYEOF
import json, sys
data = json.loads("""${json_data}""")
ports = [str(s['port']) for s in data.get('services', []) if s.get('ip') == '${node_ip}']
print(' '.join(ports))
PYEOF
)

    local probe
    for probe in "${PROBES[@]}"; do
      IFS=: read -r port svc api_path model_key <<< "$probe"
      if echo "$existing_ports" | grep -qw "$port"; then
        continue
      fi

      if check_port "$node_ip" "$port"; then
        local node_name
        node_name=$(python3 << PYEOF
import json, sys
data = json.loads("""${json_data}""")
for s in data.get('services', []):
    if s.get('ip') == '${node_ip}':
        print(s.get('node', 'unknown'))
        sys.exit(0)
print('unknown')
PYEOF
)
        info "发现新服务: ${node_ip}:${port} (${svc})"
        (
          probe_service "$node_ip" "$node_name" "$port" "$svc" "$api_path" "$model_key" \
            > "${tmpdir}/new_${node_ip//./_}_${port}"
        ) &
        pids+=($!)
      fi
    done
  done <<< "$due_nodes"

  # Wait for new service detection
  wait

  # Merge results + rebuild active_serve_port
  local merge_result
  merge_result=$(python3 << PYEOF
import json, os, time, sys

now_ts = '${now_ts}'
now_epoch = ${now_epoch}
tmpdir = '${tmpdir}'

data = json.loads("""${json_data}""")
services = data.get('services', [])
changed = False
# Process result files
for fname in os.listdir(tmpdir):
    fpath = os.path.join(tmpdir, fname)
    with open(fpath) as f:
        content = f.read().strip()
    if not content:
        continue

    if fname.startswith('res_'):
        if content.startswith('MISS|'):
            parts = content.split('|')
            ip = parts[1]
            port = int(parts[2])
            for s in services:
                if s.get('ip') == ip and s.get('port') == port:
                    s['miss_count'] = s.get('miss_count', 0) + 1
                    s['last_scan'] = now_ts
                    if s['miss_count'] >= ${ACTIVE_MISS_THRESHOLD} and s.get('status') == 'active':
                        s['status'] = 'inactive'
                        changed = True
        else:
            try:
                entry = json.loads(content)
            except json.JSONDecodeError:
                continue
            ip = entry.get('ip', '')
            port = entry.get('port', 0)
            models = entry.get('models', [])
            for s in services:
                if s.get('ip') == ip and s.get('port') == port:
                    old_models = set(s.get('models', []))
                    new_models = set(models)
                    if old_models != new_models:
                        changed = True
                    s['models'] = models
                    s['models_updated_at'] = now_ts
                    s['last_scan'] = now_ts
                    s['last_seen'] = now_ts
                    s['miss_count'] = 0
                    if s.get('status') != 'active':
                        s['status'] = 'active'
                        changed = True
                    break
    elif fname.startswith('new_'):
        try:
            entry = json.loads(content)
        except json.JSONDecodeError:
            continue
        ip = entry.get('ip', '')
        port = entry.get('port', 0)
        # Dedup
        dup = False
        for s in services:
            if s.get('ip') == ip and s.get('port') == port:
                dup = True
                break
        if dup:
            continue
        services.append({
            'node': entry.get('node', ''),
            'ip': ip,
            'port': port,
            'service': entry.get('service', ''),
            'models': entry.get('models', []),
            'models_updated_at': now_ts,
            'last_scan': now_ts,
            'last_seen': now_ts,
            'miss_count': 0,
            'status': 'active'
        })
        changed = True

# Rebuild active_serve_port: all status=active services are in the active set
# status='inactive' services (3+ consecutive misses) are automatically excluded
active_serve_port = sorted([
    f"{s['node']}:{s['port']}"
    for s in services
    if s.get('status') == 'active'
])

result = {
    'updated_at': now_ts,
    'active_serve_port': active_serve_port,
    'services': services
}
print(json.dumps(result, indent=2, ensure_ascii=False))
sys.exit(0 if changed else 1)
PYEOF
)

  local exit_code=$?

  if [[ -z "$merge_result" ]]; then
    die "合并结果失败"
  fi

  write_services_file "$merge_result"

  [[ $scan_count -gt 0 ]] && ok "本次扫描: ${scan_count} 个服务"

  echo
  echo "$merge_result" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
services = data.get('services', [])
active = [s for s in services if s.get('status') == 'active']
inactive_count = len([s for s in services if s.get('status') != 'active'])
print(f'  活跃: {len(active)} 个服务  |  离线: {inactive_count} 个')
for s in active[:5]:
    models = ', '.join(s.get('models', [])[:3])
    tail = '...' if len(s.get('models', [])) > 3 else ''
    print(f'    {s[\"node\"]}:{s[\"port\"]} ({s[\"service\"]})  ->  {models}{tail}')
if len(active) > 5:
    print(f'    ... 还有 {len(active)-5} 个')
" 2>/dev/null || true

  return $exit_code
}

# ============ Main Entry ============

# Description: Parse CLI arguments and dispatch to full or cron scan mode.
# Arguments: $@ — CLI args (--full, --cron, --force, -h, --help)
# Exit: 0 on success/changes, 1 on no changes (cron mode), non-zero on error
main() {
  local mode="" force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full) mode="full"; shift ;;
      --cron) mode="cron"; shift ;;
      --force) force=true; shift ;;
      -h|--help)
        echo "用法: $(basename "$0") [选项]"
        echo
        echo "  --full          全量扫描"
        echo "  --cron          增量扫描（按 scan_interval）"
        echo "  --cron --force  强制全量扫描"
        exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  [[ -z "$mode" ]] && mode="full"

  case "$mode" in
    full) do_full_scan ;;
    cron) do_cron_scan "$force" ;;
  esac
}

main "$@"
