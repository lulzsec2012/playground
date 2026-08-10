#!/usr/bin/env python3
"""
================================================================================
全模型基准测试脚本 — 为 opencode 单用户编程场景优化
================================================================================

测试三个模型:
  1. Gemma4-26B + MTP (26B MoE, BF16, 需加载完整模型+MT辅助模型做投机解码)
  2. Qwen3.6-27B (27B, FP8, built-in MTP head)
  3. Qwen3-Coder-Next-FP8 (79B, FP8, 纯量化模型)

目标:
  - 为每个模型寻找针对 单用户交互编程 场景的最佳配置
  - 扫描 TP 大小、CUDA Graph、Chunked Prefill、Batch Size 等维度
  - 输出详细结果表格 (CSV + Markdown + JSON)

用法:
   python scripts/bench_tune.py              # 测试全部三个模型
   python scripts/bench_tune.py --quick        # 快速扫描
   python scripts/bench_tune.py --models gemma4
   python scripts/bench_tune.py --models qwen3.6 qwen3-coder
   python scripts/bench_tune.py --no-download
   python scripts/bench_tune.py --dry-run      # 只打印计划, 不加载模型

环境要求:
  - conda env: dev312 (或通过 --python 指定)
  - vLLM >= 0.21.0
  - 8x RTX 4090 (24GB)
================================================================================
"""

import os, sys, time, json, gc, itertools, subprocess, copy, threading
from pathlib import Path
from datetime import datetime
from typing import Optional, Any

# ====== 环境检查 ======
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent  # /workspace/
VLLM_DEPLOY_DIR = WORKSPACE_ROOT / "vllm_deploy"
# Python 二进制：环境变量 VLLM_PYTHON 优先，其次当前解释器（如果在 dev312 中），最后 CONDA_PREFIX 推断
DEFAULT_PYTHON = (
    os.environ.get("VLLM_PYTHON")
    or (sys.executable if "dev312" in (sys.executable or "") else "")
    or str(Path(os.environ.get("CONDA_PREFIX", "")) / "bin" / "python")
)

# 检查 Python 环境
_in_dev312 = "dev312" in sys.executable if hasattr(sys, "executable") else False
if not _in_dev312:
    print(f"[WARN] 建议使用 dev312 环境 (via VLLM_PYTHON env var)")
    print(f"[WARN] 当前: {sys.executable}")

# 检查 vLLM
try:
    import vllm

    _vllm_ver = getattr(vllm, "__version__", "unknown")
    print(f"[INFO] vLLM {_vllm_ver} 已加载 (路径: {vllm.__file__})")
except ImportError:
    print(f"[ERROR] vLLM 未安装! 请使用 conda dev312 环境")
    sys.exit(1)


# ====================================================================
# GPU 显存清理
# ====================================================================
def cleanup_gpu_memory():
    """清理 GPU 残留显存: 杀死残留进程 + 切换 persistence mode."""
    log("清理 GPU 残留进程和显存...")
    # 1. 杀死 vLLM 残留子进程
    for pattern in ["vllm_worker", "engine_core", "ray::"]:
        try:
            subprocess.run(
                ["pkill", "-9", "-f", pattern], capture_output=True, timeout=5
            )
        except Exception:
            pass
    # 2. 从 nvidia-smi 获取持有 GPU 显存的进程并 kill -9
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-compute-apps=pid,used_memory",
                "--format=csv,noheader",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            parts = line.split(",")
            pid = parts[0].strip()
            try:
                os.kill(int(pid), 9)
            except Exception:
                pass
    except Exception:
        pass
    # 3. 切换 persistence mode 触发 driver 释放僵尸显存
    try:
        for i in range(N_GPUS):
            subprocess.run(
                ["nvidia-smi", "-i", str(i), "-pm", "0"], capture_output=True, timeout=5
            )
    except Exception:
        pass
    # 4. 等待释放
    time.sleep(3)
    # 5. 打印最终显存状态
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=index,memory.used,memory.total",
                "--format=csv,noheader",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        for line in result.stdout.strip().split("\n"):
            if line.strip():
                log(f"  GPU {line.strip()}")
    except Exception:
        pass
    log("GPU 清理完成")


# ====================================================================
# 全局常量
# ====================================================================
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent  # /workspace/
VLLM_DEPLOY_DIR = WORKSPACE_ROOT / "vllm_deploy"
MODELS_DIR = VLLM_DEPLOY_DIR / "models"
DEFAULT_PYTHON = (
    os.environ.get("VLLM_PYTHON")
    or (sys.executable if "dev312" in (sys.executable or "") else "")
    or str(
        Path(os.environ.get("CONDA_PREFIX", "/workspace/miniconda3/envs/dev312"))
        / "bin"
        / "python"
    )
)

MODEL_PATHS = {
    "gemma4": {
        "main": MODELS_DIR / "gemma4-26b",
        "main_fp8": MODELS_DIR / "gemma4-26b-fp8",
        "mtp_draft": MODELS_DIR / "gemma4-26b-mtp-vllm",
        "mtp_original": MODELS_DIR / "gemma4-26b-mtp",
        "hf_id_fp8": "RedHatAI/gemma-4-26B-A4B-it-FP8-Dynamic",
        "hf_id": "google/gemma-4-26b-it",
        "hf_id_mtp": "google/gemma-4-26b-it-mtp",
        "label": "Gemma4-26B",
    },
    "qwen3.6": {
        "main": MODELS_DIR / "qwen3.6-27b",
        "hf_id": "Qwen/Qwen3.6-27B",
        "label": "Qwen3.6-27B",
    },
    "qwen3-coder": {
        "main": MODELS_DIR / "qwen3-coder-next-fp8",
        "hf_id": "Qwen/Qwen3-Coder-Next-FP8",
        "label": "Qwen3-Coder-Next-FP8",
    },
}

# 测试用 prompts（编程场景）
CODE_PROMPT = "Write a Python function that implements a binary search tree with insert, delete, and search operations."
SHORT_PROMPT = "What is the capital of France?"
LONG_CONTEXT_PROMPT = (
    "Explain the Linux kernel's memory management: virtual memory, page tables, swap, OOM killer. "
    * 20
)  # ~200+ tokens

# 输出目录 (统一 logs/bench/)
OUTPUT_DIR = VLLM_DEPLOY_DIR / "logs" / "bench"

# 显卡信息
N_GPUS = 8  # 8× RTX 4090 (固定值, 因为 nvidia-smi 可能在导入时未就绪)
GPU_NAME = "RTX 4090"
GPU_MEM_GB = 24


# ====================================================================
# 工具函数
# ====================================================================


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}][{level}] {msg}", flush=True)


