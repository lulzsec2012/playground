#!/bin/bash

# ====================== 配置参数 ======================
PORT=11434
LOG_FILE=~/ollama-multimodel.log
MAX_WAIT_TIME=300                    # 模型加载最大等待时间（秒）
GPU_CLEANUP_WAIT=5                   # GPU 清理后等待时间（秒）
OLLAMA_STARTUP_WAIT=30               # Ollama 服务启动最大等待时间（秒）

# ====================== 环境变量优化（多模型常驻，不绑定GPU） ======================
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7   # 服务进程可见全部 8 张卡
export OLLAMA_CUDA=1
export OLLAMA_HOST=0.0.0.0:${PORT}
export OLLAMA_KEEP_ALIVE=-1                    # 模型永不卸载
export OLLAMA_NUM_PARALLEL=2                   # 降低并行度，减少显存碎片
export OLLAMA_MAX_LOADED_MODELS=5              # 允许最多 5 个模型常驻（根据需求调整）
export OLLAMA_LOAD_TIMEOUT=300                 # 模型加载超时
export OLLAMA_GPU_OVERHEAD=2048                # 为每模型预留额外显存，防止 OOM
export OLLAMA_FLASH_ATTENTION=1                # 启用 Flash Attention

# ====================== 函数定义 ======================

print_info() { echo -e "\033[32m[INFO]\033[0m $1"; }
print_warning() { echo -e "\033[33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }
print_header() { echo ""; echo "╔════════════════════════════════════════════════════════════╗"; echo "║     $1"; echo "╚════════════════════════════════════════════════════════════╝"; echo ""; }
print_command() { echo -e "\033[36m[EXEC]\033[0m $1"; }

get_gpu_memory_usage() {
    nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | \
    awk -F', ' '{printf "   GPU %s: %s | 已用: %s MiB / 总计: %s MiB\n", $1, $2, $3, $4}'
}

get_total_gpu_memory_used() {
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{sum+=$1} END {print sum}'
}

get_total_gpu_memory_capacity() {
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{sum+=$1} END {print sum}'
}

check_model_exists() {
    local model_name="$1"
    ollama list 2>/dev/null | grep -q "^${model_name}\s"
}

download_model() {
    local model_name="$1"
    print_warning "模型 ${model_name} 不存在，开始下载..."
    ollama pull "${model_name}" && print_info "下载完成" || print_error "下载失败"
}

cleanup_ollama_and_gpu() {
    print_info "清理当前用户（$(whoami)）的所有 Ollama 进程..."
    local current_pid=$$
    # 只杀死当前用户的 ollama 进程，避免影响其他用户
    local all_pids=$(pgrep -u $(whoami) -f "ollama" 2>/dev/null | grep -v "^${current_pid}$" || true)
    if [ -n "$all_pids" ]; then
        echo "   进程: $(echo $all_pids | tr '\n' ' ')"
        echo $all_pids | xargs kill -TERM 2>/dev/null
        sleep 3
        local remaining=$(pgrep -u $(whoami) -f "ollama" 2>/dev/null | grep -v "^${current_pid}$" || true)
        [ -n "$remaining" ] && echo $remaining | xargs kill -9 2>/dev/null
        sleep 2
        print_info "当前用户的 Ollama 进程已清理"
    else
        print_info "未发现当前用户的 Ollama 进程"
    fi
    
    print_info "等待 GPU 显存释放..."
    sleep $GPU_CLEANUP_WAIT
    get_gpu_memory_usage
}

is_port_in_use() { lsof -i :${PORT} >/dev/null 2>&1; }

start_ollama_service() {
    if is_port_in_use; then
        print_warning "端口 ${PORT} 已被占用"
        if curl -s http://localhost:${PORT} >/dev/null 2>&1; then
            print_info "Ollama 服务已在运行"
            return 0
        else
            fuser -k ${PORT}/tcp 2>/dev/null
            sleep 2
        fi
    fi
    print_info "启动 Ollama 服务（可见全部 GPU）..."
    nohup ollama serve > "${LOG_FILE}" 2>&1 &
    local pid=$!
    print_info "PID: ${pid}"
    for i in $(seq 1 $OLLAMA_STARTUP_WAIT); do
        curl -s http://localhost:${PORT} >/dev/null 2>&1 && { print_info "服务就绪"; return 0; }
        sleep 1
    done
    print_error "启动超时"
    tail -n 20 "${LOG_FILE}"
    return 1
}

show_memory_usage() {
    local used=$(get_total_gpu_memory_used)
    local cap=$(get_total_gpu_memory_capacity)
    echo "   📊 GPU 显存使用: ${used} MiB / ${cap} MiB ($((used*100/cap))%)"
    get_gpu_memory_usage
}

wait_for_model() {
    local model_name="$1"
    local waited=0
    print_info "等待模型加载: ${model_name}"
    while ! ollama ps 2>/dev/null | grep -q "${model_name}"; do
        sleep 3
        waited=$((waited+3))
        if [ $((waited % 12)) -eq 0 ]; then
            echo ""
            echo "   ⏳ 等待中... (${waited}s)"
            show_memory_usage
        else
            echo -n "."
        fi
        if [ $waited -ge $MAX_WAIT_TIME ]; then
            echo ""
            print_error "加载超时"
            return 1
        fi
    done
    echo ""
    print_info "✅ ${model_name} 已载入显存"
    show_memory_usage
    return 0
}

load_model() {
    local model_name="$1"
    local description="$2"
    print_header "加载模型: ${model_name}"
    print_info "${description}"
    check_model_exists "$model_name" || download_model "$model_name" || return 1
    print_command "ollama run ${model_name} 'warmup'"
    ollama run "${model_name}" "warmup" >/dev/null 2>&1 &
    local pid=$!
    print_info "加载进程 PID: ${pid}"
    wait_for_model "${model_name}" || { kill $pid 2>/dev/null; return 1; }
    print_info "✅ ${model_name} 加载成功"
    return 0
}

show_final_status() {
    echo ""
    print_header "最终状态报告"
    show_memory_usage
    echo ""
    echo "📊 当前模型列表:"
    ollama ps 2>/dev/null | tail -n +2 || echo "   无模型加载"
    echo ""
    echo "🔧 服务: http://localhost:${PORT} | 日志: ${LOG_FILE}"
}

# ====================== 交互式选择模型 ======================
get_available_models() {
    # 返回 ollama list 中除了表头以外的模型名列表（按行存储）
    ollama list 2>/dev/null | awk 'NR>1 {print $1}'
}

show_model_menu() {
    local models=("$@")
    echo "📋 可用的本地模型列表："
    for i in "${!models[@]}"; do
        # 尝试获取模型大小（可选，增强用户体验）
        local size_info=$(ollama list | grep "^${models[$i]}" | awk '{print $3, $4}')
        printf "  [%2d] %s  (%s)\n" $((i+1)) "${models[$i]}" "$size_info"
    done
    echo ""
}

parse_selection() {
    local input="$1"
    local total=$2
    local selected_indices=()
    # 将逗号和空格统一替换为空格，然后遍历
    local cleaned=$(echo "$input" | tr ',' ' ')
    for token in $cleaned; do
        if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "$total" ]; then
            selected_indices+=($((token-1)))
        else
            print_warning "忽略无效序号: $token"
        fi
    done
    # 去重并保持顺序（使用关联数组去重，但bash 4支持）
    local unique=()
    for idx in "${selected_indices[@]}"; do
        local found=0
        for u in "${unique[@]}"; do
            [ "$u" -eq "$idx" ] && found=1 && break
        done
        [ $found -eq 0 ] && unique+=($idx)
    done
    echo "${unique[@]}"
}

