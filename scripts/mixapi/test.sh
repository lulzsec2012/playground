#!/usr/bin/env bash
#
# test.sh — 测试 LLM 模型推理可用性
#
# 读取 services.json，交互式或命令行选择模型，执行推理测试后输出汇总报告。
#
# 用法:
#   ./test.sh                          # 交互式选择
#   ./test.sh --all                    # 测试所有活跃服务
#   ./test.sh --models gemma4:26b      # 指定模型（逗号分隔）
#   ./test.sh --node duser-...         # 指定节点
#
# 依赖:
#   - services.json（由 discover.sh 生成）
#   - tailscale 容器（docker exec）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"
source "${SCRIPT_DIR}/lib/lib-tailnet.sh"
source "${SCRIPT_DIR}/lib/lib-mixapi.sh"

# ==== Constants ====
# SERVICES_FILE 来自 lib/lib-mixapi.sh
readonly MAX_TOKENS="${MAX_TOKENS:-100}"
readonly TEST_TIMEOUT="${TIMEOUT:-120}"

# ============ Data Loading ============

# Description: Load active services from services.json
# Output: JSON array of active services
load_services() {
  if [[ ! -f "$SERVICES_FILE" ]]; then
    ensure_services_json
  fi
  python3 -c "
import json, sys
with open('${SERVICES_FILE}') as f:
    data = json.load(f)
services = data.get('services', [])
active = [s for s in services if s.get('status') == 'active']
print(json.dumps(active, indent=2, ensure_ascii=False))
" 2>/dev/null || die "无法读取 ${SERVICES_FILE}"
}

# ============ Model Testing ============

# Description: Pick a prompt for a model based on its name
auto_prompt() {
  local model="$1"
  case "$model" in
    *code*)   echo "Write a Python function to check if a number is prime." ;;
    *r1:*|*reason*)   echo "What is 23 * 47? Show your reasoning step by step." ;;
    *embed*)          echo "" ;;
    *)                echo "Hello! In one sentence, what is artificial intelligence?" ;;
  esac
}

# Description: Test a single model via Ollama API
# Arguments: $1 — node_ip, $2 — port, $3 — model_name
# Returns: JSON result with status and metrics
test_one_model() {
  local ip="$1"
  local port="$2"
  local model="$3"

  local prompt
  prompt=$(auto_prompt "$model")

  if [[ -z "$prompt" ]]; then
    echo "{\"model\":\"${model}\",\"status\":\"skip\",\"reason\":\"embedding model\"}"
    return
  fi

  # Build payload via heredoc to avoid JSON quoting issues
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({'model': '${model}', 'prompt': '${prompt}', 'stream': False, 'options': {'num_predict': ${MAX_TOKENS}}}))
")

  # Create temp file for payload
  local payload_file
  payload_file=$(mktemp)
  echo "$payload" > "$payload_file"
  trap 'rm -f "${payload_file}"' RETURN

  local start end elapsed_ms elapsed_sec
  start=$(date +%s%N)

  local http_code
  http_code=$(http_post "$ip" "$port" "/api/generate" "application/json" "$payload_file" "$TEST_TIMEOUT" || true)
  local exit_code=$?

  end=$(date +%s%N)
  elapsed_ms=$(( (end - start) / 1000000 ))
  elapsed_sec=$(awk "BEGIN {printf \"%.2f\", ${elapsed_ms} / 1000}")

  if [[ $exit_code -ne 0 || -z "$http_code" ]]; then
    echo "{\"model\":\"${model}\",\"status\":\"fail\",\"reason\":\"timeout or connection error\",\"elapsed_sec\":${elapsed_sec}}"
    return
  fi

  # Parse response via temp file (avoid bash string interpolation issues)
  local resp_file
  resp_file=$(mktemp)
  echo "$http_code" > "$resp_file"
  trap 'rm -f "${payload_file}" "${resp_file}"' RETURN

  local parse_result
  parse_result=$(python3 <<PYEOF
import json
with open('${resp_file}') as f:
    data = json.load(f)
response_text = data.get('response', '')
eval_count = data.get('eval_count', 0)
eval_duration = data.get('eval_duration', 0)
total_duration = data.get('total_duration', 0)
load_duration = data.get('load_duration', 0)
tokens_per_sec = 'N/A'
if eval_count and eval_duration and eval_duration > 0:
    tps = eval_count / (eval_duration / 1000000000.0)
    tokens_per_sec = round(tps, 1)
is_cold = 'no'
if load_duration and load_duration > 5000000000:
    is_cold = 'yes'
print(json.dumps({
    'model': '${model}',
    'status': 'ok',
    'response_preview': response_text[:200],
    'eval_count': eval_count,
    'tokens_per_sec': str(tokens_per_sec),
    'elapsed_sec': ${elapsed_sec},
    'total_duration_sec': round(total_duration / 1000000000.0, 2) if total_duration else 0,
    'load_duration_sec': round(load_duration / 1000000000.0, 2) if load_duration else 0,
    'cold_start': is_cold
}, ensure_ascii=False))
PYEOF
  ) 2>/dev/null || true

  if [[ -z "$parse_result" ]]; then
    echo "{\"model\":\"${model}\",\"status\":\"fail\",\"reason\":\"parse error\",\"elapsed_sec\":${elapsed_sec}}"
  else
    echo "$parse_result"
  fi
}