def get_gpu_info() -> list[dict]:
    """获取 GPU 信息 (名称、显存总量/已用)."""
    import subprocess

    try:
        out = (
            subprocess.check_output(
                [
                    "nvidia-smi",
                    "--query-gpu=index,name,memory.total,memory.used,memory.free",
                    "--format=csv,noheader,nounits",
                ],
                timeout=10,
            )
            .decode()
            .strip()
            .split("\n")
        )
        gpus = []
        for line in out:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                gpus.append(
                    {
                        "index": int(parts[0]),
                        "name": parts[1],
                        "memory_total_mb": int(parts[2]),
                        "memory_used_mb": int(parts[3]),
                        "memory_free_mb": int(parts[4]),
                    }
                )
        return gpus
    except Exception:
        return []


def check_model_disk_size(model_dir: Path) -> tuple[int, int]:
    """返回 (safetensors文件数, 总大小bytes)."""
    if not model_dir.exists():
        return 0, 0
    files = list(model_dir.glob("*.safetensors")) + list(model_dir.glob("*.bin"))
    total_size = sum(f.stat().st_size for f in files)
    return len(files), total_size


def model_is_valid(model_dir: Path, min_size_gb: float = 0.5) -> bool:
    """检查模型目录是否有效 (有 config.json 且权重文件大小合理)."""
    if not model_dir.exists():
        return False
    if not (model_dir / "config.json").exists():
        return False
    n_files, total_size = check_model_disk_size(model_dir)
    if n_files == 0:
        return False
    size_gb = total_size / (1024**3)
    if size_gb < min_size_gb:
        log(f"模型 {model_dir} 权重仅 {size_gb:.1f}GB, 似乎不完整", "WARN")
        return False
    return True


def download_model(
    hf_id: str, target_dir: Path, python: str, no_download: bool = False
) -> bool:
    """使用 huggingface_hub 下载模型."""
    if no_download:
        log(f"禁止下载模式, 跳过 {hf_id}", "WARN")
        return False
    if model_is_valid(target_dir):
        log(f"模型 {target_dir} 已存在, 跳过下载")
        return True

    log(f"正在下载 {hf_id} -> {target_dir} ...", "INFO")
    target_dir.mkdir(parents=True, exist_ok=True)

    # 尝试 huggingface_hub
    try:
        import huggingface_hub

        api = huggingface_hub.HfApi()
        api.snapshot_download(
            repo_id=hf_id,
            local_dir=str(target_dir),
            local_dir_use_symlinks=False,
            resume_download=True,
            ignore_patterns=["*.pt", "*.pth", "*.msgpack", "*.h5", "*.ot"],
        )
        log(f"下载完成: {hf_id}")
        return True
    except Exception as e:
        log(f"huggingface_hub 下载失败: {e}", "WARN")

    # 尝试 hf_transfer (更快)
    try:
        env = os.environ.copy()
        env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
        cmd = [
            python,
            "-m",
            "huggingface_hub",
            "download",
            hf_id,
            "--local-dir",
            str(target_dir),
            "--resume-download",
        ]
        subprocess.run(cmd, env=env, check=True, timeout=3600)
        log(f"hf_transfer 下载完成: {hf_id}")
        return True
    except Exception as e:
        log(f"hf_transfer 下载也失败: {e}", "WARN")

    # 尝试 ModelScope 镜像
    try:
        log("尝试 ModelScope 镜像...")
        env = os.environ.copy()
        env["HF_ENDPOINT"] = "https://hf-mirror.com"
        cmd = [
            python,
            "-m",
            "huggingface_hub",
            "download",
            hf_id,
            "--local-dir",
            str(target_dir),
            "--resume-download",
        ]
        subprocess.run(cmd, env=env, check=True, timeout=3600)
        log(f"ModelScope 镜像下载完成: {hf_id}")
        return True
    except Exception as e:
        log(f"ModelScope 镜像下载也失败: {e}", "WARN")

    log(f"所有下载方式均失败: {hf_id}", "ERROR")
    return False


def convert_gemma4_mtp(
    src_dir: Path = MODEL_PATHS["gemma4"]["mtp_original"],
    dst_dir: Path = MODEL_PATHS["gemma4"]["mtp_draft"],
    python: str = DEFAULT_PYTHON,
) -> bool:
    """将 Gemma4 MTP assistant 权重转换为 vLLM 格式."""
    if dst_dir.exists() and model_is_valid(dst_dir):
        log(f"已转换的 MTP 模型存在: {dst_dir}")
        return True

    if not src_dir.exists() or not (src_dir / "model.safetensors").exists():
        log(f"MTP 原始模型不存在: {src_dir}", "ERROR")
        return False

    log("开始转换 Gemma4 MTP 权重...")
    convert_script = BASE_DIR / "convert_gemma4_mtp.py"
    if not convert_script.exists():
        log(f"转换脚本不存在: {convert_script}", "ERROR")
        return False

    try:
        env = os.environ.copy()
        env["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
        subprocess.run([python, str(convert_script)], env=env, check=True, timeout=600)
        log(f"MTP 模型转换完成: {dst_dir}")
        return True
    except Exception as e:
        log(f"MTP 转换失败: {e}", "ERROR")
        return False


# ====================================================================
# 配置生成器
# ====================================================================


def generate_gemma4_configs(quick: bool = False) -> list[dict]:
    """Gemma4-26B config sweep.
    自动检测 FP8/BF16: FP8→TP=2, BF16→TP=4.
    """
    fp8_path = MODEL_PATHS["gemma4"].get("main_fp8")
    fp8_ok = bool(fp8_path and model_is_valid(fp8_path, min_size_gb=10))
    tp = 2 if fp8_ok else 4

    if quick:
        return [
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": False,
                "mtp_tokens": 0,
            },
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 2,
            },
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 3,
            },
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 4,
            },
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 5,
            },
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": True,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 3,
            },
            {
                "tp_size": tp,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 4,
                "use_mtp": True,
                "mtp_tokens": 3,
            },
        ]

    configs = []
    for chunked in [False, True]:
        for seqs in [8, 16, 32]:
            for mtp, mtok in [(False, 0), (True, 2), (True, 3), (True, 4), (True, 5)]:
                configs.append(
                    {
                        "tp_size": tp,
                        "enforce_eager": False,
                        "chunked_prefill": chunked,
                        "max_num_seqs": seqs,
                        "use_mtp": mtp,
                        "mtp_tokens": mtok if mtp else 0,
                    }
                )
    return configs


def generate_qwen3_configs(quick: bool = False) -> list[dict]:
    """Qwen3.6-27B config sweep.
    27B FP8 ~27GB, min TP=2 (13.5GB/card).
    Test multiple MTP token values at TP=2.
    """
    if quick:
        # 单人编程场景: TP=2, 多参数扫描
        return [
            # 1: Baseline no-MTP
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": False,
                "mtp_tokens": 0,
            },
            # 2-5: MTP token 值扫描
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 2,
            },
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 3,
            },
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 4,
            },
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 5,
            },
            # 6: MTP=3 + chunked_prefill=True
            # 7: MTP=3 + chunked_prefill=True
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": True,
                "max_num_seqs": 16,
                "use_mtp": True,
                "mtp_tokens": 3,
            },
            # 7: MTP=3 + 最小batch
            {
                "tp_size": 2,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 4,
                "use_mtp": True,
                "mtp_tokens": 3,
            },
        ]

    configs = []
    for tp in [2]:
        for chunked in [False, True]:
            for seqs in [8, 16, 32]:
                for mtp, mtok in [
                    (False, 0),
                    (True, 2),
                    (True, 3),
                    (True, 4),
                    (True, 5),
                ]:
                    configs.append(
                        {
                            "tp_size": tp,
                            "enforce_eager": False,
                            "chunked_prefill": chunked,
                            "max_num_seqs": seqs,
                            "use_mtp": mtp,
                            "mtp_tokens": mtok if mtp else 0,
                        }
                    )
    return configs


