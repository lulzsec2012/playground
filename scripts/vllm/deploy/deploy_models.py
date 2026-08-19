#!/usr/bin/env python3
"""deploy_models.py — vLLM 多模型部署管家
=============================
支持四种部署方案、GPU 自动分配（对齐约束）、一键部署最优方案。

GPU 对齐约束:
  - TP2: 起始显卡必须是 2 的整数倍 (0,2,4,6)
  - TP4: 起始显卡必须是 4 的整数倍 (0,4)

用法:
  ./scripts/deploy_models.py                           # 交互式多选部署
  ./scripts/deploy_models.py --quick                   # 一键最优部署 (Qwen TP4 + Gemma TP2)
  ./scripts/deploy_models.py --quick --model qwen      # 只部署 Qwen TP4 最优
  ./scripts/deploy_models.py --quick --model gemma     # 只部署 Gemma TP2 最优
  ./scripts/deploy_models.py --quick --watchdog        # 一键最优 + 自动重启守护
  ./scripts/deploy_models.py status                    # 查看所有部署状态
  ./scripts/deploy_models.py stop                      # 停止所有
  ./scripts/deploy_models.py stop 1,2                  # 停止指定编号的模型
  ./scripts/deploy_models.py logs 1                    # 查看模型 1 的日志
  ./scripts/deploy_models.py list                      # 列出可用模型配置

最优部署方案 (--quick):
  ┌────────┬──────────────────┬──────┬───────┬─────────┐
  │ GPU    │ 模型             │ TP   │ 端口  │ Score   │
  ├────────┼──────────────────┼──────┼───────┼─────────┤
  │ 0-3    │ Qwen3.6-27B      │ TP4  │ 8002  │ 90.7    │
  │ 4-5    │ Gemma4-26B-FP8   │ TP2  │ 8005  │ 96.2    │
  │ 6-7    │ (空闲)           │ —    │ —     │ —       │
  └────────┴──────────────────┴──────┴───────┴─────────┘
"""

import os, sys, json, time, signal, subprocess, re, argparse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent  # playground/scripts/vllm/deploy/
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent.parent  # /workspace/
VLLM_DEPLOY_DIR = WORKSPACE_ROOT / "vllm_deploy"  # /workspace/vllm_deploy/

# 自动创建 vllm_deploy 目录结构
VLLM_DEPLOY_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR = VLLM_DEPLOY_DIR / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)
(VLLM_DEPLOY_DIR / "models").mkdir(parents=True, exist_ok=True)

# vLLM 需要干净的 Python 环境（不能使用 flagos/.venv，其 manta 后端会干扰 NVML）
VENV_PYTHON = "/workspace/vllm_deploy/.venv/bin/python"

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ops")
)
from kill_gpu import kill_gpus, kill_port

TOTAL_GPUS = 8

