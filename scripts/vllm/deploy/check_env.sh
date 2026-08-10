#!/usr/bin/env bash
# check_env.sh — 验证 PyTorch 2.11 + CUDA 12.6 环境，支持 --fix 自动修复
#
# 用法:
#   ./scripts/check_env.sh           仅检查，失败则 exit 1
#   ./scripts/check_env.sh --fix     自动修复可修复项，再验证
#   ./scripts/check_env.sh --auto    等同 --fix
#
# 返回值: 0=全部通过, 1=存在不可修复的失败, 2=修复后仍有失败

set -euo pipefail

CONDA_ENV="dev312"
CONDA_BASE="${CONDA_BASE:-${CONDA_PREFIX%/envs/*}}"
[ -n "$CONDA_BASE" ] || CONDA_BASE="/workspace/miniconda3"
TORCH_VERSION="2.11.0"
CUDA_VERSION="cu126"
INDEX_URL="https://download.pytorch.org/whl/${CUDA_VERSION}"
FIX_MODE=false

for arg in "$@"; do
  case "$arg" in
    --fix|--auto) FIX_MODE=true ;;
  esac
done

# ---------- conda 激活 ----------
conda_activate() {
  eval "$("${CONDA_BASE}/bin/conda" shell.bash hook 2>/dev/null)" || true
  conda activate "${CONDA_ENV}" 2>/dev/null ||
    source "${CONDA_BASE}/bin/activate" "${CONDA_ENV}" 2>/dev/null || {
    echo "  [FAIL] conda 环境 '${CONDA_ENV}' 未找到"
    return 1
  }
}

# ---------- 执行诊断检查 ----------
run_checks() {
  python3 -c "
import sys, json

checks = {
    'torch_import':       False,
    'torch_version':      False,
    'cuda_version':       False,
    'cuda_available':     False,
    'compute_capability': False,
    'device_count':       False,
    'basic_ops':          False,
}
detail = {}

try:
    import torch
    checks['torch_import'] = True
    detail['torch_version_found'] = torch.__version__

    v = torch.__version__
    checks['torch_version'] = v.startswith('${TORCH_VERSION}') and '${CUDA_VERSION}' in v

    cv = torch.version.cuda
    checks['cuda_version'] = cv is not None and cv.startswith('12')
    detail['cuda_version_found'] = cv or 'None'

    checks['cuda_available'] = torch.cuda.is_available()
    detail['device_count'] = torch.cuda.device_count()

    if torch.cuda.is_available():
        cc = torch.cuda.get_device_capability(0)
        checks['compute_capability'] = cc[0] >= 8
        detail['compute_capability'] = f'{cc[0]}.{cc[1]}'
        checks['device_count'] = torch.cuda.device_count() >= 1

        x = torch.tensor([1.0, 2.0, 3.0], device='cuda')
        y = torch.tensor([4.0, 5.0, 6.0], device='cuda')
        z = x + y
        checks['basic_ops'] = z.sum().item() == 21.0

except Exception as e:
    detail['error'] = str(e)

all_pass = all(checks.values())
print(json.dumps({'all_pass': all_pass, 'checks': checks, 'detail': detail}))
sys.exit(0 if all_pass else 1)
" 2>&1
}

# ---------- 格式化输出检查结果 ----------
print_results() {
  local json="$1"
  echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
detail = d.get('detail', {})
for name, ok in d['checks'].items():
    status = 'PASS' if ok else 'FAIL'
    extra = ''
    if not ok:
        if name == 'torch_version':
            extra = f'  (found: {detail.get(\"torch_version_found\", \"?\")})'
        elif name == 'cuda_version':
            extra = f'  (found: {detail.get(\"cuda_version_found\", \"?\")})'
    if name == 'compute_capability':
        extra = f'  (sm_{detail.get(\"compute_capability\", \"?\")})'
    elif name == 'device_count' and d['checks']['device_count']:
        extra = f'  (found: {detail.get(\"device_count\", \"?\")})'
    print(f'  [{status}] {name}{extra}')
"
}

get_all_pass() {
  echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)['all_pass'])"
}

print_summary() {
  echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)['detail']
print(f'  torch: {d[\"torch_version_found\"]}')
print(f'  cuda:  {d[\"cuda_version_found\"]}')
print(f'  sm:    {d.get(\"compute_capability\", \"?\")}')
print(f'  gpus:  {d.get(\"device_count\", 0)}x RTX 4090')
"
}

