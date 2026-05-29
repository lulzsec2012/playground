#!/usr/bin/env bash
# ===========================================================================
# bench_models.sh — 测试显卡上三个 vLLM 模型的推理速度
# 用法:
#   bash scripts/hermes/bench_models.sh              # 测试全部模型
#   bash scripts/hermes/bench_models.sh gemma4        # 测试指定模型
#   bash scripts/hermes/bench_models.sh --restart     # 先重启服务再测试
#
# 三个模型:
#   gemma4       → :8001  gemma4-26b-fp8       (TP=2, GPU 0,1)
#   qwen3.6      → :8002  qwen3.6-27b           (TP=2, GPU 2,3)
#   qwen3-coder  → :8003  qwen3-coder-next-fp8  (TP=4, GPU 4-7)
# ===========================================================================
set -euo pipefail

# ---- Config ----
CONTAINER="lulizhi-work-server-dev"
BASE_URL="http://127.0.0.1"

declare -A MODELS
MODELS["gemma4"]="8001:gemma4-26b-fp8"
MODELS["qwen3.6"]="8002:qwen3.6-27b"
MODELS["qwen3-coder"]="8003:qwen3-coder-next-fp8"

# ---- Prompts ----
PROMPT_SHORT="What is the capital of France?"
PROMPT_MED="Write a Python function to implement a binary search tree with insert, delete, and search operations."
PROMPT_LONG="Explain the theory of relativity. Include special relativity, general relativity, time dilation, length contraction, and the equivalence principle. Use examples and mathematical formulas where appropriate."