# ── 模型定义 ──────────────────────────────────────────────────────────
MODELS = [
    {
        "id": 1,
        "name": "Qwen3.6-27B TP4",
        "model": str(VLLM_DEPLOY_DIR / "models/qwen3.6-27b"),
        "tp": 4,
        "mem": 0.93,
        "mml": 262144,
        "bt": 8192,
        "seqs": 10,
        "kv_dtype": "int8_per_token_head",
        "prefetch": True,
        "o3": True,
        "block_size": 32,  # A7 优化: block32 提升 ▲1.4
        "mtp": 5,
        "extra_args": [
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "qwen3_coder",
            "--language-model-only",
        ],
        "desc": "TP4 最优 (block32 + MTP5 + int8kv, Score 90.7)",
    },
    {
        "id": 2,
        "name": "Qwen3.6-27B TP2",
        "model": str(VLLM_DEPLOY_DIR / "models/qwen3.6-27b"),
        "tp": 2,
        "mem": 0.93,
        "mml": 131072,
        "bt": 8192,
        "seqs": 10,
        "kv_dtype": "int8_per_token_head",
        "prefetch": True,
        "o3": True,
        "mtp": 5,
        "extra_args": [
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "qwen3_coder",
            "--language-model-only",
        ],
        "desc": "TP2 最优 (MTP5 + seqs10, Score 76.4)",
    },
    {
        "id": 3,
        "name": "Gemma4-26B-FP8 TP2",
        "model": str(VLLM_DEPLOY_DIR / "models/gemma4-26b-fp8"),
        "spec_model": str(VLLM_DEPLOY_DIR / "models/gemma4-26b-mtp-vllm"),
        "tp": 2,
        "mem": 0.90,
        "mml": 262144,
        "bt": 8192,
        "seqs": 4,
        "kv_dtype": "fp8",
        "prefetch": True,
        "o3": True,
        "chunked": True,  # C10 优化: mem=0.90, seqs=4 → Score 96.2
        "spec_tokens": 4,
        "extra_args": [
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "gemma4",
        ],
        "desc": "TP2 最优 (mem90 + seqs4, Score 96.2)",
    },
    {
        "id": 4,
        "name": "Gemma4-26B-FP8 TP4",
        "model": str(VLLM_DEPLOY_DIR / "models/gemma4-26b-fp8"),
        "spec_model": str(VLLM_DEPLOY_DIR / "models/gemma4-26b-mtp-vllm"),
        "tp": 4,
        "mem": 0.93,
        "mml": 262144,
        "bt": 32768,
        "seqs": 20,
        "kv_dtype": "fp8",
        "prefetch": True,
        "o3": True,
        "chunked": False,  # D3 优化: seqs=20, bt=32k → Score 97.8
        "spec_tokens": 4,
        "extra_args": [
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "gemma4",
        ],
        "desc": "TP4 最优 (seqs20 + bt32k, Score 97.8)",
    },
    {
        "id": 5,
        "name": "Qwen3.8-27B FP8 TP4",
        "model": str(VLLM_DEPLOY_DIR / "models/qwen3.8-27b-fp8"),
        "tp": 4,
        "mem": 0.93,
        "mml": 262144,
        "bt": 8192,
        "seqs": 20,
        "kv_dtype": "int8_per_token_head",
        "prefetch": True,
        "o3": True,
        "block_size": 32,  # 3.6 TP4 同款优化
        "mtp": 3,
        "extra_args": [
            "--reasoning-parser",
            "qwen3",
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "qwen3_coder",
            "--language-model-only",
        ],
        "desc": "TP4 最优 (MTP3 + rp + block32 + seqs20, Score 70.6)",
    },
]

# 端口默认分配 (可动态调整防冲突)
DEFAULT_PORTS = {1: 8002, 2: 8004, 3: 8005, 4: 8006, 5: 8007}


# ── GPU 分配 ───────────────────────────────────────────────────────────
def allocate_gpus(selected_ids, free_gpus=None):
    """为选择的模型分配 GPU，返回 {model_id: [gpu_indices], ...}

    参数:
      selected_ids: 选中的模型 ID 集合
      free_gpus: 可用 GPU 列表，None 表示全部可用

    规则:
      - TP4 起始必须是 4 的倍数
      - TP2 起始必须是 2 的倍数
      - 不可重叠
      - 大 TP 优先分配
    """
    if free_gpus is None:
        free_gpus = list(range(TOTAL_GPUS))

    selected = [m for m in MODELS if m["id"] in selected_ids]
    selected.sort(key=lambda m: -m["tp"])  # TP4 优先

    allocated_physical = set()
    result = {}
    ports_used = set()
    free_set = set(free_gpus)

    for model in selected:
        mid = model["id"]
        tp = model["tp"]
        step = tp

        found = False
        for start in range(0, TOTAL_GPUS, step):
            gpu_set = set(range(start, start + tp))
            if gpu_set.issubset(free_set) and gpu_set.isdisjoint(allocated_physical):
                result[mid] = sorted(gpu_set)
                allocated_physical |= gpu_set
                found = True
                break

        if not found:
            used_gpus = sorted(allocated_physical)
            remain = sorted(free_set - allocated_physical)
            print(f"  ❌ {model['name']}: 无法分配 {tp} 张对齐空闲 GPU")
            print(f"     已用: {used_gpus}, 剩余空闲: {remain}")
            return None

        # 分配端口 (防冲突)
        port = DEFAULT_PORTS.get(mid, 8001)
        while port in ports_used:
            port += 1
        result[f"port_{mid}"] = port
        ports_used.add(port)

    return result