def generate_qwen3_coder_configs(quick: bool = False) -> list[dict]:
    """Qwen3-Coder-Next-FP8 config sweep.
    79B FP8 -> TP=4: ~19GB/card, needs gpu_mem_util=0.92+.
    No MTP support.
    """
    if quick:
        return [
            # 1: Baseline
            {
                "tp_size": 4,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": False,
                "mtp_tokens": 0,
            },
            # 3: chunked_prefill=True
            {
                "tp_size": 4,
                "enforce_eager": False,
                "chunked_prefill": True,
                "max_num_seqs": 16,
                "use_mtp": False,
                "mtp_tokens": 0,
            },
            # 5: 最小batch（单人场景）
            {
                "tp_size": 4,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 4,
                "use_mtp": False,
                "mtp_tokens": 0,
            },
            # 6: 短上下文（8K）优化
            {
                "tp_size": 4,
                "enforce_eager": False,
                "chunked_prefill": False,
                "max_num_seqs": 16,
                "use_mtp": False,
                "mtp_tokens": 0,
                "max_model_len": 8192,
            },
        ]

    configs = []
    for tp in [4]:  # TP=4 only viable option
        for chunked in [False, True]:
            for seqs in [8, 16, 32]:
                configs.append(
                    {
                        "tp_size": tp,
                        "enforce_eager": False,
                        "chunked_prefill": chunked,
                        "max_num_seqs": seqs,
                        "use_mtp": False,
                        "mtp_tokens": 0,
                    }
                )
    # TP=8 optional (commented - uncomment if you want to test)
    # for eager in [False]:
    #     for chunked in [False]:
    #         for seqs in [16, 32]:
    #             configs.append({"tp_size":8, "enforce_eager":eager, ...})
    return configs


# ====================================================================
# 基准测试引擎 (使用 vLLM Python API)
# ====================================================================


def _find_free_gpus(needed: int, min_free_gb: float = 18.0) -> list[int]:
    """从 nvidia-smi 找到有足够空闲显存的 GPU 索引."""
    gpus = get_gpu_info()
    free_gpus = []
    for g in gpus:
        free_mb = g["memory_total_mb"] - g["memory_used_mb"]
        if free_mb >= min_free_gb * 1024:
            free_gpus.append(g["index"])
    if len(free_gpus) < needed:
        log(
            f"警告: 只有 {len(free_gpus)}/{needed} GPU 有 {min_free_gb}GB+ 空闲,"
            f" 强制使用前 {needed} 个 GPU",
            "WARN",
        )
        return list(range(needed))
    return free_gpus[:needed]