# ---------- 修复逻辑 ----------
fix_issue() {
  local issue="$1"
  case "$issue" in
    torch_import|torch_version|cuda_version)
      echo "  → 重装 PyTorch ${TORCH_VERSION}+${CUDA_VERSION} ..."
      # torchvision 版本 = 0.(torch_major+16).(torch_patch)
      local tv_major=$(( ${TORCH_VERSION%%.*} + 16 ))
      local tv_minor="${TORCH_VERSION#*.}"; tv_minor="${tv_minor#*.}"
      pip install "torch==${TORCH_VERSION}+${CUDA_VERSION}" \
                  "torchvision==0.${tv_major}.${tv_minor}+${CUDA_VERSION}" \
                  "torchaudio==${TORCH_VERSION}+${CUDA_VERSION}" \
          --index-url "$INDEX_URL" --force-reinstall 2>&1 | tail -3
      echo "  → 重装完成"
      ;;
    cuda_available|basic_ops)
      # CUDA 运行时库路径问题，尝试设置 LD_LIBRARY_PATH
      local site_pkg
      site_pkg=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
      if [ -n "$site_pkg" ]; then
        local cuda_path="${site_pkg}/nvidia/nvjitlink/lib:${site_pkg}/nvidia/cuda_runtime/lib:${site_pkg}/nvidia/cusparse/lib:${site_pkg}/torch/lib"
        echo "  → 设置 LD_LIBRARY_PATH 指向 torch 自带 CUDA 库..."
        echo "     export LD_LIBRARY_PATH=${cuda_path}:\${LD_LIBRARY_PATH}"
        if [ "$issue" = "cuda_available" ]; then
          # 如果 GPU 不可见，也尝试重装 torch
          echo "  → GPU 不可见，尝试重装 PyTorch..."
          pip install "torch==${TORCH_VERSION}+${CUDA_VERSION}" \
                      "torchvision==0.${TORCH_VERSION##2.}+${CUDA_VERSION}" \
                      "torchaudio==${TORCH_VERSION}+${CUDA_VERSION}" \
              --index-url "$INDEX_URL" --force-reinstall 2>&1 | tail -3
        fi
      else
        echo "  → 无法获取 site-packages 路径"
        return 1
      fi
      ;;
    compute_capability|device_count)
      echo "  → ⚠️  硬件限制，无法自动修复"
      return 1
      ;;
  esac
}

# ========== 主流程 ==========

echo "=== vLLM 环境检查 ==="
echo ""

# 激活环境
conda_activate || { exit 1; }
echo "  python: $(python --version 2>/dev/null || echo '?')"
echo ""

# 执行检查
json_result=$(run_checks 2>&1) || true

# 提取 JSON 部分（run_checks 输出中可能混入 conda 激活的 stdout）
json_clean=$(echo "$json_result" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('{') and 'all_pass' in line:
        print(line)
        sys.exit(0)
" 2>/dev/null || echo '{"all_pass":false,"checks":{},"detail":{}}')

# 格式化输出
echo "--- 诊断结果 ---"
print_results "$json_clean"
echo ""

all_pass=$(get_all_pass "$json_clean")

# 如果全部通过
if [ "$all_pass" = "True" ]; then
  print_summary "$json_clean"
  echo ""
  echo "  环境就绪 ✅"
  exit 0
fi

# 如果有失败
if [ "$FIX_MODE" = false ]; then
  echo "  发现失败项。运行 ./scripts/check_env.sh --fix 尝试自动修复"
  exit 1
fi

# 修复模式
echo "=== 尝试自动修复 ==="
failed_checks=$(echo "$json_clean" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for name, ok in d['checks'].items():
    if not ok:
        print(name)
" 2>/dev/null)

fix_failed=false
for issue in $failed_checks; do
  fix_issue "$issue" || fix_failed=true
done

echo ""

# 修复后重新检查
echo "=== 修复后验证 ==="
json_retry=$(run_checks 2>&1) || true
json_retry_clean=$(echo "$json_retry" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('{') and 'all_pass' in line:
        print(line)
        sys.exit(0)
" 2>/dev/null || echo '{"all_pass":false,"checks":{},"detail":{}}')

print_results "$json_retry_clean"
echo ""

retry_pass=$(get_all_pass "$json_retry_clean")
if [ "$retry_pass" = "True" ]; then
  echo "  修复成功 ✅"
  exit 0
elif [ "$fix_failed" = true ]; then
  echo "  存在不可修复项（硬件限制），其余已尝试修复"
  exit 1
else
  echo "  修复后仍有失败，可能需要手动处理"
  exit 2
fi
