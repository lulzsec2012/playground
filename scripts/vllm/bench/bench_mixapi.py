#!/usr/bin/env python3
"""
==============================================================================
MixAPI vLLM 模型性能基准测试（支持云端参考对比）
==============================================================================

自动发现 MixAPI 上的 vLLM 模型并测试性能指标:
  - TTFT (Time to First Token)
  - 端到端延迟 / 生成吞吐量 (tok/s)
  - 多场景对比 + 并发能力

可选 --base-ref 开启云端 API 对比测试（默认 DeepSeek V4 Flash）,
用于评估本地部署与云端的性能差距。

用法:
  # 默认：自动发现 + 测试本地所有模型
  python scripts/bench_mixapi.py

  # 快速模式（每场景 3 轮）
  python scripts/bench_mixapi.py --quick

  # 加入云端对比
  python scripts/bench_mixapi.py --quick --base-ref

  # 手动指定模型和云端参考
  python scripts/bench_mixapi.py --models gemma4-26b-awq-int4 --base-ref --base-ref-model deepseek-chat

环境要求:
  - Python 3.8+
  - requests 库
  - 能访问 MixAPI 服务 (地址见 scripts/data/hosts.cfg)
  - --base-ref 需要 DEEPSEEK_API_KEY 环境变量
==============================================================================
"""

import os
import sys
import json
import time
import argparse
from bench_probe import (
    test_streaming as _probe_streaming,
    test_non_streaming as _probe_non_streaming,
    compute_stats,
)
import statistics
from datetime import datetime
from pathlib import Path
from typing import Optional
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
except ImportError:
    print("[ERROR] 需要安装 requests 库: pip install requests")
    sys.exit(1)

# ====================================================================
# ANSI 终端颜色
# ====================================================================