class ModelBenchmark:
    """单个模型的基准测试引擎。"""

    def __init__(
        self,
        model_key: str,
        python: str = DEFAULT_PYTHON,
        output_dir: Path = OUTPUT_DIR,
        no_download: bool = False,
        gpu_ids: Optional[str] = None,
    ):
        self.model_key = model_key
        self.python = python
        self.output_dir = Path(output_dir)
        self.no_download = no_download
        self.gpu_ids = gpu_ids  # 固定 GPU 列表, 如 "4,5"
        self.info = MODEL_PATHS[model_key]
        self.results: list[dict] = []
        self.best_config: Optional[dict] = None
        self._env = os.environ.copy()
        self._env["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"

    # ---- 模型准备 ----

    def prepare(self) -> bool:
        """准备模型 (下载/转换). 返回是否成功."""
        raise NotImplementedError

    # ---- 配置测试 ----

    def _get_gpu_devices(self, tp_size: int) -> str:
        """返回要使用的 GPU 列表 (逗号分隔)."""
        if self.gpu_ids:
            return self.gpu_ids
        free_gpus = _find_free_gpus(tp_size)
        return ",".join(str(i) for i in free_gpus)

    def bench_single_config(self, config: dict) -> dict:
        """测试单个配置, 返回结果字典."""
        raise NotImplementedError

    def run_all_configs(self, configs: list[dict]) -> list[dict]:
        """顺序测试所有配置."""
        total = len(configs)
        for i, cfg in enumerate(configs):
            cfg_tag = self._config_tag(cfg)
            tp = cfg.get("tp_size", "?")
            mtok = cfg.get("mtp_tokens", 0)
            log(f"[{self.model_key}] ({i+1}/{total}) [TP{tp} MTP{mtok}] {cfg_tag} ...")
            try:
                result = self.bench_single_config(cfg)
                self.results.append(result)
                # 打印详细结果
                if result.get("error"):
                    err = result["error"][:120]
                    log(f"  >> FAIL: {err}", "WARN")
                else:
                    tp_s = result.get("throughput_tok_s", "?")
                    lat = result.get("latency_s", "?")
                    ltp = result.get("long_context_throughput_tok_s", "?")
                    load = result.get("load_time_s", "?")
                    mem = result.get("gpu_mem_used_avg_mb", 0)
                    mem_str = f"{mem/1024:.1f}GB" if mem else "?"
                    log(
                        f"  >> OK: {tp_s:.0f} tok/s | 延迟={lat:.3f}s | 长文本={ltp:.0f} tok/s | 加载={load:.1f}s | 显存={mem_str}"
                    )
            except Exception as e:
                log(f"  >> CRASHED: {e}", "ERROR")
                self.results.append(
                    {
                        "config_tag": cfg_tag,
                        "model": self.model_key,
                        "error": str(e)[:200],
                        **cfg,
                    }
                )
        return self.results

    def find_best(self) -> Optional[dict]:
        """从结果中找到最佳配置 (最高吞吐 + 低延迟)."""
        valid = [
            r
            for r in self.results
            if r.get("error") is None and r.get("throughput_tok_s", 0) > 0
        ]
        if not valid:
            return None
        # 排序: 吞吐量优先, 延迟次之
        valid.sort(key=lambda r: (-r["throughput_tok_s"], r.get("latency_s", 999)))
        self.best_config = valid[0]
        return self.best_config

    @staticmethod
    def _config_tag(cfg: dict) -> str:
        mtp = f"_mtp{cfg.get('mtp_tokens',0)}" if cfg.get("use_mtp") else ""
        return (
            f"TP{cfg['tp_size']}_eager{cfg['enforce_eager']}"
            f"_chunk{cfg['chunked_prefill']}_seqs{cfg['max_num_seqs']}{mtp}"
        )

    @staticmethod
    def _collect_gpu_stats(tp_size: int, devices: str = "") -> dict:
        """收集当前 GPU 显存使用."""
        gpus = get_gpu_info()
        if not gpus:
            return {}
        used_indices = (
            list(range(tp_size))
            if not devices
            else [int(x) for x in devices.split(",")]
        )
        target_gpus = [g for g in gpus if g["index"] in used_indices]
        if not target_gpus:
            return {}
        mem_used = [g["memory_used_mb"] for g in target_gpus]
        mem_total = [g["memory_total_mb"] for g in target_gpus]
        return {
            "gpu_count": len(target_gpus),
            "gpu_names": target_gpus[0]["name"],
            "gpu_mem_per_card_mb": mem_total[0],
            "gpu_mem_used_per_card_mb": mem_used,
            "gpu_mem_used_avg_mb": sum(mem_used) / len(mem_used),
        }

    def _cleanup(self):
        """清理 GPU 显存 和 残留进程."""
        gc.collect()
        try:
            import torch

            torch.cuda.empty_cache()
            # 强制释放所有可回收的显存
            torch.cuda.synchronize()
        except ImportError:
            pass
        # 清理 vLLM 残留子进程
        try:
            import subprocess

            subprocess.run(["pkill", "-f", "vllm_worker"], capture_output=True)
            subprocess.run(["pkill", "-f", "engine_core"], capture_output=True)
        except:
            pass
        time.sleep(3)

    # ---- 结果输出 ----

    def save_results(self):
        """保存详细结果 JSON."""
        out = {
            "model": self.model_key,
            "label": self.info["label"],
            "timestamp": datetime.now().isoformat(),
            "gpu_info": get_gpu_info(),
            "best_config": self.best_config,
            "results": self.results,
        }
        path = self.output_dir / f"bench_{self.model_key}_results.json"
        with open(path, "w") as f:
            json.dump(out, f, indent=2, default=str)
        log(f"结果已保存: {path}")

    def summary_table(self) -> str:
        """返回 Markdown 格式的汇总表."""
        lines = [f"\n## {self.info['label']} 基准测试结果\n"]
        lines.append(
            "| 配置 | GPU数 | 加载(s) | 延迟(s) | 吞吐(tok/s) | 长文本吞吐(tok/s) | 状态 |"
        )
        lines.append(
            "|------|-------|---------|---------|-------------|-------------------|------|"
        )
        for r in self.results:
            tag = r.get("config_tag", self._config_tag(r))
            gpus = r.get("gpu_count", r.get("tp_size", "?"))
            load_t = r.get("load_time_s", "?")
            lat = r.get("latency_s", "?")
            tp = r.get("throughput_tok_s", "?")
            ltp = r.get("long_context_throughput_tok_s", "?")
            err = r.get("error", "")
            status = "❌" if err else "✅"
            # Format numbers
            load_s = f"{load_t:.1f}" if isinstance(load_t, (int, float)) else "?"
            lat_s = f"{lat:.3f}" if isinstance(lat, (int, float)) else "?"
            tp_s = f"{tp:.0f}" if isinstance(tp, (int, float)) else "?"
            ltp_s = f"{ltp:.0f}" if isinstance(ltp, (int, float)) else "?"
            lines.append(
                f"| {tag} | {gpus} | {load_s} | {lat_s} | {tp_s} | {ltp_s} | {status} |"
            )

        if self.best_config:
            b = self.best_config
            lines.append(f"\n**最佳配置**: {self._config_tag(b)}")
            lines.append(f"- 吞吐量: {b.get('throughput_tok_s', '?'):.0f} tok/s")
            lines.append(f"- 延迟: {b.get('latency_s', '?'):.3f}s")
            lines.append(f"- GPU数: {b.get('gpu_count', b.get('tp_size', '?'))}")
            lines.append(f"- 加载时间: {b.get('load_time_s', '?'):.1f}s")

        return "\n".join(lines)


# ====================================================================
# Gemma4-26B + MTP 基准测试
# ====================================================================


class Gemma4Benchmark(ModelBenchmark):
    """Gemma4-26B 基准测试 (FP8 + MTP speculative decoding)."""

    def __init__(self, **kwargs):
        super().__init__("gemma4", **kwargs)

    def prepare(self) -> bool:
        """检查/下载 Gemma4 FP8 主模型 和 MTP 辅助模型."""
        # 1. 优先检查 FP8 版，其次 fallback 到 BF16
        fp8_path = self.info.get("main_fp8")
        bf16_path = self.info["main"]

        # 检查 FP8 路径
        if fp8_path and model_is_valid(fp8_path, min_size_gb=10):
            self._use_fp8 = True
            log(f"Gemma4 FP8 主模型: {fp8_path}")
        elif model_is_valid(bf16_path, min_size_gb=10):
            self._use_fp8 = False
            log(f"Gemma4 BF16 主模型: {bf16_path} (建议下载 FP8 版)")
        else:
            log("Gemma4 主模型未找到, 尝试下载 FP8 版...")
            hf_id_fp8 = self.info.get("hf_id_fp8")
            if hf_id_fp8 and download_model(
                hf_id_fp8, fp8_path, self.python, self.no_download
            ):
                self._use_fp8 = True
            else:
                log("FP8 下载失败, 尝试下载 BF16 版...", "WARN")
                if not download_model(
                    self.info["hf_id"], bf16_path, self.python, self.no_download
                ):
                    log("Gemma4 所有模型下载失败！", "ERROR")
                    return False
                self._use_fp8 = False

        # 2. MTP 辅助模型 (MTP 始终是 BF16, 不受主模型精度影响)
        if not model_is_valid(self.info["mtp_draft"], min_size_gb=0.3):
            if not model_is_valid(self.info["mtp_original"], min_size_gb=0.3):
                log("Gemma4 MTP 辅助模型未找到, 尝试下载...")
                if not download_model(
                    self.info["hf_id_mtp"],
                    self.info["mtp_original"],
                    self.python,
                    self.no_download,
                ):
                    log("Gemma4 MTP 辅助模型下载失败, 将继续不使用 MTP", "WARN")
            if model_is_valid(self.info["mtp_original"], min_size_gb=0.3):
                convert_gemma4_mtp(
                    self.info["mtp_original"], self.info["mtp_draft"], self.python
                )

        model_path = str(fp8_path) if self._use_fp8 else str(bf16_path)
        log(f"Gemma4 主模型: {model_path}")
        log(
            f"MTP draft模型: {self.info['mtp_draft']} (可用)"
            if model_is_valid(self.info["mtp_draft"])
            else "MTP draft: 不可用"
        )
        return True

    def _build_llm_kwargs(self, config: dict) -> dict:
        """构建 LLM 初始化参数."""
        model_path = (
            str(self.info["main_fp8"]) if self._use_fp8 else str(self.info["main"])
        )
        kwargs = {
            "model": model_path,
            "tensor_parallel_size": config["tp_size"],
            "dtype": "auto",  # auto 让 vLLM 自动检测 FP8/BF16
            "gpu_memory_utilization": 0.92 if self._use_fp8 else 0.85,
            "max_model_len": config.get("max_model_len", 16384),
            "max_num_seqs": config["max_num_seqs"],
            "enforce_eager": config["enforce_eager"],
            "enable_chunked_prefill": config["chunked_prefill"],
            "max_num_batched_tokens": 8192 if config["chunked_prefill"] else None,
            "block_size": 16,
            "disable_custom_all_reduce": True,
        }
        # V1 speculative decoding: draft_model 放在 speculative_config dict 中
        mtp_draft = self.info["mtp_draft"]
        if config.get("use_mtp") and model_is_valid(mtp_draft):
            kwargs["speculative_config"] = {
                "model": str(mtp_draft),
                "method": "mtp",
                "num_speculative_tokens": config.get("mtp_tokens", 2),
            }
        return kwargs

    def bench_single_config(self, config: dict) -> dict:
        from vllm import LLM, SamplingParams

        tag = self._config_tag(config)
        result = {"config_tag": tag, "model": self.model_key, **copy.deepcopy(config)}

        # 分配 GPU (固定或自动)
        devices_str = self._get_gpu_devices(config["tp_size"])
        self._env["CUDA_VISIBLE_DEVICES"] = devices_str

        # 构建参数
        kwargs = self._build_llm_kwargs(config)
        mtp_info = (
            f"MTP={config.get('use_mtp',False)}" if config.get("use_mtp") else "no-MTP"
        )

        # 加载模型
        t_load = time.time()
        try:
            llm = LLM(**kwargs)
            result["load_time_s"] = round(time.time() - t_load, 1)
        except Exception as e:
            self._cleanup()
            result["error"] = str(e)[:200]
            result["load_time_s"] = round(time.time() - t_load, 1)
            return result

        # 收集 GPU 统计
        gpu_stats = self._collect_gpu_stats(config["tp_size"], devices_str)
        result.update(gpu_stats)

        # 采样参数
        sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=128)

        try:
            # Warmup
            _ = llm.generate(["warmup test " * 20], sampling)

            # ---- 1. 单请求延迟 (短输出, 编程场景) ----
            lat_sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=64)
            t0 = time.perf_counter()
            _ = llm.generate([CODE_PROMPT], lat_sampling)
            result["latency_s"] = round(time.perf_counter() - t0, 3)

            # ---- 2. 批量吞吐 (16个请求, 模拟编程对话) ----
            prompts = [CODE_PROMPT] * 16
            batch_sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=128)
            t0 = time.perf_counter()
            outputs = llm.generate(prompts, batch_sampling)
            gen_time = time.perf_counter() - t0
            total_out = sum(len(o.outputs[0].token_ids) for o in outputs)
            total_in = sum(len(o.prompt_token_ids) for o in outputs)
            result["throughput_tok_s"] = (
                round(total_out / gen_time, 1) if gen_time > 0 else 0
            )
            result["total_input_tok"] = int(total_in)
            result["total_output_tok"] = int(total_out)
            result["gen_time_s"] = round(gen_time, 3)

            # ---- 3. 长文本 ----
            long_prompts = [LONG_CONTEXT_PROMPT] * 2
            t0 = time.perf_counter()
            outputs_long = llm.generate(long_prompts, sampling)
            t_long = time.perf_counter() - t0
            long_tok = sum(len(o.outputs[0].token_ids) for o in outputs_long)
            result["long_context_throughput_tok_s"] = (
                round(long_tok / t_long, 1) if t_long > 0 else 0
            )
            result["long_gen_time_s"] = round(t_long, 3)

        except Exception as e:
            result["error"] = f"推理失败: {str(e)[:200]}"

        # 清理
        del llm
        self._cleanup()
        return result