# ---- Helpers ----
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[1;33m'; cyan='\033[0;36m'; bold='\033[1m'; nc='\033[0m'

info()  { echo -e "${green}[INFO]${nc} $*"; }
warn()  { echo -e "${yellow}[WARN]${nc} $*"; }
err()   { echo -e "${red}[ERR]${nc} $*" >&2; }
title() { echo -e "\n${cyan}══════════════════════════════════════════════════════════════${nc}"; echo -e "${bold}$*${nc}"; echo -e "${cyan}══════════════════════════════════════════════════════════════${nc}"; }

api_get() {
  local port="$1" endpoint="$2"
  docker exec "$CONTAINER" sh -c "curl -sf --max-time 5 'http://127.0.0.1:$port$endpoint' 2>/dev/null"
}

api_chat() {
  local port="$1" model="$2" prompt="$3" max_tok="$4" stream="$5"
  # Escape the prompt for JSON (simple escaping)
  local escaped
  escaped=$(echo "$prompt" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null)
  docker exec "$CONTAINER" sh -c "
    curl -sf --max-time 180 'http://127.0.0.1:$port/v1/chat/completions' \
      -H 'Content-Type: application/json' \
      -d '{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":$escaped}],\"max_tokens\":$max_tok,\"stream\":$stream}' 2>/dev/null
  "
}

# ---- Measure: Latency (no stream) ----
measure_latency() {
  local name="$1" port="$2" model="$3" label="$4" prompt="$5" max_tok="$6"
  local start elapsed output usage comp_tok prompt_tok tps

  start=$(date +%s.%N)
  output=$(api_chat "$port" "$model" "$prompt" "$max_tok" "false") || {
    echo "TIMEOUT|0|0|0"
    return
  }
  elapsed=$(echo "$(date +%s.%N) - $start" | bc 2>/dev/null || echo "0")

  usage=$(echo "$output" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    u=d.get('usage',{})
    c=u.get('completion_tokens',0)
    p=u.get('prompt_tokens',0)
    print(f'{c},{p}')
except: print('0,0')
" 2>/dev/null) || usage="0,0"

  comp_tok=$(echo "$usage" | cut -d, -f1)
  prompt_tok=$(echo "$usage" | cut -d, -f2)
  tps=$(echo "scale=1; if($comp_tok > 0) $comp_tok / $elapsed else 0" | bc 2>/dev/null || echo "0")
  echo "$elapsed|$comp_tok|$prompt_tok|$tps"
}

# ---- Measure: Streaming (throughput + TTFT) ----
measure_stream() {
  local name="$1" port="$2" model="$3" label="$4" prompt="$5" max_tok="$6"
  local start elapsed first_token_time raw_output tok_count output_ttft tps

  start=$(date +%s.%N)
  raw_output=$(api_chat "$port" "$model" "$prompt" "$max_tok" "true") || {
    echo "TIMEOUT|0|0"
    return
  }
  elapsed=$(echo "$(date +%s.%N) - $start" | bc 2>/dev/null || echo "0")

  # Parse SSE response: count token deltas, find first token time
  tok_count=$(echo "$raw_output" | grep -c '"content"' 2>/dev/null || echo "0")

  # TTFT: time to first token
  first_token_time=$(echo "$raw_output" | grep -b 'data:' | head -2 | tail -1 | cut -d: -f1 2>/dev/null || echo "0")
  if [ -n "$first_token_time" ] && [ "$first_token_time" != "0" ] && [ "${#raw_output}" -gt 0 ]; then
    # Estimate: assume first chunk arrives around 15-25% of raw data
    output_ttft=$(echo "scale=3; $first_token_time / 1000 * 0.02" | bc 2>/dev/null || echo "0")
  else
    output_ttft="?"
  fi

  tps=$(echo "scale=1; if($tok_count > 0 && $(echo "$elapsed > 0" | bc -l)) $tok_count / $elapsed else 0" | bc 2>/dev/null || echo "0")
  echo "$elapsed|$tok_count|$tps"
}

# ---- Test a single model ----
bench_model() {
  local name="$1"
  IFS=: read -r port model <<< "${MODELS[$name]}"

  title "📊 $name ($model) — Port $port"

  # Check if API is alive
  local models_json
  models_json=$(api_get "$port" "/v1/models")
  if [ -z "$models_json" ]; then
    err "API at :$port is not responding. Skipping."
    return
  fi

  info "API is alive ✓"

  # ── 1. Latency (no stream) ──
  echo ""
  echo -e "${bold}Latency (非流式)${nc}"
  printf "  %-12s %8s  %10s  %8s  %7s  %5s\n" "Prompt" "MaxTokens" "耗时(s)" "输出tok" "tok/s" "输入tok"
  printf "  %-12s %8s  %10s  %8s  %7s  %5s\n" "-------" "--------" "-------" "-------" "-----" "-------"

  for test_case in "short:${PROMPT_SHORT}:64" "medium:${PROMPT_MED}:256" "code:${PROMPT_MED}:1024" "long:${PROMPT_LONG}:2048"; do
    IFS=: read -r label prompt max_tok <<< "$test_case"
    result=$(measure_latency "$name" "$port" "$model" "$label" "$prompt" "$max_tok")
    IFS='|' read -r elapsed comp_tok prompt_tok tps <<< "$result"

    if [ "$elapsed" = "TIMEOUT" ]; then
      printf "  ${red}%-12s %8d  ⏰ TIMEOUT${nc}\n" "$label" "$max_tok"
    else
      printf "  %-12s %8d  %10.3f  %8d  %7.1f  %5d\n" "$label" "$max_tok" "$elapsed" "$comp_tok" "$tps" "$prompt_tok"
    fi
  done

  # ── 2. Streaming (throughput) ──
  echo ""
  echo -e "${bold}Streaming (流式)${nc}"
  printf "  %-12s %8s  %10s  %8s  %7s\n" "Prompt" "MaxTokens" "耗时(s)" "输出tok" "tok/s"
  printf "  %-12s %8s  %10s  %8s  %7s\n" "-------" "--------" "-------" "-------" "-----"

  for test_case in "short:${PROMPT_SHORT}:64" "medium:${PROMPT_MED}:256"; do
    IFS=: read -r label prompt max_tok <<< "$test_case"
    result=$(measure_stream "$name" "$port" "$model" "$label" "$prompt" "$max_tok")
    IFS='|' read -r elapsed tok_count tps <<< "$result"

    if [ "$elapsed" = "TIMEOUT" ]; then
      printf "  ${red}%-12s %8d  ⏰ TIMEOUT${nc}\n" "$label" "$max_tok"
    else
      printf "  %-12s %8d  %10.3f  %8d  %7.1f\n" "$label" "$max_tok" "$elapsed" "$tok_count" "$tps"
    fi
  done

  # ── 3. Warm vs Cold latency ──
  echo ""
  echo -e "${bold}Warm vs Cold (流式, short)${nc}"
  # Cold: first request after idle
  result_cold=$(measure_stream "$name" "$port" "$model" "cold" "$PROMPT_SHORT" "64")
  IFS='|' read -r elapsed_cold tok_cold tps_cold <<< "$result_cold"
  # Warm: second request immediately after
  result_warm=$(measure_stream "$name" "$port" "$model" "warm" "$PROMPT_SHORT" "64")
  IFS='|' read -r elapsed_warm tok_warm tps_warm <<< "$result_warm"

  if [ "$elapsed_cold" != "TIMEOUT" ]; then
    printf "  %-12s  %10s  %8s  %7s\n" "" "耗时(s)" "输出tok" "tok/s"
    printf "  %-12s  %10.3f  %8d  %7.1f\n" "Cold(冷启动)" "$elapsed_cold" "$tok_cold" "$tps_cold"
  fi
  if [ "$elapsed_warm" != "TIMEOUT" ]; then
    printf "  %-12s  %10.3f  %8d  %7.1f\n" "Warm(预热后)" "$elapsed_warm" "$tok_warm" "$tps_warm"
  fi

  echo ""
}

# ===========================================================================
# Main
# ===========================================================================

SELF="$0"
RESTART_FLAG=false

# Parse args
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--restart" ]; then
    RESTART_FLAG=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]}"

# Restart if requested
if [ "$RESTART_FLAG" = true ]; then
  echo -e "${yellow}⚠  --restart: 将杀掉现有 vLLM 并重启${nc}"
  echo -e "${yellow}   使用 restart_all.sh 中的配置重新部署${nc}"
  # Check if restart_all.sh exists in container
  if docker exec "$CONTAINER" sh -c "[ -f /tmp/restart_all.sh ]" 2>/dev/null; then
    echo "  Found restart_all.sh in container, executing..."
    docker exec "$CONTAINER" sh -c "bash /tmp/restart_all.sh"
  else
    warn "restart_all.sh not found in container"
  fi
  exit 0
fi

# Test target
TARGET="${1:-all}"

echo ""
echo -e "${bold}🚀 vLLM 模型速度测试${nc}"
echo "  容器: $CONTAINER"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null | head -1 | sed 's/^/  GPU: /'

# Verify container
if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^$CONTAINER$"; then
  err "容器 $CONTAINER 不在运行中"
  exit 1
fi

if [ "$TARGET" = "all" ]; then
  for model_key in "gemma4" "qwen3.6" "qwen3-coder"; do
    bench_model "$model_key"
  done
elif [ -n "${MODELS[$TARGET]:-}" ]; then
  bench_model "$TARGET"
else
  err "未知模型: $TARGET"
  echo "  可选: all, gemma4, qwen3.6, qwen3-coder"
  exit 1
fi

# GPU memory summary
echo ""
echo -e "${bold}📊 显存使用情况${nc}"
nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv,noheader 2>/dev/null | \
  while IFS=, read -r idx used free; do
    echo "  GPU $idx: Used=${used} Free=${free}"
  done

echo ""
info "测试完成！"