# ====================== 主程序 ======================
main() {
    print_header "Ollama 多模型常驻启动脚本（交互式选择模型）"
    cleanup_ollama_and_gpu
    start_ollama_service || exit 1
    echo ""
    print_info "初始显存状态:"
    show_memory_usage

    # 获取可用模型列表
    mapfile -t available_models < <(get_available_models)
    if [ ${#available_models[@]} -eq 0 ]; then
        print_error "没有找到任何本地模型，请先使用 'ollama pull <model>' 下载模型"
        exit 1
    fi

    show_model_menu "${available_models[@]}"
    echo -n "请输入要加载的模型序号（支持逗号或空格分隔，如 1,3,5 或 1 3 5）："
    read -r selection
    if [ -z "$selection" ]; then
        print_warning "未输入任何序号，退出"
        exit 0
    fi

    selected_indices=($(parse_selection "$selection" ${#available_models[@]}))
    if [ ${#selected_indices[@]} -eq 0 ]; then
        print_error "没有有效的序号，退出"
        exit 1
    fi

    print_info "将按以下顺序加载 ${#selected_indices[@]} 个模型："
    for idx in "${selected_indices[@]}"; do
        echo "  - ${available_models[$idx]}"
    done

    # 建议用户按显存从大到小排序，这里保持用户输入的顺序
    # 如果用户希望自动排序，可以在此处添加排序逻辑，但需求未要求，故保留原始顺序

    local success=0
    for idx in "${selected_indices[@]}"; do
        model_name="${available_models[$idx]}"
        # 尝试获取模型大小作为描述（可选）
        desc="用户选择的模型: ${model_name}"
        if load_model "$model_name" "$desc"; then
            ((success++))
        else
            print_warning "${model_name} 加载失败"
        fi
        # 模型间等待5秒，让显存稳定
        [ $idx -ne ${selected_indices[-1]} ] && sleep 5
    done

    show_final_status
    echo ""
    print_header "启动完成"
    echo "成功加载: ${success}/${#selected_indices[@]}"
    if [ $success -eq ${#selected_indices[@]} ]; then
        print_info "🎉 所选模型全部常驻显存"
    else
        print_warning "部分模型加载失败，请检查显存或日志"
    fi
}

trap 'echo ""; print_info "中断"; exit 0' INT TERM
main