# ====================================================================
# Qwen3.6-27B (内置 MTP) 基准测试
# ====================================================================


class Qwen36Benchmark(ModelBenchmark):
    """Qwen3.6-27B 基准测试 (内置 MTP head)."""

    def __init__(self, **kwargs):
        super().__init__("qwen3.6", **kwargs)

    def prepare(self) -> bool:
        if not model_is_valid(self.info["main"], min_size_gb=5):
            log("Qwen3.6-27B 模型未找到, 尝试下载...")
            if not download_model(
                self.info["hf_id"], self.info["main"], self.python, self.no_download
            ):
                log("Qwen3.6-27B 下载失败！", "ERROR")
                return False
        log(f"Qwen3.6 模型: {self.info['main']}")
        # 检查 MTP
        has_mtp = (self.info["main"] / "mtp.safetensors").exists()
        log(f"  MTP head: {'可用' if has_mtp else '不可用'}")
        return True

    def _build_llm_kwargs(self, config: dict) -> dict:
        kwargs = {
            "model": str(self.info["main"]),
            "tensor_parallel_size": config["tp_size"],
            "dtype": "auto",
            "gpu_memory_utilization": 0.85,
            "max_model_len": config.get("max_model_len", 32768),
            "max_num_seqs": config["max_num_seqs"],
            "enforce_eager": config["enforce_eager"],
            "enable_chunked_prefill": config["chunked_prefill"],
            "max_num_batched_tokens": 8192 if config["chunked_prefill"] else None,
            "block_size": 16,
            "disable_custom_all_reduce": True,
        }
        # 内置 MTP (Qwen3.5 架构原生支持)
        has_mtp = (self.info["main"] / "mtp.safetensors").exists()
        if config.get("use_mtp") and has_mtp:
            kwargs["speculative_config"] = {
                "method": "mtp",
                "num_speculative_tokens": config.get("mtp_tokens", 2),
            }
            kwargs["language_model_only"] = True
        return kwargs

    def bench_single_config(self, config: dict) -> dict:
        from vllm import LLM, SamplingParams

        tag = self._config_tag(config)
        result = {"config_tag": tag, "model": self.model_key, **copy.deepcopy(config)}

        devices_str = self._get_gpu_devices(config["tp_size"])
        self._env["CUDA_VISIBLE_DEVICES"] = devices_str
        kwargs = self._build_llm_kwargs(config)

        t_load = time.time()
        try:
            llm = LLM(**kwargs)
            result["load_time_s"] = round(time.time() - t_load, 1)
        except Exception as e:
            self._cleanup()
            result["error"] = str(e)[:200]
            result["load_time_s"] = round(time.time() - t_load, 1)
            return result

        gpu_stats = self._collect_gpu_stats(config["tp_size"], devices_str)
        result.update(gpu_stats)

        sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=128)

        try:
            _ = llm.generate(["warmup test " * 20], sampling)

            # 单请求延迟
            lat_sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=64)
            t0 = time.perf_counter()
            _ = llm.generate([CODE_PROMPT], lat_sampling)
            result["latency_s"] = round(time.perf_counter() - t0, 3)

            # 批量吞吐
            prompts = [CODE_PROMPT] * 16
            batch_sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=128)
            t0 = time.perf_counter()
            outputs = llm.generate(prompts, batch_sampling)
            gen_time = time.perf_counter() - t0
            total_out = sum(len(o.outputs[0].token_ids) for o in outputs)
            total_in = sum(len(o.prompt_token_ids) for o in outputs)
            result["throughput_tok_s"] = (
                round(total_out / gen_time, 1) if gen_time > 0 else 0
            )
            result["total_input_tok"] = int(total_in)
            result["total_output_tok"] = int(total_out)
            result["gen_time_s"] = round(gen_time, 3)

            # 长文本
            long_prompts = [LONG_CONTEXT_PROMPT] * 2
            t0 = time.perf_counter()
            outputs_long = llm.generate(long_prompts, sampling)
            t_long = time.perf_counter() - t0
            long_tok = sum(len(o.outputs[0].token_ids) for o in outputs_long)
            result["long_context_throughput_tok_s"] = (
                round(long_tok / t_long, 1) if t_long > 0 else 0
            )
            result["long_gen_time_s"] = round(t_long, 3)

        except Exception as e:
            result["error"] = f"推理失败: {str(e)[:200]}"

        del llm
        self._cleanup()
        return result