# ── 构建 vLLM 参数 ────────────────────────────────────────────────────
def build_vllm_args(model, gpu_indices, port):
    """构建 vLLM 启动参数列表 (Popen 安全, 无 shell)"""
    args = [
        str(VENV_PYTHON),
        "-m",
        "vllm.entrypoints.openai.api_server",
        "--model",
        model["model"],
        "--served-model-name",
        model["name"].split(" ")[0].lower(),
        "--port",
        str(port),
        "--host",
        "0.0.0.0",
        "--tensor-parallel-size",
        str(model["tp"]),
        "--dtype",
        "auto",
        "--gpu-memory-utilization",
        str(model["mem"]),
        "--max-model-len",
        str(model["mml"]),
        "--max-num-batched-tokens",
        str(model["bt"]),
        "--max-num-seqs",
        str(model["seqs"]),
        "--no-enforce-eager",
        "--kv-cache-dtype",
        model["kv_dtype"],
    ]

    # prefix-caching
    if model.get("prefetch", True):
        args.append("--enable-prefix-caching")
    else:
        args.append("--no-enable-prefix-caching")

    # block-size (Qwen TP4 优化)
    if model.get("block_size"):
        args += ["--block-size", str(model["block_size"])]

    # Qwen 专有参数
    if "qwen" in model["name"].lower():
        if model.get("mtp", 0) > 0:
            args += [
                "--speculative-config",
                '{"method":"mtp","num_speculative_tokens":%d}' % model["mtp"],
            ]

    # Gemma 专有参数
    if "gemma" in model["name"].lower():
        spec = model.get("spec_model", "")
        if model.get("spec_tokens", 0) > 0 and spec:
            args += ["--spec-model", spec, "--spec-tokens", str(model["spec_tokens"])]
        if model.get("chunked", False):
            args.append("--enable-chunked-prefill")
        else:
            args.append("--no-enable-chunked-prefill")

    # 额外参数
    args += model.get("extra_args", [])

    if model.get("o3", True):
        args.append("-O3")

    return args


# ── 模型自动下载 ──────────────────────────────────────────────────────
# 模型目录名 → HuggingFace Model ID
MODEL_HF_MAP = {
    "qwen3.6-27b": "Qwen/Qwen3.6-27B",
    "gemma4-26b-fp8": "google/gemma-4-26b-it-FP8",
    "gemma4-26b-mtp-vllm": "google/gemma-4-26b-it-MTP",
    "qwen3.8-27b-fp8": "Qwen/Qwen3.8-27B-FP8",
}

# 模型目录名 → ModelScope Model ID (国内下载优先)
MODEL_MS_MAP = {
    "qwen3.6-27b": "Qwen/Qwen3.6-27B",
    "qwen3.8-27b-fp8": "Qwen/Qwen3.8-27B-FP8",
}