class C:
    """ANSI 终端颜色代码"""

    CYAN = "\033[36m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RESET = "\033[0m"
    CLEAR_LINE = "\r\033[K"

    @staticmethod
    def ok(count: int) -> str:
        return f"{C.GREEN}✅{count}{C.RESET}"

    @staticmethod
    def fail(count: int) -> str:
        return f"{C.RED}❌{count}{C.RESET}"

    @staticmethod
    def ms(ms_val: float) -> str:
        if ms_val < 150:
            col = C.GREEN
        elif ms_val < 500:
            col = C.YELLOW
        else:
            col = C.RED
        return f"{col}{ms_val:.1f}ms{C.RESET}"

    @staticmethod
    def tok_s(tp: float) -> str:
        if tp > 150:
            col = C.GREEN
        elif tp > 50:
            col = C.YELLOW
        else:
            col = C.RED
        return f"{col}{tp:.1f} tok/s{C.RESET}"


# ====================================================================
# 配置
# ====================================================================

import os
def _load_hosts_cfg():
    for d in (os.path.join(os.path.dirname(__file__), "..", "data"), os.path.join(os.path.dirname(__file__), "data")):
        f = os.path.join(d, "hosts.cfg")
        if os.path.isfile(f):
            for line in open(f):
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    os.environ.setdefault(k.strip(), v.strip().strip('"'))

_load_hosts_cfg()
MIXAPI_BASE_URL = os.environ.get("MIXAPI_BASE_URL") or (f"http://{os.environ.get('ALIYUN_IP', '<aliyun-ip>')}:3000" if os.environ.get('ALIYUN_IP') else "<gateway-ip>")
API_TOKEN = "5npqHnncMlBinulPU1VHcrIze9sGx3T3BsVKnBhRrzxgFpKd"

# vLLM 后端所在 Tailscale 节点
VLLM_HOST = "100.101.118.89"
VLLM_PORTS = list(range(8000, 8006))

# 模型列表（从 MixAPI 自动获取，命令行可覆盖）
MODELS = []

# ====================================================================
# 云端参考 API 配置（用于 --base-ref 对比）
# ====================================================================

CLOUD_API_BASE_URL = os.environ.get(
    "BENCH_CLOUD_BASE_URL", "https://api.deepseek.com/v1"
)
CLOUD_API_KEY = os.environ.get(
    "BENCH_CLOUD_API_KEY", os.environ.get("DEEPSEEK_API_KEY", "")
)
CLOUD_MODEL_ALIASES = {
    "deepseek-chat": "DeepSeek Chat",
    "deepseek-reasoner": "DeepSeek Reasoner",
    "deepseek-v4-flash": "DeepSeek V4 Flash",
}
# DeepSeek V4 Flash 已知上下文限制
CLOUD_MODEL_CONTEXT = {
    "deepseek-chat": 131072,
    "deepseek-reasoner": 131072,
    "deepseek-v4-flash": 262144,
}

# 测试场景: (名称, 用户提示, max_tokens)
# 模拟不同的编程场景
TEST_SCENARIOS = [
    {
        "name": "short-qna",
        "label": "短问答 (20 out tokens)",
        "messages": [{"role": "user", "content": "What is the capital of France?"}],
        "max_tokens": 20,
        "description": "极简问答，测试基础响应速度",
    },
    {
        "name": "code-func",
        "label": "函数生成 (100 out tokens)",
        "messages": [
            {
                "role": "user",
                "content": "Write a Python function that implements a binary search tree with insert, delete, and search operations.",
            }
        ],
        "max_tokens": 100,
        "description": "中等代码生成，测试典型编程场景延迟",
    },
    {
        "name": "code-review",
        "label": "代码审查 (200 out tokens)",
        "messages": [
            {
                "role": "user",
                "content": (
                    "Review this Python code and suggest improvements:\n\n"
                    "def quicksort(arr):\n"
                    "    if len(arr) <= 1:\n"
                    "        return arr\n"
                    "    pivot = arr[len(arr) // 2]\n"
                    "    left = [x for x in arr if x < pivot]\n"
                    "    middle = [x for x in arr if x == pivot]\n"
                    "    right = [x for x in arr if x > pivot]\n"
                    "    return quicksort(left) + middle + quicksort(right)"
                ),
            }
        ],
        "max_tokens": 200,
        "description": "代码审查场景，中等上下文+较长输出",
    },
    {
        "name": "long-context",
        "label": "长上下文 (500 out tokens)",
        "messages": [
            {
                "role": "user",
                "content": (
                    "Explain the Linux kernel's memory management in detail:\n"
                    "- Virtual memory and page tables\n"
                    "- Process address space\n"
                    "- Page allocation and buddy system\n"
                    "- Slab allocator\n"
                    "- Swap and page reclaim\n"
                    "- OOM killer\n"
                    "- Memory-mapped files\n"
                    "- Huge pages and THP\n"
                    "- CMA and ZRAM\n"
                    "- cgroup memory controller\n\n"
                    "Provide a comprehensive explanation for each topic."
                ),
            }
        ],
        "max_tokens": 500,
        "description": "长文档生成，测试长序列吞吐能力",
    },
]

# 并发测试场景
CONCURRENT_SCENARIO = {
    "name": "concurrent-8",
    "label": "并发 8 请求 (code-func)",
    "messages": [
        {
            "role": "user",
            "content": (
                "Write a Python class for a thread-safe task queue with "
                "producer-consumer pattern using asyncio."
            ),
        }
    ],
    "max_tokens": 150,
    "concurrency": 8,
    "description": "8 请求并发，测试服务吞吐上限",
}

# ====================================================================
# 后端信息自动发现
# ====================================================================


def discover_backend_info(mixapi_models: list[str]) -> dict:
    """扫描 vLLM 后端，收集模型部署信息（max_model_len 等）"""
    info = {}
    for port in VLLM_PORTS:
        try:
            r = requests.get(f"http://{VLLM_HOST}:{port}/v1/models", timeout=3)
            if r.status_code != 200:
                continue
            for m in r.json().get("data", []):
                model_id = m["id"]
                if model_id in mixapi_models:
                    info[model_id] = {
                        "port": port,
                        "max_model_len": m.get("max_model_len", "?"),
                    }
        except Exception:
            pass
    return info


def discover_models_from_mixapi() -> list[str]:
    """从 MixAPI 获取可用的模型列表"""
    headers = {"Authorization": f"Bearer {API_TOKEN}"}
    try:
        r = requests.get(f"{MIXAPI_BASE_URL}/v1/models", headers=headers, timeout=10)
        if r.status_code == 200:
            return [m["id"] for m in r.json().get("data", [])]
    except Exception:
        pass
    return []


# 输出目录 (统一 logs/bench/)
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent  # /workspace/
VLLM_DEPLOY_DIR = WORKSPACE_ROOT / "vllm_deploy"
OUTPUT_DIR = VLLM_DEPLOY_DIR / "logs" / "bench"

# 测试参数
DEFAULT_N_RUNS = 5  # 每个场景重复次数
DEFAULT_TIMEOUT = 120  # 单请求超时 (秒)
QUICK_N_RUNS = 3  # 快速模式重复次数


# ====================================================================
# 工具函数
# ====================================================================

# ====================================================================
# 进度跟踪
# ====================================================================


class Progress:
    """静默进度跟踪器，实时显示测试进度条"""

    def __init__(self, total: int):
        self.total = total
        self.done = 0
        self.success = 0
        self.fail = 0
        self._in_progress_label = ""
        self._width = 50  # 进度条宽度

    def set_label(self, label: str):
        self._in_progress_label = label

    def tick(self, ok: bool = True):
        self.done += 1
        if ok:
            self.success += 1
        else:
            self.fail += 1
        self._draw()

    def _draw(self):
        ratio = self.done / max(self.total, 1)
        filled = int(ratio * self._width)
        bar = f"{C.GREEN}{'█' * filled}{C.DIM}{'░' * (self._width - filled)}{C.RESET}"
        pct = int(ratio * 100)
        ok_str = C.ok(self.success)
        fail_str = C.fail(self.fail)
        label = self._in_progress_label
        # 行首清空 + 进度显示 + 标签（中文等宽对齐）
        line = f"\r  [{bar}] {self.done}/{self.total}  {ok_str}  {fail_str}  {pct}%  {label}"
        # 用 CLEAR_LINE + 重绘确保不会残留
        sys.stdout.write(C.CLEAR_LINE)
        sys.stdout.write(f"{line:<100}")
        sys.stdout.flush()

    def newline(self):
        """结束当前进度行，换到下一行"""
        sys.stdout.write(C.CLEAR_LINE)
        sys.stdout.flush()

    def header(self, msg: str):
        self.newline()
        # 模型名称或云端标题用粗体彩色
        if msg.startswith("▶") or msg.startswith("☁️"):
            print(f"  {C.BOLD}{C.CYAN}{msg}{C.RESET}", flush=True)
        else:
            print(f"  {C.BOLD}{msg}{C.RESET}", flush=True)

    def info(self, msg: str):
        self.newline()
        print(f"  {msg}", flush=True)
        self._draw()

    def done_display(self):
        self.newline()
        bar = f"{C.GREEN}{'█' * self._width}{C.RESET}"
        ok_str = C.ok(self.success)
        fail_str = C.fail(self.fail)
        total_str = f"{C.BOLD}{self.done}{C.RESET}/{self.total}"
        msg = f"  [{bar}] {total_str}  {ok_str}  {fail_str}  {C.BOLD}完成!{C.RESET}"
        print(msg, flush=True)


# 全局进度实例 (在 main 中初始化)
_progress: Optional[Progress] = None


def fmt_ms(seconds: float) -> str:
    """格式化毫秒"""
    return f"{seconds * 1000:.1f}ms"


def fmt_tok_s(tokens: float, seconds: float) -> str:
    """格式化 tokens/s"""
    if seconds <= 0:
        return "N/A"
    return f"{tokens / seconds:.1f}"


# ====================================================================
# MixAPI 认证头
# ====================================================================

MIXAPI_HEADERS = {
    "Authorization": f"Bearer {API_TOKEN}",
    "Content-Type": "application/json",
}


# ====================================================================
# 非流式测试 — 委托 bench_probe，替换为 MixAPI endpoint
# ====================================================================


def test_non_streaming(
    model: str,
    messages: list,
    max_tokens: int,
    timeout: int = DEFAULT_TIMEOUT,
) -> dict:
    """非流式请求测试。委托 bench_probe，带 MixAPI auth headers."""
    return _probe_non_streaming(
        MIXAPI_BASE_URL,
        model,
        messages,
        max_tokens,
        timeout=timeout,
        headers=MIXAPI_HEADERS,
    )


# ====================================================================
# 流式测试 — 委托 bench_probe，替换为 MixAPI endpoint
# ====================================================================


def test_streaming(
    model: str,
    messages: list,
    max_tokens: int,
    timeout: int = DEFAULT_TIMEOUT,
) -> dict:
    """流式请求测试。委托 bench_probe，带 MixAPI auth headers."""
    return _probe_streaming(
        MIXAPI_BASE_URL,
        model,
        messages,
        max_tokens,
        timeout=timeout,
        headers=MIXAPI_HEADERS,
    )


# ====================================================================
# 合并统计 — 由 bench_probe.compute_stats 提供
# ====================================================================
# (直接从 bench_probe import compute_stats)


# ====================================================================
# 并发测试
# ====================================================================


def test_concurrent(
    model: str,
    messages: list,
    max_tokens: int,
    concurrency: int = 8,
    timeout: int = DEFAULT_TIMEOUT,
) -> dict:
    """
    并发测试: 同时发送 concurrency 个请求，测量总吞吐。
    """
    results = []
    t_start = time.perf_counter()

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(test_non_streaming, model, messages, max_tokens, timeout)
            for _ in range(concurrency)
        ]
        for f in as_completed(futures):
            results.append(f.result())

    t_total = time.perf_counter() - t_start

    successful = [r for r in results if r["success"]]
    failed = [r for r in results if not r["success"]]

    total_completion = sum(r["completion_tokens"] for r in successful)
    total_prompt = sum(r["prompt_tokens"] for r in successful)
    latencies = [r["latency_s"] for r in successful]
    throughputs = [
        r["throughput_tok_s"] for r in successful if r["throughput_tok_s"] > 0
    ]

    return {
        "success_count": len(successful),
        "fail_count": len(failed),
        "total_time_s": round(t_total, 3),
        "total_prompt_tokens": total_prompt,
        "total_completion_tokens": total_completion,
        "aggregate_throughput_tok_s": (
            round(total_completion / t_total, 1) if t_total > 0 else 0
        ),
        "avg_latency_s": round(statistics.mean(latencies), 4) if latencies else 0,
        "latency_stats": compute_stats(latencies),
        "throughput_stats": compute_stats(throughputs),
        "errors": [r["error"] for r in failed if r["error"]],
    }