# ============ Interactive Selection ============

# Description: Show hierarchical multi-select menu for services/models
# Output: JSON array of {ip, port, model} objects (stdout only)
#         Display text goes to stderr so $() capture works correctly
interactive_select() {
  local services_json
  services_json=$(load_services)

  if [[ -z "$services_json" || "$services_json" == "[]" ]]; then
    die "没有活跃的服务可测试"
  fi

  # Display tree menu (all output to stderr)
  section "Available LLM Services" 1>&2
  echo "" 1>&2

  echo "$services_json" | python3 -c '
import json, sys

services = json.loads(sys.stdin.read())
print("  [0] All: 测试所有模型", file=sys.stderr)
print("", file=sys.stderr)

for si, s in enumerate(services, 1):
    display = f"{s.get("service", "?")}@{s.get("node", "?")}"
    models = [m for m in s.get("models", []) if m != "(running)"]
    if not models:
        continue
    print(f"  [{si}] {display}", file=sys.stderr)
    for mi, m in enumerate(models, 1):
        print(f"  [{si}-{mi}] {display}: {m}", file=sys.stderr)
print("", file=sys.stderr)
print("  [q] 退出", file=sys.stderr)
' 2>/dev/null

  echo "" 1>&2

  # Get selection
  local selection
  read -p "  选择（如 0, 1, 1-1,2 或 1-1,1-2）: " selection
  echo "" 1>&2

  [[ "$selection" == "q" ]] && exit 0

  # Parse selection, expand hierarchy, merge/dedup coverage
  echo "$services_json" | python3 -c "
import json, sys

services = json.loads(sys.stdin.read())
raw_sel = '${selection}'

def expand_selection(sel_str, svcs):
    if sel_str == '0':
        results = []
        seen = set()
        for s in svcs:
            for m in s.get('models', []):
                if m == '(running)':
                    continue
                key = (s['ip'], s['port'], m)
                if key not in seen:
                    seen.add(key)
                    results.append({'ip': s['ip'], 'port': s['port'], 'model': m})
        return results

    # Parse comma-separated entries
    selected = set()  # (svc_idx,) or (svc_idx, model_idx)
    for part in sel_str.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            a, b = part.split('-', 1)
            selected.add((int(a.strip()), int(b.strip())))
        else:
            try:
                selected.add((int(part),))
            except ValueError:
                pass

    # Merge coverage: if a service-level entry exists, drop its children
    svc_indices = {t[0] for t in selected if len(t) == 1}
    clean = [t for t in selected if len(t) == 1 or t[0] not in svc_indices]

    # Expand to flat model list with dedup
    results = []
    seen = set()
    for entry in clean:
        si = entry[0] - 1
        if si < 0 or si >= len(svcs):
            continue
        s = svcs[si]
        models = [m for m in s.get('models', []) if m != '(running)']

        if len(entry) == 1:
            # Entire service
            for m in models:
                key = (s['ip'], s['port'], m)
                if key not in seen:
                    seen.add(key)
                    results.append({'ip': s['ip'], 'port': s['port'], 'model': m})
        else:
            # Single model
            mi = entry[1] - 1
            if 0 <= mi < len(models):
                m = models[mi]
                key = (s['ip'], s['port'], m)
                if key not in seen:
                    seen.add(key)
                    results.append({'ip': s['ip'], 'port': s['port'], 'model': m})

    return results

output = expand_selection(raw_sel, services)
print(json.dumps(output, indent=2, ensure_ascii=False))
" 2>/dev/null
}

# ============ Test Runner ============