# ====================================================================
# Qwen3-Coder-Next-FP8 基准测试
# ====================================================================


class Qwen3CoderBenchmark(ModelBenchmark):
    """Qwen3-Coder-Next-FP8 基准测试."""

    def __init__(self, **kwargs):
        super().__init__("qwen3-coder", **kwargs)

    def prepare(self) -> bool:
        if not model_is_valid(self.info["main"], min_size_gb=10):
            log("Qwen3-Coder-Next-FP8 模型未找到, 尝试下载...")
            if not download_model(
                self.info["hf_id"], self.info["main"], self.python, self.no_download
            ):
                log("Qwen3-Coder-Next-FP8 下载失败！", "ERROR")
                return False
        log(f"Qwen3-Coder 模型: {self.info['main']}")
        return True

    def _build_llm_kwargs(self, config: dict) -> dict:
        return {
            "model": str(self.info["main"]),
            "tensor_parallel_size": config["tp_size"],
            "dtype": "auto",  # FP8 model
            "gpu_memory_utilization": 0.92,
            "max_model_len": config.get("max_model_len", 16384),
            "max_num_seqs": config["max_num_seqs"],
            "enforce_eager": config["enforce_eager"],
            "enable_chunked_prefill": config["chunked_prefill"],
            "max_num_batched_tokens": 8192 if config["chunked_prefill"] else None,
            "block_size": 16,
            "disable_custom_all_reduce": True,
        }

    def bench_single_config(self, config: dict) -> dict:
        from vllm import LLM, SamplingParams

        tag = self._config_tag(config)
        result = {"config_tag": tag, "model": self.model_key, **copy.deepcopy(config)}

        devices_str = self._get_gpu_devices(config["tp_size"])
        self._env["CUDA_VISIBLE_DEVICES"] = devices_str
        kwargs = self._build_llm_kwargs(config)

        t_load = time.time()
        try:
            llm = LLM(**kwargs)
            result["load_time_s"] = round(time.time() - t_load, 1)
        except Exception as e:
            self._cleanup()
            result["error"] = str(e)[:200]
            result["load_time_s"] = round(time.time() - t_load, 1)
            return result

        gpu_stats = self._collect_gpu_stats(config["tp_size"], devices_str)
        result.update(gpu_stats)

        sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=128)

        try:
            _ = llm.generate(["warmup test " * 20], sampling)

            # 单请求延迟
            lat_sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=64)
            t0 = time.perf_counter()
            _ = llm.generate([CODE_PROMPT], lat_sampling)
            result["latency_s"] = round(time.perf_counter() - t0, 3)

            # 批量吞吐
            prompts = [CODE_PROMPT] * 16
            batch_sampling = SamplingParams(temperature=0.0, top_p=1.0, max_tokens=128)
            t0 = time.perf_counter()
            outputs = llm.generate(prompts, batch_sampling)
            gen_time = time.perf_counter() - t0
            total_out = sum(len(o.outputs[0].token_ids) for o in outputs)
            total_in = sum(len(o.prompt_token_ids) for o in outputs)
            result["throughput_tok_s"] = (
                round(total_out / gen_time, 1) if gen_time > 0 else 0
            )
            result["total_input_tok"] = int(total_in)
            result["total_output_tok"] = int(total_out)
            result["gen_time_s"] = round(gen_time, 3)

            # 长文本
            long_prompts = [LONG_CONTEXT_PROMPT] * 2
            t0 = time.perf_counter()
            outputs_long = llm.generate(long_prompts, sampling)
            t_long = time.perf_counter() - t0
            long_tok = sum(len(o.outputs[0].token_ids) for o in outputs_long)
            result["long_context_throughput_tok_s"] = (
                round(long_tok / t_long, 1) if t_long > 0 else 0
            )
            result["long_gen_time_s"] = round(t_long, 3)

        except Exception as e:
            result["error"] = f"推理失败: {str(e)[:200]}"

        del llm
        self._cleanup()
        return result


# ====================================================================
# 统一结果汇总 & 表格生成
# ====================================================================