def ensure_model(model_path: str):
    """确保模型目录存在，不存在则自动从 HuggingFace 下载。

    优先检测旧目录 (/workspace/vllm_deploy/models/) 中是否已有模型，
    若有则自动创建符号链接避免重复下载。
    """
    path = Path(model_path)
    model_name = path.name
    if path.is_dir():
        return True  # 已存在

    # 检测旧部署目录是否有该模型
    old_path = Path("/workspace/vllm_deploy/models") / model_name
    if old_path.is_dir():
        print(f"  发现已有模型: {old_path}")
        print(f"  → 创建符号链接到 {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(old_path.resolve())
        return True

    # 从 ModelScope 下载 (国内直连优先, HF 直连常不可用)
    ms_id = MODEL_MS_MAP.get(model_name)
    if ms_id:
        try:
            from modelscope import snapshot_download

            print(f"\n  📥 下载模型 {ms_id} → {path} (ModelScope)")
            path.parent.mkdir(parents=True, exist_ok=True)
            snapshot_download(ms_id, local_dir=str(path))
            print(f"     ✅ 下载完成: {path}")
            return True
        except ImportError:
            print("     modelscope 不可用，回退 HuggingFace...")
        except Exception as e:
            print(f"     ❌ ModelScope 下载失败: {e}")
            print("     回退 HuggingFace...")

    # 从 HuggingFace 下载
    hf_id = MODEL_HF_MAP.get(model_name)
    if not hf_id:
        print(f"  ❌ 未知模型 '{model_name}'，无法自动下载。请手动放置到 {path}")
        print(f"     已知模型: {list(MODEL_HF_MAP.keys())}")
        return False

    print(f"\n  📥 下载模型 {hf_id} → {path}")
    print(f"     (大模型下载需要一段时间...)")
    path.parent.mkdir(parents=True, exist_ok=True)

    try:
        from huggingface_hub import snapshot_download

        snapshot_download(
            hf_id,
            local_dir=str(path),
            local_dir_use_symlinks=False,
            resume_download=True,
        )
        print(f"     ✅ 下载完成: {path}")
        return True
    except ImportError:
        print("     huggingface_hub 未安装，尝试 huggingface-cli...")
        result = subprocess.run(
            [
                "huggingface-cli",
                "download",
                hf_id,
                "--local-dir",
                str(path),
                "--resume-download",
            ],
            capture_output=False,
            timeout=3600,
        )
        if result.returncode == 0:
            print(f"     ✅ 下载完成: {path}")
            return True
        print(
            f"     ❌ 下载失败，请手动下载: huggingface-cli download {hf_id} --local-dir {path}"
        )
        return False


# ── 部署 ───────────────────────────────────────────────────────────────
def deploy_one(model, gpu_indices, port):
    """启动单个 vLLM 实例"""
    mid = model["id"]
    gpu_str = ",".join(map(str, gpu_indices))
    model_name = model["name"]

    # 确保模型已下载
    if not ensure_model(model["model"]):
        print(f"  ❌ 模型 '{model_name}' 不可用，跳过部署")
        return None, None
    if model.get("spec_model"):
        if not ensure_model(model["spec_model"]):
            print(f"  ⚠️  speculative model 不可用，将禁用 MTP")
            model = model.copy()
            model["spec_model"] = None
            model["spec_tokens"] = 0

    args = build_vllm_args(model, gpu_indices, port)

    log_file = str(LOG_DIR / f"vllm-{port}.log")
    env = os.environ.copy()
    env["CUDA_VISIBLE_DEVICES"] = gpu_str

    # 先清理 GPU
    kill_gpus(gpu_str)
    time.sleep(2)

    print(f"\n  🚀 启动 {model_name}")
    print(f"     GPU: {gpu_str} | 端口: {port} | TP: {model['tp']}")
    print(f"     Log: {log_file}")

    with open(log_file, "w") as f:
        proc = subprocess.Popen(
            args,
            cwd="/tmp",
            env=env,
            stdout=f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    print(f"     PID: {proc.pid}")
    return proc.pid, log_file


def wait_for_server(port, timeout=360):
    """等待 vLLM 服务就绪 (urllib + requests 双保险)"""
    import urllib.request

    t0 = time.time()
    last_err = ""
    while time.time() - t0 < timeout:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/models")
            with urllib.request.urlopen(req, timeout=5) as resp:
                if resp.status == 200:
                    return int(time.time() - t0)
        except Exception as e:
            last_err = str(e)[:60]
        # Fallback: requests
        try:
            import requests

            r = requests.get(f"http://127.0.0.1:{port}/v1/models", timeout=5)
            if r.status_code == 200:
                return int(time.time() - t0)
        except Exception:
            pass
        time.sleep(5)
    if last_err:
        import sys

        sys.stderr.write(f"  (最后错误: {last_err})")
    return None


# ── 交互式菜单 ─────────────────────────────────────────────────────────
def interactive_menu():
    """显示交互式多选菜单"""
    print("\n" + "=" * 60)
    print("  vLLM 多模型部署管家")
    print("=" * 60)
    print("\n可用部署方案:")
    print(f"  {'编号':<6} {'模型':<26} {'TP':<4} {'说明'}")
    print(f"  {'-' * 4:<6} {'-' * 24:<26} {'-' * 3:<4} {'-' * 30}")
    avail_gpus = detect_free_gpus()
    for m in MODELS:
        print(f"  {m['id']:<6} {m['name']:<26} TP{m['tp']:<3} {m['desc']}")

    print(
        f"\n可用 GPU: {len(avail_gpus)} 张 ({', '.join(map(str, avail_gpus))})"
        if avail_gpus
        else "\n⚠️  无可用 GPU"
    )
    if len(avail_gpus) < TOTAL_GPUS:
        stuck = set(range(TOTAL_GPUS)) - set(avail_gpus)
        print(f"  ({len(stuck)} 张被占用: {sorted(stuck)})")

    print("\n支持组合部署 (多选):")
    print("  例: 1         → 仅部署 Qwen TP4")
    print("  例: 1,3       → Qwen TP4 + Gemma TP2")
    print("  例: 1,2,3,4   → 全部部署 (需 12 张 GPU，8 张不够)")
    print("  例: 3,4       → Gemma TP2 + Gemma TP4 (需 6 张 GPU)")

    while True:
        try:
            inp = input("\n请输入编号 (逗号/空格分隔, 或 q 退出): ").strip()
            if inp.lower() in ("q", "quit", "exit"):
                print(" 已取消")
                return None

            # 解析输入
            ids = set()
            for part in re.split(r"[,\s]+", inp):
                part = part.strip()
                if not part:
                    continue
                if "-" in part:
                    a, b = part.split("-", 1)
                    ids.update(range(int(a), int(b) + 1))
                else:
                    ids.add(int(part))

            valid_ids = {m["id"] for m in MODELS}
            if not ids.issubset(valid_ids):
                print(f"  ❌ 无效编号: {ids - valid_ids}，可选 {sorted(valid_ids)}")
                continue
            if not ids:
                print("  ❌ 请至少选择一个")
                continue
            return ids

        except (ValueError, EOFError, KeyboardInterrupt):
            print(" 已取消")
            return None


def detect_free_gpus():
    """检测空闲 GPU (显存使用 < 100 MiB)"""
    try:
        r = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=index,memory.used",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        free = []
        for line in r.stdout.strip().split("\n"):
            parts = line.split(", ")
            if len(parts) == 2:
                idx = int(parts[0].strip())
                mem = int(parts[1].strip())
                if mem < 100:
                    free.append(idx)
        return free
    except Exception:
        return list(range(TOTAL_GPUS))


def verify_allocation(alloc, selected_ids):
    """验证分配是否符合对齐约束"""
    for mid in selected_ids:
        model = next(m for m in MODELS if m["id"] == mid)
        gpus = alloc[mid]
        tp = model["tp"]
        start = gpus[0]
        if start % tp != 0:
            print(f"  ⚠️  {model['name']}: 起始 GPU {start} 不满足 TP{tp} 对齐!")
            return False
        if gpus != list(range(start, start + tp)):
            print(f"  ⚠️  {model['name']}: GPU {gpus} 不连续!")
            return False
    return True


# ── 命令行动作 ─────────────────────────────────────────────────────────


def cmd_list():
    """列出可用模型"""
    print(f"\n{'编号':<6} {'模型':<26} {'TP':<4} {'端口':<6} {'说明'}")
    print(f"{'-' * 4:<6} {'-' * 24:<26} {'-' * 3:<4} {'-' * 5:<6} {'-' * 30}")
    for m in MODELS:
        port = DEFAULT_PORTS.get(m["id"], "?")
        print(f"{m['id']:<6} {m['name']:<26} TP{m['tp']:<3} {port:<6} {m['desc']}")


def cmd_status():
    """查看所有部署状态"""
    print("\n" + "=" * 60)
    print("  部署状态")
    print("=" * 60)

    # 查进程
    try:
        r = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=10)
        vllm_procs = []
        for line in r.stdout.split("\n"):
            if "vllm.entrypoints" in line and "grep" not in line:
                vllm_procs.append(line)

        if not vllm_procs:
            print("  📭 没有正在运行的 vLLM 服务")
        else:
            print(f"\n  📡 运行中的 vLLM ({len(vllm_procs)}):")
            for line in vllm_procs:
                parts = line.split(None, 10)
                pid = parts[1] if len(parts) > 1 else "?"
                # 提取端口
                port_match = re.search(r"--port (\d+)", line)
                port = port_match.group(1) if port_match else "?"
                # 提取模型
                model_match = re.search(r"--served-model-name (\S+)", line)
                model = model_match.group(1) if model_match else "?"
                # 提取 GPU
                gpu_match = re.search(r"CUDA_VISIBLE_DEVICES=(\S+)", line)
                gpu = gpu_match.group(1) if gpu_match else "?"
                print(f"     PID {pid:<7} | 端口 {port:<5} | GPU {gpu:<8} | {model}")
    except Exception as e:
        print(f"  ⚠️ 状态查询失败: {e}")

    # 查 GPU
    try:
        r = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=index,memory.used,memory.total",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        print(f"\n  🎮 GPU 状态:")
        for line in r.stdout.strip().split("\n"):
            parts = line.split(", ")
            if len(parts) == 3:
                idx, used, total = parts
                pct = int(used) / int(total) * 100 if int(total) > 0 else 0
                bar = "█" * int(pct / 5) + "░" * (20 - int(pct / 5))
                print(f"     GPU {idx}: {bar} {used:>6}/{total} MiB ({pct:.0f}%)")
    except Exception:
        pass


def cmd_stop(selected_ids=None):
    """停止部署"""
    if selected_ids:
        for mid in selected_ids:
            model = next(m for m in MODELS if m["id"] == mid)
            # 查找对应进程
            port = DEFAULT_PORTS.get(mid)
            if port:
                print(f"  正在停止 {model['name']} (port {port})...")
                kill_port(port)
        return

    # 停止所有
    print("\n  正在停止所有 vLLM 服务...")
    kill_gpus("0,1,2,3,4,5,6,7")
    print("  ✅ 已停止")


def cmd_logs(mid):
    """查看日志"""
    model = next((m for m in MODELS if m["id"] == mid), None)
    if not model:
        print(f"  ❌ 无效编号: {mid}")
        return
    port = DEFAULT_PORTS.get(mid, 8001)
    log_file = LOG_DIR / f"vllm-{port}.log"
    if not log_file.exists():
        print(f"  📭 日志文件不存在: {log_file}")
        return
    try:
        subprocess.run(["tail", "-f", str(log_file)])
    except KeyboardInterrupt:
        pass


# ── 最优部署方案 ─────────────────────────────────────────────────────
# ── Watchdog 自动重启 ──────────────────────────────────────────────────
def run_watchdog(deployed):
    """监控已部署的服务，掉线自动重启。

    deployed: [(model, gpu_indices, port), ...]
    每 30s 健康检查，连续 3 次失败后自动重启。
    """
    import urllib.request
    from datetime import datetime

    def log_wd(msg):
        ts = datetime.now().strftime("%H:%M:%S")
        print(f"  [{ts}] 📡 {msg}")

    # 失败计数器: port → consecutive_failures
    fail_count = {item[2]: 0 for item in deployed}
    restart_count = {item[2]: 0 for item in deployed}

    print("\n" + "=" * 60)
    print("  🐕 Watchdog 启动 — 每 30s 健康检查，连续 3 次失败自动重启")
    print("     按 Ctrl+C 停止 watchdog")
    print("=" * 60)

    for model, gpus, port in deployed:
        log_wd(f"监控 {model['name']} (port {port}, GPU {gpus})")

    try:
        while True:
            time.sleep(30)

            for model, gpus, port in deployed:
                # 健康检查
                ok = False
                try:
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/models")
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        ok = resp.status == 200
                except Exception:
                    pass

                if ok:
                    if fail_count[port] > 0:
                        log_wd(f"{model['name']} (port {port}) 已恢复 ✅")
                    fail_count[port] = 0
                    continue

                fail_count[port] += 1
                log_wd(f"{model['name']} (port {port}) 无响应 ({fail_count[port]}/3)")

                if fail_count[port] >= 3:
                    restart_count[port] += 1
                    nth = restart_count[port]
                    log_wd(f"🔄 重启 {model['name']} (port {port}) — 第 {nth} 次")

                    # 杀掉旧进程
                    kill_port(port)
                    kill_gpus(",".join(map(str, gpus)))
                    time.sleep(3)

                    # 重新部署
                    pid, _ = deploy_one(model, gpus, port)
                    if pid:
                        log_wd(f"  新 PID: {pid}")
                        elapsed = wait_for_server(port, timeout=300)
                        if elapsed is not None:
                            log_wd(f"  {model['name']} 重启成功 ✅ ({elapsed}s)")
                            fail_count[port] = 0
                        else:
                            log_wd(f"  {model['name']} 重启超时 ❌，下次继续监控")
                            fail_count[port] = 0  # 重置计数，避免循环
                    else:
                        log_wd(f"  {model['name']} 启动失败 ❌")
                        fail_count[port] = 0

    except KeyboardInterrupt:
        print("\n\n  🛑 Watchdog 已停止 (服务仍在运行)")
        print("     停止服务: ./deploy_models.py stop")


# ── Watchdog ──────────────────────────────────────────────────────────────
OPTIMAL_QUICK = {
    "all": {1, 3},  # Qwen TP4 + Gemma TP2
    "qwen": {1},
    "gemma": {3},
    "qwen38": {5},  # Qwen3.8-27B FP8 TP4 (GPU 4-7)
}


def deploy_quick(model_target="all"):
    """--quick 模式：跳过交互，直接部署最优方案"""
    if model_target not in OPTIMAL_QUICK:
        print(f"  ❌ 无效模型: {model_target} (可选: qwen, gemma, all)")
        sys.exit(1)

    selected_ids = OPTIMAL_QUICK[model_target]
    selected = [m for m in MODELS if m["id"] in selected_ids]

    print("\n" + "=" * 60)
    print("  ⚡ 快速最优部署")
    print("=" * 60)
    for m in selected:
        print(f"  [{m['id']}] {m['name']} — {m['desc']}")
    print()

    return selected_ids


# ── 主入口 ─────────────────────────────────────────────────────────────
def main():
    import requests

    # 先检查是否有 --quick / --watchdog 标志（argparse 会把它当 action 处理，需要手动解析）
    has_quick = "--quick" in sys.argv
    has_watchdog = "--watchdog" in sys.argv
    model_target = "all"

    if has_quick:
        sys.argv.remove("--quick")
    if has_watchdog:
        sys.argv.remove("--watchdog")

    if has_quick:
        # 提取 --model 参数
        try:
            mi = sys.argv.index("--model")
            model_target = sys.argv[mi + 1]
            sys.argv.pop(mi)  # remove --model value
            sys.argv.pop(mi)  # remove --model flag
        except ValueError:
            pass

    p = argparse.ArgumentParser(description="vLLM 多模型部署管家")
    p.add_argument(
        "action", nargs="?", default="menu", help="menu|list|status|stop|logs"
    )
    p.add_argument("args", nargs="*", help="额外参数 (如模型编号)")
    args = p.parse_args()

    action = args.action
    extra = args.args

    # --quick 模式下跳过菜单，直接部署
    if has_quick:
        if action not in ("menu",):
            print(f"  ⚠️  --quick 模式下忽略子命令: {action}")
        selected_ids = deploy_quick(model_target)
        # fall through to deployment logic below
    elif action == "list":
        cmd_list()
        return
    elif action == "status":
        cmd_status()
        return
    elif action == "stop":
        ids = None
        if extra:
            try:
                ids = set()
                for part in re.split(r"[,\s]+", extra[0]):
                    part = part.strip()
                    if "-" in part:
                        a, b = part.split("-", 1)
                        ids.update(range(int(a), int(b) + 1))
                    else:
                        ids.add(int(part))
            except ValueError:
                pass
        cmd_stop(ids)
        return
    elif action == "logs":
        if extra:
            try:
                cmd_logs(int(extra[0]))
            except ValueError:
                print(f"  ❌ 无效编号: {extra[0]}")
        else:
            print("  用法: deploy_models.py logs <编号>")
            cmd_list()
        return
    elif action == "menu":
        selected_ids = interactive_menu()
        if not selected_ids:
            return
    else:
        # 支持 "1,3" 或 "1 3" 格式
        if extra:
            ids_str = action + "," + ",".join(extra)
        else:
            ids_str = action
        try:
            selected_ids = set()
            for part in re.split(r"[,\s]+", ids_str):
                part = part.strip()
                if not part:
                    continue
                if "-" in part:
                    a, b = part.split("-", 1)
                    selected_ids.update(range(int(a), int(b) + 1))
                else:
                    selected_ids.add(int(part))
        except ValueError:
            print(f"  未知动作: {action}")
            print("  用法: deploy_models.py {menu|list|status|stop|logs}")
            return

    # ── 执行部署 ───────────────────────────────────────────────────────────
    print("\n" + "=" * 60)
    print("  检测空闲 GPU...")
    free_gpus = detect_free_gpus()
    print(f"    空闲 GPU: {len(free_gpus)} 张 {free_gpus}")
    if not free_gpus:
        print("  ❌ 无可用 GPU，退出")
        sys.exit(1)

    print("  分配 GPU...")
    alloc = allocate_gpus(selected_ids, free_gpus=free_gpus)
    if alloc is None:
        print("\n  ❌ GPU 分配失败，请减少部署数量或释放 GPU")
        sys.exit(1)

    # 验证对齐
    if not verify_allocation(alloc, selected_ids):
        print("\n  ❌ GPU 分配不满足对齐约束")
        sys.exit(1)

    # 显示部署计划
    print("\n" + "=" * 60)
    print("  📋 部署计划")
    print("=" * 60)
    total_gpu_needed = 0
    for mid in sorted(selected_ids):
        model = next(m for m in MODELS if m["id"] == mid)
        gpus = alloc[mid]
        port = alloc[f"port_{mid}"]
        desc = model["desc"]
        print(
            f"  [{mid}] {model['name']:<24} GPU {str(gpus):<12} 端口 {port:<5}  {desc}"
        )
        total_gpu_needed += len(gpus)
    print(f"\n  共需 {total_gpu_needed}/{TOTAL_GPUS} 张 GPU")

    # 确认
    confirm = input("\n确认部署? (Y/n): ").strip().lower()
    if confirm not in ("", "y", "yes"):
        print(" 已取消")
        return

    # 执行部署
    print("\n" + "=" * 60)
    print("  🚀 开始部署...")
    print("=" * 60)

    pids = {}
    for mid in sorted(selected_ids):
        model = next(m for m in MODELS if m["id"] == mid)
        gpus = alloc[mid]
        port = alloc[f"port_{mid}"]
        pid, log_file = deploy_one(model, gpus, port)
        pids[mid] = pid

    print("\n" + "=" * 60)
    print("  ⏳ 等待服务就绪...")
    print("=" * 60)

    all_ready = True
    for mid in sorted(selected_ids):
        model = next(m for m in MODELS if m["id"] == mid)
        port = alloc[f"port_{mid}"]
        print(f"  [{mid}] {model['name']} (port {port})...", end=" ")
        sys.stdout.flush()
        elapsed = wait_for_server(port, 360)
        if elapsed is not None:
            print(f"✅ {elapsed}s")
        else:
            print(f"❌ 超时 360s")
            all_ready = False

    print("\n" + "=" * 60)
    if all_ready:
        print("  ✅ 全部部署就绪!")
    else:
        print("  ⚠️  部分服务未就绪，请检查日志")
    print("=" * 60)
    print("\n  查看状态:  ./deploy_models.py status")
    print("  查看日志:  ./deploy_models.py logs <编号>")
    print("  停止服务:  ./deploy_models.py stop")
    print()

    # ── Watchdog 模式 ───────────────────────────────────────────────────────
    if has_watchdog and all_ready:
        deployed = []
        for mid in sorted(selected_ids):
            model = next(m for m in MODELS if m["id"] == mid)
            gpus = alloc[mid]
            port = alloc[f"port_{mid}"]
            deployed.append((model, gpus, port))
        run_watchdog(deployed)
    elif has_watchdog:
        print("  ⚠️  watchdog 未启动：部分服务未就绪")
        print()


if __name__ == "__main__":
    main()
