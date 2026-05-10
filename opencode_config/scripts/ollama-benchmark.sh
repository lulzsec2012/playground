#!/bin/bash
# ============================================================
# 脚本: benchmark_ollama_models_advanced.sh
# 功能: 测试模型显存占用与推理速度，计算最小所需GPU卡数，
#       并给出模型组合建议（基于8×24GB显存）
# ============================================================

set -euo pipefail

# ------------------------------ 配置 ------------------------------
TEST_PROMPT="解释什么是量子计算，用大约100字。"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
WARMUP_REQUESTS=1          # 预热请求次数（不计时）
BENCHMARK_REQUESTS=3       # 正式测试次数（取平均）
SINGLE_GPU_MEM_MIB=24576   # 单张 RTX 4090 显存 (24GB)
TOTAL_GPU_COUNT=8          # 服务器总卡数
TOTAL_MEM_MIB=$((SINGLE_GPU_MEM_MIB * TOTAL_GPU_COUNT))

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# 结果文件
RESULT_CSV="model_benchmark.csv"
COMBINATION_REPORT="model_combination_advice.txt"

# ------------------------------ 辅助函数 ------------------------------
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 获取当前总显存使用量 (MiB)
get_total_gpu_memory_used() {
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{sum+=$1} END {print sum}'
}

# 获取每张 GPU 显存使用量 (MiB)
get_per_gpu_memory_used() {
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr '\n' ',' | sed 's/,$//'
}

# 清理所有 Ollama 进程和 GPU 显存
cleanup_gpu() {
    log_info "清理 GPU 显存..."
    pkill -f "ollama run" 2>/dev/null || true
    sleep 3
    # 如果显存未释放，重启服务
    local used=$(get_total_gpu_memory_used)
    if [ "$used" -gt 100 ]; then
        log_warn "显存未完全释放，重启 Ollama 服务..."
        pkill -f "ollama serve" || true
        sleep 2
        nohup ollama serve > /dev/null 2>&1 &
        sleep 5
    fi
    log_info "清理完成，当前总显存占用: $(get_total_gpu_memory_used) MiB"
}

# 计算最小所需卡数
calc_min_gpus() {
    local mem_mib=$1
    # 向上取整
    echo $(( (mem_mib + SINGLE_GPU_MEM_MIB - 1) / SINGLE_GPU_MEM_MIB ))
}