def generate_final_report(benchmarks: list[ModelBenchmark], output_dir: Path):
    """生成最终报告: JSON + CSV + Markdown."""

    # ---- JSON 总结果 ----
    all_results = {}
    for b in benchmarks:
        all_results[b.model_key] = {
            "label": b.info["label"],
            "best_config": b.best_config,
            "results_count": len(b.results),
        }

    report = {
        "timestamp": datetime.now().isoformat(),
        "hardware": {
            "gpu_count": N_GPUS,
            "gpu_name": GPU_NAME,
            "gpu_mem_gb": GPU_MEM_GB,
            "vllm_version": "0.21.0",
        },
        "scenario": "single-user interactive coding with opencode",
        "models": all_results,
    }
    with open(output_dir / "bench_all_report.json", "w") as f:
        json.dump(report, f, indent=2, default=str)
    log(f"总报告: {output_dir / 'bench_all_report.json'}")

    # ---- 汇总表 (所有模型最佳配置) ----
    lines = [
        "=" * 90,
        "  opencode 编程场景 - 三模型基准测试汇总报告",
        f"  硬件: {N_GPUS}x {GPU_NAME} ({GPU_MEM_GB}GB each)",
        f"  场景: 单用户交互编程 (batch ≤ 16, 低延迟优先)",
        f"  时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "=" * 90,
        "",
        "## 各模型最佳配置\n",
    ]

    best_table = [
        "| 模型 | 最佳配置 | GPU数 | MTP tok | 加载(s) | 延迟(s) | 吞吐(tok/s) | 长文本(tok/s) | 每卡显存(GB) | MTP |",
        "|------|----------|-------|---------|---------|---------|-------------|---------------|-------------|-----|",
    ]

    for b in benchmarks:
        model_name = b.info["label"]
        best = b.best_config
        if best:
            tag = b._config_tag(best)
            gpus = best.get("gpu_count", best.get("tp_size", "?"))
            mtok = best.get("mtp_tokens", 0)
            load_t = best.get("load_time_s", "?")
            lat = best.get("latency_s", "?")
            tp = best.get("throughput_tok_s", "?")
            ltp = best.get("long_context_throughput_tok_s", "?")
            mem_used = best.get("gpu_mem_used_avg_mb", 0)
            mem_gb = f"{mem_used/1024:.1f}" if mem_used else "?"
            mtp = "YES" if best.get("use_mtp") else "no"

            load_s = f"{load_t:.1f}" if isinstance(load_t, (int, float)) else "?"
            lat_s = f"{lat:.3f}" if isinstance(lat, (int, float)) else "?"
            tp_s = f"{tp:.0f}" if isinstance(tp, (int, float)) else "?"
            ltp_s = f"{ltp:.0f}" if isinstance(ltp, (int, float)) else "?"

            best_table.append(
                f"| {model_name} | `{tag}` | {gpus} | {mtok} | {load_s} | {lat_s} | {tp_s} | {ltp_s} | {mem_gb} | {mtp} |"
            )
        else:
            best_table.append(
                f"| {model_name} | 无有效配置 | - | - | - | - | - | - | - |"
            )

    lines += best_table
    lines.append("")

    # ---- 详细配置表 (所有测试过的配置) ----
    lines.append("\n## 详细测试结果\n")
    lines.append(
        "| 模型 | 配置 | MTP tok | GPU数 | 加载(s) | 延迟(s) | 吞吐(tok/s) | 长文本(tok/s) | 状态 |"
    )
    lines.append(
        "|------|------|---------|-------|---------|---------|-------------|---------------|------|"
    )

    for b in benchmarks:
        model_name = b.info["label"]
        for r in b.results:
            gpus = r.get("gpu_count", r.get("tp_size", "?"))
            mtok = r.get("mtp_tokens", 0)
            load_t = r.get("load_time_s", "?")
            lat = r.get("latency_s", "?")
            tp = r.get("throughput_tok_s", "?")
            ltp = r.get("long_context_throughput_tok_s", "?")
            err = r.get("error", "")
            status = "FAIL" if err else "OK"
            load_s = f"{load_t:.1f}" if isinstance(load_t, (int, float)) else "?"
            lat_s = f"{lat:.3f}" if isinstance(lat, (int, float)) else "?"
            tp_s = f"{tp:.0f}" if isinstance(tp, (int, float)) else "?"
            ltp_s = f"{ltp:.0f}" if isinstance(ltp, (int, float)) else "?"
            tag = r.get("config_tag", "?")
            lines.append(
                f"| {model_name} | {tag} | {mtok} | {gpus} | {load_s} | {lat_s} | {tp_s} | {ltp_s} | {status} |"
            )

    # ---- 最佳配置推荐 ----
    lines.extend(
        [
            "",
            "## opencode 单用户编程最佳实践\n",
            "基于测试结果, 为 opencode 编程场景推荐以下配置:\n",
        ]
    )

    for b in benchmarks:
        model_name = b.info["label"]
        best = b.best_config
        if best:
            tag = b._config_tag(best)
            tp = best.get("tp_size", "?")
            lines.append(f"### {model_name}")
            lines.append(f"- **最佳配置**: `{tag}`")
            lines.append(f"- **GPU 占用**: {best.get('gpu_count', tp)} 张")
            lines.append(f"- **MTP token数**: {best.get('mtp_tokens', 0)}")
            lines.append(
                f"- **单请求延迟**: {best.get('latency_s', '?'):.3f}s (输出64tokens)"
            )
            lines.append(
                f"- **批量吞吐**: {best.get('throughput_tok_s', '?'):.0f} tok/s (16并发)"
            )
            lines.append(
                f"- **长文本吞吐**: {best.get('long_context_throughput_tok_s', '?'):.0f} tok/s"
            )
            lines.append(f"- **MTP**: {'启用' if best.get('use_mtp') else '未启用'}")
            lines.append("")

    # ---- 写入文件 ----
    report_md = "\n".join(lines)
    md_path = output_dir / "bench_all_report.md"
    with open(md_path, "w") as f:
        f.write(report_md)
    log(f"Markdown 报告: {md_path}")
    print(report_md)

    # ---- CSV ----
    csv_path = output_dir / "bench_all_results.csv"
    csv_lines = [
        "model,config,gpu_count,mtp_tokens,load_time_s,latency_s,throughput_tok_s,long_context_tok_s,gpu_mem_per_card_mb,error"
    ]
    for b in benchmarks:
        for r in b.results:
            err = r.get("error", "")
            mtok = r.get("mtp_tokens", 0)
            mem = r.get("gpu_mem_used_avg_mb", "")
            csv_lines.append(
                f"{b.model_key},{tag},{r.get('gpu_count', r.get('tp_size',''))},"
                f"{mtok},{r.get('load_time_s','')},{r.get('latency_s','')},"
                f"{r.get('throughput_tok_s','')},{r.get('long_context_throughput_tok_s','')},"
                f"{mem},{err}"
            )
    with open(csv_path, "w") as f:
        f.write("\n".join(csv_lines) + "\n")
    log(f"CSV 数据: {csv_path}")


# ====================================================================
# 主入口
# ====================================================================


def parse_args():
    import argparse

    parser = argparse.ArgumentParser(
        description="vLLM 三模型基准测试 (opencode 编程场景)",
    )
    parser.add_argument(
        "--models",
        nargs="+",
        choices=["gemma4", "qwen3.6", "qwen3-coder"],
        help="要测试的模型 (默认全部)",
    )
    parser.add_argument("--full", action="store_true", help="全量测试 (覆盖更多配置)")
    parser.add_argument("--download", action="store_true", help="允许自动下载模型")
    parser.add_argument("--output", default=str(OUTPUT_DIR), help="输出目录")
    parser.add_argument(
        "--dry-run", action="store_true", help="只打印测试计划, 不加载模型"
    )
    parser.add_argument(
        "--gpu-ids", help="固定 GPU 列表 (如 '4,5'). 子进程模式下自动设置."
    )
    parser.add_argument(
        "--parallel", action="store_true", help="并行模式: 三模型各分配固定 GPU 同时跑"
    )
    args = parser.parse_args()
    # 默认值: quick=true, no-download=true
    args.quick = not args.full
    args.no_download = not args.download
    return args


SUPPORTED_MODELS = {
    "gemma4": {
        "bench_cls": Gemma4Benchmark,
        "config_gen": generate_gemma4_configs,
    },
    "qwen3.6": {
        "bench_cls": Qwen36Benchmark,
        "config_gen": generate_qwen3_configs,
    },
    "qwen3-coder": {
        "bench_cls": Qwen3CoderBenchmark,
        "config_gen": generate_qwen3_coder_configs,
    },
}