# ====================================================================
# 云端基准测试（用于 --base-ref 与本地模型对比）
# ====================================================================


def benchmark_cloud_model(
    model_name: str,
    scenarios: list,
    n_runs: int,
    quick: bool = False,
    timeout: int = DEFAULT_TIMEOUT,
) -> dict:
    """针对云端 API 运行相同场景测试"""
    global _progress
    display_name = CLOUD_MODEL_ALIASES.get(model_name, model_name)
    _progress.header(f"☁️ {display_name}")

    token = CLOUD_API_KEY
    if not token:
        _progress.info("⚠️ 未配置云端 API Key，跳过")
        return None

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    model_results = {
        "model": f"{model_name} (云端)",
        "source": "cloud",
        "cloud_model": model_name,
        "timestamp": datetime.now().isoformat(),
        "scenarios": [],
        "concurrent": None,
    }

    for scenario in scenarios:
        sname = scenario["name"]
        slabel = scenario["label"]
        messages = scenario["messages"]
        max_tok = scenario["max_tokens"]

        # ---- 非流式测试 ----
        ns_latencies = []
        ns_throughputs = []
        ns_prompt_toks = []
        ns_completion_toks = []

        for i in range(n_runs):
            _progress.set_label(f"☁️ {display_name} 非流式 {slabel} [{i+1}/{n_runs}]")
            payload = {
                "model": model_name,
                "messages": messages,
                "max_tokens": max_tok,
                "temperature": 0.0,
                "stream": False,
            }
            result = {
                "success": False,
                "error": None,
                "latency_s": 0,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
                "throughput_tok_s": 0,
            }
            try:
                t0 = time.perf_counter()
                resp = requests.post(
                    f"{CLOUD_API_BASE_URL}/chat/completions",
                    headers=headers,
                    json=payload,
                    timeout=timeout,
                )
                elapsed = time.perf_counter() - t0
                result["latency_s"] = round(elapsed, 4)
                if resp.status_code == 200:
                    data = resp.json()
                    usage = data.get("usage", {})
                    result["prompt_tokens"] = usage.get("prompt_tokens", 0)
                    result["completion_tokens"] = usage.get("completion_tokens", 0)
                    result["total_tokens"] = usage.get("total_tokens", 0)
                    if result["completion_tokens"] > 0 and elapsed > 0:
                        result["throughput_tok_s"] = round(
                            result["completion_tokens"] / elapsed, 1
                        )
                    result["success"] = True
                else:
                    result["error"] = f"HTTP {resp.status_code}: {resp.text[:200]}"
            except Exception as e:
                result["error"] = f"请求失败: {e}"

            if result["success"]:
                ns_latencies.append(result["latency_s"])
                ns_throughputs.append(result["throughput_tok_s"])
                ns_prompt_toks.append(result["prompt_tokens"])
                ns_completion_toks.append(result["completion_tokens"])
                _progress.tick(ok=True)
            else:
                _progress.tick(ok=False)

        # ---- 流式测试 ----
        stream_ttfts = []
        stream_e2es = []
        stream_throughputs = []
        stream_completions = []

        for i in range(n_runs):
            _progress.set_label(f"☁️ {display_name} 流式 {slabel} [{i+1}/{n_runs}]")
            payload = {
                "model": model_name,
                "messages": messages,
                "max_tokens": max_tok,
                "temperature": 0.0,
                "stream": True,
            }
            sr = {
                "success": False,
                "error": None,
                "ttft_s": 0,
                "end_to_end_s": 0,
                "generation_s": 0,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
                "throughput_tok_s": 0,
                "total_throughput_tok_s": 0,
            }
            try:
                t0 = time.perf_counter()
                ttft_recorded = False
                first_token_time = 0
                usage_info = {}
                resp = requests.post(
                    f"{CLOUD_API_BASE_URL}/chat/completions",
                    headers=headers,
                    json=payload,
                    timeout=timeout,
                    stream=True,
                )
                if resp.status_code != 200:
                    sr["error"] = f"HTTP {resp.status_code}: {resp.text[:200]}"
                else:
                    for line in resp.iter_lines(decode_unicode=True):
                        if not line:
                            continue
                        if line.startswith("data: "):
                            data_str = line[6:]
                            if data_str.strip() == "[DONE]":
                                break
                            try:
                                chunk = json.loads(data_str)
                            except json.JSONDecodeError:
                                continue
                            choices = chunk.get("choices", [])
                            if choices:
                                delta = choices[0].get("delta", {})
                                content = delta.get("content", "")
                                if content and not ttft_recorded:
                                    first_token_time = time.perf_counter()
                                    ttft_recorded = True
                                    sr["ttft_s"] = round(first_token_time - t0, 4)
                                usage = chunk.get("usage")
                                if usage:
                                    usage_info = usage
                    t_end = time.perf_counter()
                    sr["end_to_end_s"] = round(t_end - t0, 4)
                    if ttft_recorded:
                        sr["generation_s"] = round(t_end - first_token_time, 4)
                    else:
                        sr["generation_s"] = round(t_end - t0, 4)
                    if usage_info:
                        sr["prompt_tokens"] = usage_info.get("prompt_tokens", 0)
                        sr["completion_tokens"] = usage_info.get("completion_tokens", 0)
                        sr["total_tokens"] = usage_info.get("total_tokens", 0)
                    gen_s = sr["generation_s"]
                    comp = sr["completion_tokens"]
                    if comp > 0 and gen_s > 0:
                        sr["throughput_tok_s"] = round(comp / gen_s, 1)
                    e2e = sr["end_to_end_s"]
                    if comp > 0 and e2e > 0:
                        sr["total_throughput_tok_s"] = round(comp / e2e, 1)
                    sr["success"] = True
            except Exception as e:
                sr["error"] = f"流式请求失败: {e}"

            if sr["success"] and sr["ttft_s"] > 0:
                stream_ttfts.append(sr["ttft_s"])
                stream_e2es.append(sr["end_to_end_s"])
                stream_throughputs.append(sr["throughput_tok_s"])
                stream_completions.append(sr["completion_tokens"])
                _progress.tick(ok=True)
            elif sr["success"]:
                stream_e2es.append(sr["end_to_end_s"])
                _progress.tick(ok=True)
            else:
                _progress.tick(ok=False)

        scenario_result = {
            "name": sname,
            "label": slabel,
            "description": scenario.get("description", ""),
            "max_tokens": max_tok,
            "n_runs": n_runs,
            "non_streaming": {
                "latency_s": compute_stats(ns_latencies) if ns_latencies else {},
                "throughput_tok_s": (
                    compute_stats(ns_throughputs) if ns_throughputs else {}
                ),
                "avg_prompt_tokens": (
                    round(statistics.mean(ns_prompt_toks), 1) if ns_prompt_toks else 0
                ),
                "avg_completion_tokens": (
                    round(statistics.mean(ns_completion_toks), 1)
                    if ns_completion_toks
                    else 0
                ),
                "all_latencies": [round(v, 4) for v in ns_latencies],
                "all_throughputs": [round(v, 2) for v in ns_throughputs],
                "success_count": len(ns_latencies),
                "fail_count": n_runs - len(ns_latencies),
            },
            "streaming": {
                "ttft_s": compute_stats(stream_ttfts) if stream_ttfts else {},
                "end_to_end_s": compute_stats(stream_e2es) if stream_e2es else {},
                "throughput_tok_s": (
                    compute_stats(stream_throughputs) if stream_throughputs else {}
                ),
                "avg_completion_tokens": (
                    round(statistics.mean(stream_completions), 1)
                    if stream_completions
                    else 0
                ),
                "all_ttfts": [round(v, 4) for v in stream_ttfts],
                "all_e2es": [round(v, 4) for v in stream_e2es],
                "all_throughputs": [round(v, 2) for v in stream_throughputs],
                "success_count": len(stream_ttfts),
                "fail_count": n_runs - len(stream_ttfts),
            },
        }

        model_results["scenarios"].append(scenario_result)

        avg_lat = statistics.mean(ns_latencies) if ns_latencies else 0
        avg_tp = statistics.mean(ns_throughputs) if ns_throughputs else 0
        avg_ttft = statistics.mean(stream_ttfts) if stream_ttfts else 0
        _progress.info(
            f"☁️ {slabel}: {avg_tp:.1f} tok/s | TTFT={fmt_ms(avg_ttft)}"
            if stream_ttfts
            else f"☁️ {slabel}: {avg_tp:.1f} tok/s"
        )

    return model_results