# ------------------------------ 主测试流程 ------------------------------
main() {
    # 检查依赖
    for cmd in ollama curl nvidia-smi bc; do
        if ! command -v $cmd &> /dev/null; then
            log_error "缺少命令: $cmd"
            exit 1
        fi
    done

    # 获取所有模型
    mapfile -t models < <(ollama list | awk 'NR>1 {print $1}')
    if [ ${#models[@]} -eq 0 ]; then
        log_error "没有找到任何模型，请先 pull 模型。"
        exit 1
    fi
    log_info "发现 ${#models[@]} 个模型: ${models[*]}"

    # 初始化 CSV 文件
    echo "模型名称,显存占用(MiB),最小卡数,冷启动时间(秒),平均推理时间(秒),每卡显存分布" > "$RESULT_CSV"

    # 临时存储各模型数据用于组合分析
    declare -a model_names
    declare -a model_mems

    for model in "${models[@]}"; do
        echo ""
        log_info "========== 测试模型: $model =========="

        # 1. 清理显存
        cleanup_gpu
        base_mem=$(get_total_gpu_memory_used)
        base_per_gpu=$(get_per_gpu_memory_used)
        log_info "基线显存: ${base_mem} MiB, 每卡 [${base_per_gpu}]"

        # 2. 冷启动时间（首次加载+推理）
        log_info "测量冷启动时间（包含模型加载）..."
        start_time=$(date +%s.%N)
        curl -s -X POST "$OLLAMA_HOST/api/generate" \
            -d "{\"model\":\"$model\",\"prompt\":\"$TEST_PROMPT\",\"stream\":false}" > /dev/null
        end_time=$(date +%s.%N)
        cold_time=$(echo "$end_time - $start_time" | bc)

        # 3. 等待显存稳定，记录占用
        sleep 2
        after_mem=$(get_total_gpu_memory_used)
        after_per_gpu=$(get_per_gpu_memory_used)
        mem_used=$((after_mem - base_mem))
        if [ $mem_used -lt 0 ]; then mem_used=0; fi
        min_gpus=$(calc_min_gpus $mem_used)

        log_info "显存占用: ${mem_used} MiB, 最小所需卡数: ${min_gpus}"
        log_info "冷启动时间: ${cold_time} 秒"

        # 4. 预热（让模型完全驻留）
        log_info "预热模型（${WARMUP_REQUESTS} 次请求）..."
        for i in $(seq 1 $WARMUP_REQUESTS); do
            curl -s -X POST "$OLLAMA_HOST/api/generate" \
                -d "{\"model\":\"$model\",\"prompt\":\"Warmup\",\"stream\":false}" > /dev/null
            sleep 1
        done

        # 5. 测量纯推理时间（热启动）
        log_info "测量纯推理速度（${BENCHMARK_REQUESTS} 次平均）..."
        total_time=0
        for i in $(seq 1 $BENCHMARK_REQUESTS); do
            start_time=$(date +%s.%N)
            curl -s -X POST "$OLLAMA_HOST/api/generate" \
                -d "{\"model\":\"$model\",\"prompt\":\"$TEST_PROMPT\",\"stream\":false}" > /dev/null
            end_time=$(date +%s.%N)
            iter_time=$(echo "$end_time - $start_time" | bc)
            total_time=$(echo "$total_time + $iter_time" | bc)
            echo "  第 ${i} 次: ${iter_time} 秒"
            sleep 1
        done
        avg_time=$(echo "scale=3; $total_time / $BENCHMARK_REQUESTS" | bc)
        log_info "平均推理时间（热）: ${avg_time} 秒"

        # 保存结果
        echo "$model,$mem_used,$min_gpus,$cold_time,$avg_time,\"[$after_per_gpu]\"" >> "$RESULT_CSV"
        model_names+=("$model")
        model_mems+=("$mem_used")
    done

    # ------------------------------ 输出汇总表格 ------------------------------
    echo ""
    echo "============================ 最终汇总 ============================"
    printf "%-30s %-12s %-10s %-12s %-12s\n" "模型名称" "显存占用" "最小卡数" "冷启动(秒)" "热推理(秒)"
    echo "------------------------------------------------------------------------"
    while IFS=',' read -r name mem min_gpus cold avg per_gpu; do
        # 去除可能的引号
        name=$(echo "$name" | tr -d '"')
        mem_disp="${mem} MiB"
        printf "%-30s %-12s %-10s %-12s %-12s\n" "$name" "$mem_disp" "$min_gpus" "$cold" "$avg"
    done < <(tail -n +2 "$RESULT_CSV")
    echo "========================================================================"

    # ------------------------------ 模型组合建议 ------------------------------
    log_info "生成模型组合建议（基于 ${TOTAL_GPU_COUNT}×${SINGLE_GPU_MEM_MIB} MiB 显存）..."
    cat > "$COMBINATION_REPORT" << EOF
# 模型组合建议
服务器配置: ${TOTAL_GPU_COUNT} 张 RTX 4090，单卡 ${SINGLE_GPU_MEM_MIB} MiB (24 GiB)
总显存: ${TOTAL_MEM_MIB} MiB

## 各模型最小卡数需求
EOF

    # 按显存占用降序排序
    sort -t',' -k2 -rn <(tail -n +2 "$RESULT_CSV") | while IFS=',' read -r name mem min_gpus cold avg per_gpu; do
        name=$(echo "$name" | tr -d '"')
        echo "- ${name}: ${mem} MiB → 至少需要 ${min_gpus} 张卡" >> "$COMBINATION_REPORT"
    done

    echo "" >> "$COMBINATION_REPORT"
    echo "## 可同时常驻的模型组合（按总卡数 ≤ ${TOTAL_GPU_COUNT} 且总显存 ≤ ${TOTAL_MEM_MIB} MiB 排序）" >> "$COMBINATION_REPORT"
    echo "" >> "$COMBINATION_REPORT"

    # 简单贪心组合（按显存降序尝试打包）
    # 创建一个索引数组
    indices=()
    mems=()
    names=()
    while IFS=',' read -r name mem min_gpus cold avg per_gpu; do
        name=$(echo "$name" | tr -d '"')
        names+=("$name")
        mems+=($mem)
    done < <(tail -n +2 "$RESULT_CSV" | sort -t',' -k2 -rn)

    # 生成所有可能的单组组合（不超过总卡数和总显存）
    # 由于模型数量不多，直接输出所有满足条件的子集（简单起见，输出一个推荐组合）
    # 这里采用贪心：从大到小尝试装入，直到剩余卡数或显存不足
    remaining_gpus=$TOTAL_GPU_COUNT
    remaining_mem=$TOTAL_MEM_MIB
    combination=()
    for i in "${!names[@]}"; do
        need_gpus=$(calc_min_gpus ${mems[$i]})
        if [ $need_gpus -le $remaining_gpus ] && [ ${mems[$i]} -le $remaining_mem ]; then
            combination+=("${names[$i]} (${mems[$i]} MiB, ${need_gpus}卡)")
            remaining_gpus=$((remaining_gpus - need_gpus))
            remaining_mem=$((remaining_mem - ${mems[$i]}))
        fi
    done

    echo "### 推荐打包组合（贪心算法，从大到小）" >> "$COMBINATION_REPORT"
    if [ ${#combination[@]} -eq 0 ]; then
        echo "没有模型能单独装入剩余资源？请检查。" >> "$COMBINATION_REPORT"
    else
        for item in "${combination[@]}"; do
            echo "- $item" >> "$COMBINATION_REPORT"
        done
        echo "" >> "$COMBINATION_REPORT"
        echo "剩余可用卡数: ${remaining_gpus}，剩余显存: ${remaining_mem} MiB" >> "$COMBINATION_REPORT"
    fi

    # 额外列出所有两两组合（可选）
    echo "" >> "$COMBINATION_REPORT"
    echo "### 所有可同时常驻的两两模型组合（卡数+显存均不超限）" >> "$COMBINATION_REPORT"
    for i in "${!names[@]}"; do
        for j in $(($i+1)); do
            if [ $j -lt ${#names[@]} ]; then
                total_mem=$((mems[$i] + mems[$j]))
                total_gpus=$(( $(calc_min_gpus ${mems[$i]}) + $(calc_min_gpus ${mems[$j]}) ))
                if [ $total_mem -le $TOTAL_MEM_MIB ] && [ $total_gpus -le $TOTAL_GPU_COUNT ]; then
                    echo "- ${names[$i]} + ${names[$j]} : 总显存 ${total_mem} MiB, 总卡数 ${total_gpus}" >> "$COMBINATION_REPORT"
                fi
            fi
        done
    done

    log_info "组合建议已保存到: $COMBINATION_REPORT"
    echo ""
    cat "$COMBINATION_REPORT"
}

# 运行主程序
main