def _pipe_logger(model_key: str, pipe, log_file):
    """子进程输出实时打印, 并写入日志文件."""
    try:
        for line in iter(pipe.readline, ""):
            line = line.rstrip("\n")
            if line:
                print(f"[{model_key}] {line}", flush=True)
                log_file.write(f"{line}\n")
                log_file.flush()
    except ValueError:
        pass
    finally:
        pipe.close()


def _run_parallel(args):
    """并行模式: 各模型分配固定 GPU 同时运行."""
    cleanup_gpu_memory()
    import types

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # GPU 自动分配 (基于各模型最小 TP 需求)
    # 8× RTX 4090: Gemma4(2) + Qwen3.6(2) + Qwen3-Coder(4) = 8
    GPU_ASSIGN = {
        "gemma4": [4, 5],
        "qwen3.6": [6, 7],
        "qwen3-coder": [0, 1, 2, 3],
    }

    models_to_test = args.models or list(GPU_ASSIGN.keys())

    log("并行模式: 各模型分配固定 GPU 同时运行")
    for m in models_to_test:
        gpus = GPU_ASSIGN.get(m, [])
        log(f"  {MODEL_PATHS[m]['label']}: GPU {','.join(str(g) for g in gpus)}")

    processes = []
    for model_key in models_to_test:
        if model_key not in GPU_ASSIGN:
            log(f"跳过 {model_key}: 无 GPU 分配", "WARN")
            continue

        gpu_str = ",".join(str(g) for g in GPU_ASSIGN[model_key])
        env = os.environ.copy()
        env["CUDA_VISIBLE_DEVICES"] = gpu_str

        cmd = [
            sys.executable,
            __file__,
            "--models",
            model_key,
            "--gpu-ids",
            gpu_str,
            "--output",
            str(args.output),
        ]
        if args.quick:
            cmd.append("--quick")
        if args.no_download:
            cmd.append("--no-download")

        log_file = open(
            output_dir / f"bench_{model_key}_parallel.log", "w", buffering=1
        )
        log(f"启动 {model_key} -> GPU {gpu_str} ...")
        p = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        t = threading.Thread(
            target=_pipe_logger, args=(model_key, p.stdout, log_file), daemon=True
        )
        t.start()
        processes.append((model_key, p, log_file, t))

    # 等待所有子进程
    failed = []
    for model_key, p, log_file, t in processes:
        log(f"等待 {model_key} 完成...")
        p.wait()
        log_file.close()
        if p.returncode != 0:
            log(f"{model_key} 失败 (返回码 {p.returncode})", "ERROR")
            failed.append(model_key)
        else:
            log(f"{model_key} 完成")

    if failed:
        log(f"以下模型测试失败: {', '.join(failed)}", "WARN")

    # 读取子进程结果, 生成汇总报告
    collected = []
    for model_key in models_to_test:
        result_file = output_dir / f"bench_{model_key}_results.json"
        if result_file.exists():
            with open(result_file) as f:
                data = json.load(f)
            ns = types.SimpleNamespace()
            ns.model_key = data["model"]
            ns.info = {"label": data["label"]}
            ns.best_config = data.get("best_config")
            ns.results = data.get("results", [])
            ns._config_tag = ModelBenchmark._config_tag  # @staticmethod → raw function
            collected.append(ns)
        else:
            log(f"未找到 {model_key} 的结果: {result_file}", "WARN")

    if collected:
        generate_final_report(collected, output_dir)
        log("\n并行测试全部完成!")
    else:
        log("没有收集到任何测试结果", "WARN")


def main():
    args = parse_args()
    cleanup_gpu_memory()
    output_dir = Path(args.output)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.dry_run:
        log("=" * 60)
        log("DRY RUN - 仅打印测试计划")
        log("=" * 60)
        models_to_test = args.models or list(SUPPORTED_MODELS.keys())
        for model_key in models_to_test:
            info = SUPPORTED_MODELS[model_key]
            configs = info["config_gen"](quick=args.quick)
            label = MODEL_PATHS[model_key]["label"]
            log(f"\n{label}")
            log(f"  模型路径: {MODEL_PATHS[model_key]['main']}")
            log(f"  配置数: {len(configs)}")
            log(f"  TP ∈ {sorted(set(c['tp_size'] for c in configs))}")
            for c in configs[:5]:
                tag = (
                    f"TP{c['tp_size']}_eager{c['enforce_eager']}_chunk{c['chunked_prefill']}_seqs{c['max_num_seqs']}"
                    + (f"_mtp{c['mtp_tokens']}" if c.get("use_mtp") else "_nomtp")
                )
                log(f"    {tag}")
            if len(configs) > 5:
                log(f"    ... 共 {len(configs)} 个配置")
        log(f"\n输出目录: {output_dir}")
        log("DRY RUN 完成, 未执行任何模型加载和测试")
        return
    # 并行模式
    if args.parallel:
        return _run_parallel(args)
    log("=" * 60)
    log("vLLM 三模型基准测试")
    log(f"硬件: {N_GPUS}x {GPU_NAME} ({GPU_MEM_GB}GB)")
    log(f"场景: opencode 单用户交互编程")
    log(f"模式: {'快速' if args.quick else '完整扫描'}")
    log("=" * 60)

    # 选择模型
    models_to_test = args.models or list(SUPPORTED_MODELS.keys())
    log(f"测试模型: {', '.join(models_to_test)}")

    benchmarks = []
    for model_key in models_to_test:
        if model_key not in SUPPORTED_MODELS:
            log(f"未知模型: {model_key}", "WARN")
            continue

        info = SUPPORTED_MODELS[model_key]
        log(f"\n{'='*60}")
        log(f"准备模型: {MODEL_PATHS[model_key]['label']}")
        log(f"{'='*60}")

        # 创建 benchmark 实例 (支持固定 GPU)
        bench = info["bench_cls"](
            output_dir=output_dir,
            no_download=args.no_download,
            gpu_ids=args.gpu_ids,
        )

        # 准备模型 (检查/下载)
        if not bench.prepare():
            log(f"模型 {model_key} 准备失败, 跳过", "ERROR")
            continue

        # 生成配置
        configs = info["config_gen"](quick=args.quick)
        log(f"共 {len(configs)} 个配置待测试")

        # 运行所有配置
        bench.run_all_configs(configs)

        # 找最佳配置
        best = bench.find_best()
        if best:
            log(f"\n>>> {bench.info['label']} 最佳配置: {bench._config_tag(best)}")
            log(
                f"    吞吐: {best.get('throughput_tok_s','?'):.0f} tok/s  "
                f"延迟: {best.get('latency_s','?'):.3f}s"
            )
        else:
            log(f"\n>>> {bench.info['label']} 无有效结果")

        # 保存
        bench.save_results()
        benchmarks.append(bench)

    # 生成汇总报告
    if benchmarks:
        log(f"\n{'='*60}")
        log("生成汇总报告...")
        generate_final_report(benchmarks, output_dir)
        log("完成!")
    else:
        log("没有成功运行的模型测试", "WARN")


if __name__ == "__main__":
    main()