# ====================================================================
# 模型全量测试
# ====================================================================


def benchmark_model(
    model: str,
    scenarios: list,
    n_runs: int,
    quick: bool = False,
    skip_concurrent: bool = False,
) -> dict:
    """对单个模型运行所有测试场景。返回完整的测试结果字典。"""
    global _progress
    _progress.header(f"▶ {model}")

    model_results = {
        "model": model,
        "timestamp": datetime.now().isoformat(),
        "scenarios": [],
        "concurrent": None,
    }

    for scenario in scenarios:
        sname = scenario["name"]
        slabel = scenario["label"]
        messages = scenario["messages"]
        max_tok = scenario["max_tokens"]

        # ---- 非流式测试 ----
        ns_latencies = []
        ns_throughputs = []
        ns_prompt_toks = []
        ns_completion_toks = []

        for i in range(n_runs):
            _progress.set_label(f"{model} 非流式 {slabel} [{i+1}/{n_runs}]")
            r = test_non_streaming(model, messages, max_tok)
            if r["success"]:
                ns_latencies.append(r["latency_s"])
                ns_throughputs.append(r["throughput_tok_s"])
                ns_prompt_toks.append(r["prompt_tokens"])
                ns_completion_toks.append(r["completion_tokens"])
                _progress.tick(ok=True)
            else:
                _progress.tick(ok=False)

        # ---- 流式测试 ----
        stream_ttfts = []
        stream_e2es = []
        stream_throughputs = []
        stream_completions = []

        for i in range(n_runs):
            _progress.set_label(f"{model} 流式 {slabel} [{i+1}/{n_runs}]")
            r = test_streaming(model, messages, max_tok)
            if r["success"] and r["ttft_s"] > 0:
                stream_ttfts.append(r["ttft_s"])
                stream_e2es.append(r["end_to_end_s"])
                stream_throughputs.append(r["throughput_tok_s"])
                stream_completions.append(r["completion_tokens"])
                _progress.tick(ok=True)
            elif r["success"]:
                stream_e2es.append(r["end_to_end_s"])
                _progress.tick(ok=True)
            else:
                _progress.tick(ok=False)

        # ---- 汇总场景结果 ----
        scenario_result = {
            "name": sname,
            "label": slabel,
            "description": scenario.get("description", ""),
            "max_tokens": max_tok,
            "n_runs": n_runs,
            "non_streaming": {
                "latency_s": compute_stats(ns_latencies) if ns_latencies else {},
                "throughput_tok_s": (
                    compute_stats(ns_throughputs) if ns_throughputs else {}
                ),
                "avg_prompt_tokens": (
                    round(statistics.mean(ns_prompt_toks), 1) if ns_prompt_toks else 0
                ),
                "avg_completion_tokens": (
                    round(statistics.mean(ns_completion_toks), 1)
                    if ns_completion_toks
                    else 0
                ),
                "all_latencies": [round(v, 4) for v in ns_latencies],
                "all_throughputs": [round(v, 2) for v in ns_throughputs],
                "success_count": len(ns_latencies),
                "fail_count": n_runs - len(ns_latencies),
            },
            "streaming": {
                "ttft_s": compute_stats(stream_ttfts) if stream_ttfts else {},
                "end_to_end_s": compute_stats(stream_e2es) if stream_e2es else {},
                "throughput_tok_s": (
                    compute_stats(stream_throughputs) if stream_throughputs else {}
                ),
                "avg_completion_tokens": (
                    round(statistics.mean(stream_completions), 1)
                    if stream_completions
                    else 0
                ),
                "all_ttfts": [round(v, 4) for v in stream_ttfts],
                "all_e2es": [round(v, 4) for v in stream_e2es],
                "all_throughputs": [round(v, 2) for v in stream_throughputs],
                "success_count": len(stream_ttfts),
                "fail_count": n_runs - len(stream_ttfts),
            },
        }

        model_results["scenarios"].append(scenario_result)

        # 场景摘要（行内，不打断进度条）
        avg_lat = statistics.mean(ns_latencies) if ns_latencies else 0
        avg_tp = statistics.mean(ns_throughputs) if ns_throughputs else 0
        avg_ttft = statistics.mean(stream_ttfts) if stream_ttfts else 0
        st_tp = statistics.mean(stream_throughputs) if stream_throughputs else 0
        if stream_throughputs:
            _progress.info(
                f"{slabel}: 非流式 {C.tok_s(avg_tp)} | "
                f"TTFT={C.ms(avg_ttft * 1000)} | "
                f"流式 {C.tok_s(st_tp)}"
            )
        else:
            _progress.info(f"{slabel}: {C.tok_s(avg_tp)}")

    # ---- 并发测试 ----
    if not skip_concurrent:
        _progress.set_label(
            f"{model} 并发 ({CONCURRENT_SCENARIO['concurrency']}请求)..."
        )
        concurrent_result = test_concurrent(
            model,
            CONCURRENT_SCENARIO["messages"],
            CONCURRENT_SCENARIO["max_tokens"],
            CONCURRENT_SCENARIO["concurrency"],
        )
        model_results["concurrent"] = concurrent_result
        cc_succ = concurrent_result["success_count"]
        cc_fail = concurrent_result["fail_count"]
        cc_tp = concurrent_result["aggregate_throughput_tok_s"]
        _progress.info(
            f"并发({CONCURRENT_SCENARIO['concurrency']}路): "
            f"{C.ok(cc_succ)} {C.fail(cc_fail)}  "
            f"总吞吐={C.tok_s(cc_tp)}"
        )

    return model_results