# Description: Run tests for selected models and generate report
# Arguments: $1 — JSON array of {ip, port, model}
run_tests() {
  local test_list="$1"
  local total_models
  total_models=$(echo "$test_list" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(len(data))
" 2>/dev/null)

  if [[ "$total_models" -eq 0 ]]; then
    die "没有选中的模型"
  fi

  section "Starting Tests"
  info "  共 ${total_models} 个模型待测试"
  echo ""

  local results=()
  local count=0

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    local ip
    local port
    local model
    ip=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['ip'])")
    port=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['port'])")
    model=$(echo "$item" | python3 -c "import json,sys; print(json.load(sys.stdin)['model'])")

    count=$((count + 1))
    echo -ne "  [${count}/${total_models}] Testing ${model}...\r"

    local result
    result=$(test_one_model "$ip" "$port" "$model")
    results+=("$result")

    local status
    status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")

    if [[ "$status" == "ok" ]]; then
      local tps
      tps=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tokens_per_sec','N/A'))")
      echo -e "  [${count}/${total_models}] ${GREEN}✓${NC} ${model}  (${tps} tok/s)          "
    else
      local reason
      reason=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason','unknown'))")
      echo -e "  [${count}/${total_models}] ${RED}✗${NC} ${model}  (${reason})          "
    fi
  done <<< "$(echo "$test_list" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    print(json.dumps(item, ensure_ascii=False))
" 2>/dev/null)"

  echo ""

  # Generate summary report
  generate_report "$(printf '%s\n' "${results[@]}")"
}

# ============ Summary Report ============

# Description: Print formatted summary report from test results
# Arguments: $1 — newline-separated JSON result objects
generate_report() {
  local results_json="$1"

  local report
  report=$(python3 -c "
import json, sys

results_data = [json.loads(l) for l in sys.stdin.read().strip().split('\n') if l.strip()]
total = len(results_data)
passed = sum(1 for r in results_data if r.get('status') == 'ok')
failed = sum(1 for r in results_data if r.get('status') == 'fail')
skipped = sum(1 for r in results_data if r.get('status') == 'skip')

report_lines = []
report_lines.append('')
report_lines.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
report_lines.append('  Model Test Summary Report')
report_lines.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
report_lines.append('')

for r in results_data:
    model = r.get('model', 'unknown')
    status = r.get('status', '?')
    if status == 'ok':
        tps = r.get('tokens_per_sec', 'N/A')
        cold = r.get('cold_start', 'no')
        elapsed = r.get('elapsed_sec', 0)
        report_lines.append(f'  {model:<30s} | OK   | {str(tps):>8s} tok/s | cold: {cold}')
    elif status == 'fail':
        reason = r.get('reason', 'unknown')
        report_lines.append(f'  {model:<30s} | FAIL | {reason}')
    else:
        report_lines.append(f'  {model:<30s} | SKIP | {r.get(\"reason\", \"\")}')

report_lines.append('')
report_lines.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
report_lines.append(f'  Tested: {total}  |  Pass: {passed}  |  Fail: {failed}  |  Skip: {skipped}')
report_lines.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
report_lines.append('')

print('\n'.join(report_lines))

# Return structured data for exit code
summary = {'total': total, 'passed': passed, 'failed': failed, 'skipped': skipped}
print(json.dumps(summary))
" <<< "$results_json" 2>/dev/null)

  # Last line is JSON summary, rest is display
  local summary_json
  summary_json=$(echo "$report" | tail -1)
  echo "$report" | head -n -1

  local failed
  failed=$(echo "$summary_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('failed',0))" 2>/dev/null || echo "0")

  return "$failed"
}

# ============ Main ============
main() {
  local mode=""
  local filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) mode="all"; shift ;;
      --models) mode="models"; filter="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
      --node) mode="node"; filter="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
      -h|--help)
        echo "用法: $(basename "$0") [选项]"
        echo ""
        echo "  --all                     测试所有活跃服务"
        echo "  --models model1,model2    指定模型列表"
        echo "  --node node_name          仅测试指定节点"
        echo ""
        echo "  无参数: 交互式选择"
        exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  local services_json
  services_json=$(load_services)

  local test_list

  case "$mode" in
    all)
      # Select all models from all active services
      test_list=$(echo "$services_json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
results = []
for s in data:
    for m in s.get('models', []):
        if m == '(running)':
            continue
        results.append({'ip': s['ip'], 'port': s['port'], 'model': m})
print(json.dumps(results, ensure_ascii=False))
")
      ;;
    models)
      # Filter by model name
      test_list=$(echo "$services_json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
targets = '${filter}'.split(',')
results = []
for s in data:
    for m in s.get('models', []):
        for t in targets:
            if t.strip() == m:
                results.append({'ip': s['ip'], 'port': s['port'], 'model': m})
print(json.dumps(results, ensure_ascii=False))
")
      ;;
    node)
      # Filter by node name
      test_list=$(echo "$services_json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
target = '${filter}'
results = []
for s in data:
    if target in s.get('node', ''):
        for m in s.get('models', []):
            if m == '(running)':
                continue
            results.append({'ip': s['ip'], 'port': s['port'], 'model': m})
print(json.dumps(results, ensure_ascii=False))
")
      ;;
    *)
      test_list=$(interactive_select)
      ;;
  esac

  if [[ -z "$test_list" || "$test_list" == "[]" ]]; then
    die "没有匹配的模型"
  fi

  run_tests "$test_list"
}

main "$@"
