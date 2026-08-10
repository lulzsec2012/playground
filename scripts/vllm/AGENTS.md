# AGENTS.md — vLLM 部署脚本

> Qwen3.6 + Gemma4 模型部署、监控与基准测试脚本集。

---

## 1. Python 环境

### 1.1 专用 venv（必须）

vLLM 需要**干净的 Python 环境**，**不能使用** `flagos/.venv`（其 manta/microbt 自定义 PyTorch 后端会 hook CUDA，干扰 vLLM 的 NVML 设备检测）。

```bash
# 创建 vLLM 专用 venv
python3.12 -m venv /workspace/vllm_deploy/.venv
/workspace/vllm_deploy/.venv/bin/pip install vllm

# 验证
/workspace/vllm_deploy/.venv/bin/python -c "import vllm; print(vllm.__version__)"
```

> vLLM 需与 CUDA 12.x 兼容的 PyTorch，安装时自动拉取。当前版本：**v0.26.0**。

### 1.2 其他脚本的 Python 依赖

| 脚本 | Python 依赖 |
|------|------------|
| `deploy/deploy_models.py` | 标准库 + `ops/kill_gpu` 模块 |
| `ops/kill_gpu.py` | 标准库，无外部依赖 |
| `bench/tune.py` | 调用 `bench/bench_probe.py` + `ops/kill_gpu` |
| `bench/bench_probe.py` | 标准库 |
| `bench_tune.py` | 标准库 |
| `bench_mixapi.py` | 标准库 |
| `bench_mixapi_vs_local.py` | 标准库 |
| `check_env.sh` | Bash，检查 nvidia-smi / vllm / curl |

**除 vLLM 运行时本身外，所有部署管理脚本仅需 Python 标准库。**

---

## 2. 部署架构

```
/workspace/
├── vllm_deploy/
│   ├── .venv/                  ← vLLM 专用干净 Python 环境（必须）
│   ├── models/                 ← 模型权重（git 外，365GB）
│   │   ├── qwen3.6-27b/        ← Qwen3.6-27B (Qwen3_5ForConditionalGeneration)
│   │   ├── gemma4-26b-fp8/     ← Gemma4-26B-FP8
│   │   └── gemma4-26b-mtp-vllm/← Gemma4 MTP speculative model
│   └── logs/                   ← 运行时日志
│       ├── vllm-8002.log
│       └── bench/
│
└── playground/
    └── scripts/vllm/           ← 部署脚本（git 管理）
        ├── deploy/deploy_models.py ← 唯一部署入口
        ├── ops/kill_gpu.py       ← GPU 清理
        ├── bench/tune.py         ← 参数调优
        └── bench/bench_*.py      ← 基准测试
```

---

## 3. 部署命令

```bash
cd /workspace/playground/scripts/vllm

# 一键最优部署 + watchdog 自动重启守护
python deploy/deploy_models.py --quick --watchdog

# 只部署 Qwen TP4
python deploy/deploy_models.py --quick --watchdog --model qwen

# 只部署 Gemma TP2
python deploy/deploy_models.py --quick --watchdog --model gemma

# 交互式多选
python deploy/deploy_models.py

# 管理
python deploy/deploy_models.py status        # 查看状态
python deploy/deploy_models.py stop          # 停止所有
python deploy/deploy_models.py logs 1        # 查看日志

# GPU 清理
python ops/kill_gpu.py --status          # GPU 进程映射
python ops/kill_gpu.py --gpus 0,1,2,3    # 释放指定 GPU
python ops/kill_gpu.py --all             # 释放所有 GPU
```

---

## 4. 已知问题

### 4.1 Zombie GPU VRAM

**症状**：`nvidia-smi` 显示 GPU VRAM 已被占用，但对应 PID 进程已不存在（`[Not Found]`）。GPU 无法使用。

**根因**：vLLM 进程异常退出（kill -9 或被 OOM 杀掉）后，NVIDIA 驱动未释放 CUDA context。

**影响**：zombie GPU 无法用于新部署，`nvidia-smi -r` 也无法重置（报 "In use by another client"）。

**临时方案**：
1. 使用未受影响的 GPU（如 GPU 0-3 zombie → 用 4-7 部署）
2. 重启机器彻底释放 VRAM

**自动化**：`ops/kill_gpu.py --zombie` 可检测 zombie GPU 并尝试 `nvidia-smi drain` 清理（需 root）。

### 4.2 当前 GPU 可用情况

| GPUs | 状态 | 可用 |
|------|------|------|
| 0,1,2,3 | Zombie VRAM (各 ~23GB) | ❌ |
| 4,5,6,7 | 空闲 | ✅ |

**影响**：当前仅能部署 Qwen TP4（需 4 GPU），无法同时部署 Gemma TP2（需要额外 2 GPU）。需重启后恢复全部 8 GPU。

### 4.3 flagos/.venv 冲突

**问题**：本机 `/workspace/flagos/.venv/` 中有 vLLM 包，但带有 microbt/manta 自定义 PyTorch 后端。加载模型时 `vllm.kernels.oink_ops` → `has_device_capability(100)` → NVML 查询失败。

**解决**：必须使用 `/workspace/vllm_deploy/.venv/` 的干净环境。`deploy_models.py` 已将 `VENV_PYTHON` 指向该环境。

---

## 5. 模型信息

| 模型 | 架构 | 参数量 | 量化 | VRAM/GPU (TP4) |
|------|------|--------|------|----------------|
| Qwen3.6-27B | `Qwen3_5ForConditionalGeneration` | 27B | FP8 | ~17.5 GB |
| Gemma4-26B-FP8 | `Gemma4ForConditionalGeneration` | 26B | FP8 | ~23 GB (TP2) |

Qwen3.6 是混合架构（Hybrid: Transformer + Mamba layers），支持 MTP speculative decoding。

---

## 6. Watchdog 自动重启

```bash
python deploy/deploy_models.py --quick --watchdog
```

- 每 30s 健康检查（`GET /v1/models`）
- 连续 3 次失败 → 自动 `kill_port + kill_gpus + deploy_one()`
- 所有事件带时间戳打印
- Ctrl+C 退出 watchdog（服务继续运行）