# ====================================================================
# 报告生成
# ====================================================================


def generate_report(
    all_results: list[dict], output_dir: Path, backend_info: dict = None
):
    """生成 JSON + Markdown 报告"""

    # ---- 保存 JSON ----
    report_data = {
        "timestamp": datetime.now().isoformat(),
        "mixapi_url": MIXAPI_BASE_URL,
        "models_tested": [r["model"] for r in all_results],
        "results": all_results,
    }
    json_path = output_dir / "bench_mixapi_report.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(report_data, f, indent=2, ensure_ascii=False)
    print(f"JSON: {json_path}")

    # ---- Markdown 报告 ----
    lines = []
    lines.append("# MixAPI 远程模型性能测试报告\n")
    lines.append(f"- **测试时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"- **MixAPI 端点**: `{MIXAPI_BASE_URL}`")
    lines.append(f"- **测试方式**: 通过 MixAPI (OneAPI) 转发到内网 vLLM 实例\n")

    for mr in all_results:
        model = mr["model"]
        lines.append(f"## {model}\n")

        lines.append("### 非流式测试结果\n")
        lines.append(
            "| 场景 | 延迟(ms) | 吞吐(tok/s) | 输入tokens | 输出tokens | 失败数 |"
        )
        lines.append(
            "|------|----------|-------------|------------|------------|--------|"
        )

        for sc in mr["scenarios"]:
            ns = sc["non_streaming"]
            lat = ns.get("latency_s", {})
            tp = ns.get("throughput_tok_s", {})
            lat_ms = (
                f"{lat.get('mean', 0) * 1000:.1f} ±{lat.get('stdev', 0) * 1000:.1f}"
            )
            tp_str = f"{tp.get('mean', 0):.1f}"
            p_tok = ns.get("avg_prompt_tokens", "?")
            c_tok = ns.get("avg_completion_tokens", "?")
            fail = ns.get("fail_count", 0)
            lines.append(
                f"| {sc['label']} | {lat_ms} | {tp_str} | {p_tok} | {c_tok} | {fail} |"
            )

        lines.append("\n### 流式测试结果 (TTFT)\n")
        lines.append("| 场景 | TTFT(ms) | 生成时间(ms) | 吞吐(tok/s) | 输出tokens |")
        lines.append("|------|----------|-------------|-------------|------------|")

        for sc in mr["scenarios"]:
            st = sc["streaming"]
            ttft = st.get("ttft_s", {})
            e2e = st.get("end_to_end_s", {})
            tp = st.get("throughput_tok_s", {})
            ttft_ms = (
                f"{ttft.get('mean', 0) * 1000:.1f} ±{ttft.get('stdev', 0) * 1000:.1f}"
            )
            e2e_ms = f"{e2e.get('mean', 0) * 1000:.1f}"
            tp_str = f"{tp.get('mean', 0):.1f}"
            c_tok = st.get("avg_completion_tokens", "?")
            lines.append(
                f"| {sc['label']} | {ttft_ms} | {e2e_ms} | {tp_str} | {c_tok} |"
            )

        # 并发测试
        concurrent = mr.get("concurrent")
        if concurrent:
            lines.append("\n### 并发测试结果\n")
            lines.append(f"| 指标 | 值 |")
            lines.append(f"|------|-----|")
            lines.append(f"| 并发数 | {CONCURRENT_SCENARIO['concurrency']} |")
            lines.append(
                f"| 成功/失败 | {concurrent['success_count']}/{concurrent['fail_count']} |"
            )
            lines.append(f"| 总耗时 | {concurrent['total_time_s']:.2f}s |")
            lines.append(f"| 总输出 tokens | {concurrent['total_completion_tokens']} |")
            lines.append(
                f"| 聚合吞吐 | {concurrent['aggregate_throughput_tok_s']} tok/s |"
            )
            lines.append(f"| 平均延迟 | {fmt_ms(concurrent['avg_latency_s'])} |")
            lat_s = concurrent.get("latency_stats", {})
            lines.append(f"| 延迟 P95 | {fmt_ms(lat_s.get('p95', 0))} |")
            lines.append(f"| 延迟 P99 | {fmt_ms(lat_s.get('p99', 0))} |")

        lines.append("\n---\n")

    # ---- 模型部署参数（本地 + 云端） ----
    lines.append("## 模型部署参数\n")

    has_local = any(mr.get("source") != "cloud" for mr in all_results)
    if has_local:
        lines.append("### 本地部署\n")
        lines.append("| 模型 | 最大上下文(len) | 状态 |")
        lines.append("|------|-----------------|------|")
        for mr in all_results:
            if mr.get("source") == "cloud":
                continue
            model = mr["model"]
            binfo = (backend_info or {}).get(model, {})
            ctx_len = binfo.get("max_model_len", "?")
            ctx_str = f"{ctx_len:,}" if isinstance(ctx_len, int) else str(ctx_len)
            total_succ = 0
            total_fail = 0
            for sc in mr["scenarios"]:
                total_succ += sc["non_streaming"].get("success_count", 0)
                total_succ += sc["streaming"].get("success_count", 0)
                total_fail += sc["non_streaming"].get("fail_count", 0)
                total_fail += sc["streaming"].get("fail_count", 0)
            status = "✅" if total_fail == 0 else "❌"
            lines.append(f"| {model} | {ctx_str} | {status} |")

    has_cloud = any(mr.get("source") == "cloud" for mr in all_results)
    if has_cloud:
        lines.append("\n### 云端参考\n")
        lines.append("| 模型 | 最大上下文(len) | API |")
        lines.append("|------|-----------------|-----|")
        for mr in all_results:
            if mr.get("source") != "cloud":
                continue
            cmodel = mr.get("cloud_model", "")
            ctx = CLOUD_MODEL_CONTEXT.get(cmodel, "?")
            ctx_str = f"{ctx:,}" if isinstance(ctx, int) else str(ctx)
            display = mr["model"]
            lines.append(f"| {display} | {ctx_str} | `{CLOUD_API_BASE_URL}` |")

    # ---- 性能横向对比 ----
    lines.append("\n## 性能横向对比\n")
    lines.append("### 短场景 (函数生成, 100 tokens out)\n")
    lines.append("| 模型 | 延迟(ms) | 吞吐(tok/s) | TTFT(ms) | 成功/失败 |")
    lines.append("|------|----------|-------------|----------|-----------|")

    for mr in all_results:
        model = mr["model"]
        code_sc = next((s for s in mr["scenarios"] if s["name"] == "code-func"), None)
        if code_sc:
            ns = code_sc["non_streaming"]
            st = code_sc["streaming"]
            lat_ms = f"{ns.get('latency_s', {}).get('mean', 0) * 1000:.1f}"
            tp = f"{ns.get('throughput_tok_s', {}).get('mean', 0):.1f}"
            ttft_ms = f"{st.get('ttft_s', {}).get('mean', 0) * 1000:.1f}"
            ns_fail = ns.get("fail_count", 0)
            st_fail = st.get("fail_count", 0)
            ns_succ = ns.get("success_count", 0)
            st_succ = st.get("success_count", 0)
            succ = ns_succ + st_succ
            fail = ns_fail + st_fail
            lines.append(f"| {model} | {lat_ms} | {tp} | {ttft_ms} | {succ}/{fail} |")

    lines.append("\n### 长场景 (Linux内存管理, 500 tokens out)\n")
    lines.append("| 模型 | 延迟(ms) | 吞吐(tok/s) | TTFT(ms) | 成功/失败 |")
    lines.append("|------|----------|-------------|----------|-----------|")

    for mr in all_results:
        model = mr["model"]
        lc_sc = next((s for s in mr["scenarios"] if s["name"] == "long-context"), None)
        if lc_sc:
            ns = lc_sc["non_streaming"]
            st = lc_sc["streaming"]
            lat_ms = f"{ns.get('latency_s', {}).get('mean', 0) * 1000:.1f}"
            tp = f"{ns.get('throughput_tok_s', {}).get('mean', 0):.1f}"
            ttft_ms = f"{st.get('ttft_s', {}).get('mean', 0) * 1000:.1f}"
            ns_fail = ns.get("fail_count", 0)
            st_fail = st.get("fail_count", 0)
            ns_succ = ns.get("success_count", 0)
            st_succ = st.get("success_count", 0)
            succ = ns_succ + st_succ
            fail = ns_fail + st_fail
            lines.append(f"| {model} | {lat_ms} | {tp} | {ttft_ms} | {succ}/{fail} |")

    lines.append("\n### 全景对比 (所有场景均值)\n")
    lines.append(
        "| 模型 | TTFT(ms) | 非流式吞吐(tok/s) | 流式吞吐(tok/s) | 延迟(ms) | 成功/失败 |"
    )
    lines.append(
        "|------|----------|-------------------|-----------------|----------|-----------|"
    )

    for mr in all_results:
        model = mr["model"]
        ns_latencies = []
        ns_throughputs = []
        st_ttfts = []
        st_throughputs = []
        total_succ = 0
        total_fail = 0
        for sc in mr["scenarios"]:
            ns = sc["non_streaming"]
            st = sc["streaming"]
            ns_lat = ns.get("latency_s", {}).get("mean", 0)
            ns_tp = ns.get("throughput_tok_s", {}).get("mean", 0)
            st_ttft = st.get("ttft_s", {}).get("mean", 0)
            st_tp = st.get("throughput_tok_s", {}).get("mean", 0)
            if ns_lat > 0:
                ns_latencies.append(ns_lat)
                ns_throughputs.append(ns_tp)
            if st_ttft > 0:
                st_ttfts.append(st_ttft)
                st_throughputs.append(st_tp)
            total_succ += ns.get("success_count", 0) + st.get("success_count", 0)
            total_fail += ns.get("fail_count", 0) + st.get("fail_count", 0)
        avg_ttft = statistics.mean(st_ttfts) * 1000 if st_ttfts else 0
        avg_ns_tp = statistics.mean(ns_throughputs) if ns_throughputs else 0
        avg_st_tp = statistics.mean(st_throughputs) if st_throughputs else 0
        avg_lat = statistics.mean(ns_latencies) * 1000 if ns_latencies else 0
        lines.append(
            f"| {model} | {avg_ttft:.1f} | {avg_ns_tp:.1f} | {avg_st_tp:.1f} | {avg_lat:.1f} | {total_succ}/{total_fail} |"
        )

    # ---- 并发测试对比 ----
    has_concurrent = any(mr.get("concurrent") for mr in all_results)
    if has_concurrent:
        lines.append("\n### 并发 (8请求) 对比\n")
        lines.append("| 模型 | 成功/失败 | 聚合吞吐(tok/s) | 平均延迟(ms) |")
        lines.append("|------|-----------|-----------------|-------------|")

        for mr in all_results:
            model = mr["model"]
            cc = mr.get("concurrent")
            if cc:
                lines.append(
                    f"| {model} | {cc['success_count']}/{cc['fail_count']} | "
                    f"{cc['aggregate_throughput_tok_s']} | "
                    f"{fmt_ms(cc['avg_latency_s'])} |"
                )

    lines.append("\n---\n")
    lines.append("*报告由 `scripts/bench_mixapi.py` 自动生成*\n")

    report_md = "\n".join(lines)
    md_path = output_dir / "bench_mixapi_report.md"
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(report_md)
    print(f"MD:   {md_path}")
    print("\n" + report_md)


# ====================================================================
# 主入口
# ====================================================================


def parse_args():
    parser = argparse.ArgumentParser(
        description="MixAPI vLLM 远程模型性能测试",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python scripts/bench_mixapi.py
  python scripts/bench_mixapi.py --models gemma4-26b-fp8 qwen3.6-27b
  python scripts/bench_mixapi.py --quick
  python scripts/bench_mixapi.py --runs 10 --output ./my_report
        """,
    )
    parser.add_argument(
        "--models",
        nargs="+",
        default=None,
        help="要测试的模型 (默认从 MixAPI 自动发现)",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=DEFAULT_N_RUNS,
        help=f"每个场景重复次数 (默认 {DEFAULT_N_RUNS})",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help=f"快速模式 (每个场景 {QUICK_N_RUNS} 次)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=str(OUTPUT_DIR),
        help=f"输出目录 (默认 {OUTPUT_DIR})",
    )
    parser.add_argument(
        "--skip-concurrent",
        action="store_true",
        help="跳过并发测试",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"请求超时秒数 (默认 {DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        "--base-ref",
        action="store_true",
        help="启用云端基准测试 (与 DeepSeek 等云端 API 对比)",
    )
    parser.add_argument(
        "--base-ref-model",
        type=str,
        default="deepseek-v4-flash",
        help="云端参考模型 (默认 deepseek-v4-flash)",
    )
    return parser.parse_args()


def main():
    global _progress
    args = parse_args()
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # ---- 自动发现模型列表 ----
    models = args.models
    if not models:
        sys.stdout.write(
            f"{C.CLEAR_LINE}  🔍 {C.DIM}从 MixAPI 自动发现模型...{C.RESET}"
        )
        sys.stdout.flush()
        models = discover_models_from_mixapi()
        if not models:
            print(f"\r  {C.RED}❌ 未发现可用模型{C.RESET}", flush=True)
            sys.exit(1)
        print(
            f"\r  {C.GREEN}✅ 发现 {C.BOLD}{len(models)}{C.RESET}{C.GREEN} 个模型: {C.BOLD}{', '.join(models)}{C.RESET}",
            flush=True,
        )

    # ---- 自动发现后端信息 ----
    sys.stdout.write(f"{C.CLEAR_LINE}  🔍 {C.DIM}扫描 vLLM 后端...{C.RESET}")
    sys.stdout.flush()
    backend_info = discover_backend_info(models)
    if backend_info:
        details = ", ".join(
            f"{C.BOLD}{m}{C.RESET}(len={v['max_model_len']})"
            for m, v in backend_info.items()
        )
        print(
            f"\r  {C.GREEN}✅ 发现 {C.BOLD}{len(backend_info)}{C.RESET}{C.GREEN} 个后端: {details}{C.RESET}",
            flush=True,
        )
    else:
        print(f"\r  {C.YELLOW}⚠️ 未发现 vLLM 后端信息{C.RESET}", flush=True)

    n_runs = QUICK_N_RUNS if args.quick else args.runs
    n_models = len(models)
    n_scenarios = len(TEST_SCENARIOS)
    n_cloud = 1 if args.base_ref else 0
    total_tests = (n_models + n_cloud) * n_scenarios * n_runs * 2 + n_models * 1
    _progress = Progress(total_tests)

    label = f"{', '.join(models)}"
    if args.base_ref:
        label += f"  +  {C.BOLD}{C.MAGENTA}☁️ {args.base_ref_model}{C.RESET}"
    _progress.header(f"MixAPI 远程测试 | {label} | {n_scenarios}场景 × {n_runs}轮")

    # 健康检查
    sys.stdout.write(f"{C.CLEAR_LINE}  ⏳ {C.DIM}健康检查 ...{C.RESET}")
    sys.stdout.flush()
    try:
        resp = requests.get(
            f"{MIXAPI_BASE_URL}/v1/models",
            headers={"Authorization": f"Bearer {API_TOKEN}"},
            timeout=10,
        )
        if resp.status_code == 200:
            models_available = [m["id"] for m in resp.json().get("data", [])]
            for m in models:
                if m not in models_available:
                    print(
                        f"\n  {C.YELLOW}⚠️ 模型 '{m}' 不在 MixAPI 列表中{C.RESET}",
                        flush=True,
                    )
            print(f"\r  {C.GREEN}✅ 健康检查通过{C.RESET}    ", flush=True)
        else:
            print(
                f"\r  {C.RED}❌ 健康检查失败: HTTP {resp.status_code}{C.RESET}",
                flush=True,
            )
            sys.exit(1)
    except Exception as e:
        print(f"\r  {C.RED}❌ 健康检查失败: {e}{C.RESET}", flush=True)
        sys.exit(1)

    all_results = []
    for model in models:
        result = benchmark_model(
            model,
            TEST_SCENARIOS,
            n_runs=n_runs,
            quick=args.quick,
            skip_concurrent=args.skip_concurrent,
        )
        all_results.append(result)

    # ---- 云端基准测试（可选） ----
    if args.base_ref:
        _progress.info("")
        cloud_model_name = args.base_ref_model
        cloud_result = benchmark_cloud_model(
            cloud_model_name,
            TEST_SCENARIOS,
            n_runs=n_runs,
            quick=args.quick,
            timeout=args.timeout,
        )
        if cloud_result:
            all_results.append(cloud_result)

    # 生成报告
    generate_report(all_results, output_dir, backend_info)

    _progress.done_display()
    print(
        f"\n  {C.BOLD}报告:{C.RESET} {C.CYAN}{output_dir / 'bench_mixapi_report.md'}{C.RESET}"
    )
    print(
        f"  {C.BOLD}数据:{C.RESET} {C.DIM}{output_dir / 'bench_mixapi_report.json'}{C.RESET}"
    )
    print()


if __name__ == "__main__":
    main()
