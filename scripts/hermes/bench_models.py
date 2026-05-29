#!/usr/bin/env python3
"""测试显卡上三个 vLLM 模型的推理速度 (通过 OpenAI API).

用法:
  python scripts/hermes/bench_models.py              # 测试全部
  python scripts/hermes/bench_models.py gemma4        # 指定模型
  python scripts/hermes/bench_models.py --parallel    # 并行测试

三个模型:
  gemma4      → :8001  gemma4-26b-fp8       (TP=2, GPU 0,1)
  qwen3.6     → :8002  qwen3.6-27b           (TP=2, GPU 2,3)
  qwen3-coder → :8003  qwen3-coder-next-fp8  (TP=4, GPU 4-7)
"""
import argparse
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from typing import Optional

CONTAINER = "lulizhi-work-server-dev"

MODELS = {
    "gemma4": {"port": 8001, "name": "gemma4-26b-fp8", "label": "Gemma4-26B-FP8"},
    "qwen3.6": {"port": 8002, "name": "qwen3.6-27b", "label": "Qwen3.6-27B"},
    "qwen3-coder": {"port": 8003, "name": "qwen3-coder-next-fp8", "label": "Qwen3-Coder-FP8"},
}

PROMPTS = {
    "short": "What is the capital of France?",
    "medium": "Write a Python function to implement a binary search tree with insert, delete, and search operations.",
    "code": "Write a complete Python script that: 1) Fetches JSON data from an API, 2) Processes it with pandas, 3) Generates a matplotlib visualization, and 4) Saves it to a file. Include error handling and comments.",
    "long": "Explain the Linux kernel's memory management subsystem in detail. Cover: virtual memory, page tables (multi-level), TLB, swapping, page cache, OOM killer, memory mapping, slab allocator, and NUMA. Include relevant data structures and algorithms." * 3,
}

MAX_TOKENS = {
    "short": 64,
    "medium": 256,
    "code": 512,
    "long": 1024,
}

# Colors
C = {
    "bold": "\033[1m",
    "green": "\033[0;32m",
    "yellow": "\033[1;33m",
    "cyan": "\033[0;36m",
    "red": "\033[0;31m",
    "dim": "\033[2m",
    "nc": "\033[0m",
}


def docker_chat(port: int, model: str, prompt: str, max_tokens: int, stream: bool = False) -> Optional[dict]:
    """通过 docker exec 调用 vLLM API."""
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": stream,
        "temperature": 0.0,
    })

    curl_cmd = (
        f'curl -sf --max-time 120 "http://127.0.0.1:{port}/v1/chat/completions" '
        f'-H "Content-Type: application/json" '
        f'-d {json.dumps(payload)}'
    )

    try:
        result = subprocess.run(
            ["docker", "exec", CONTAINER, "sh", "-c", curl_cmd],
            capture_output=True, text=True, timeout=130,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return None
        if stream:
            return _parse_sse(result.stdout)
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        return None
    except Exception as e:
        return None


def _parse_sse(sse_text: str) -> dict:
    """解析 SSE 流式响应, 返回合并结果."""
    choices = []
    usage = {"completion_tokens": 0}
    content_parts = []
    finish_reason = None

    for line in sse_text.strip().split("\n"):
        line = line.strip()
        if not line.startswith("data: "):
            continue
        data_str = line[6:]
        if data_str == "[DONE]":
            break
        try:
            chunk = json.loads(data_str)
            delta = chunk.get("choices", [{}])[0].get("delta", {})
            if delta.get("content"):
                content_parts.append(delta["content"])
            if chunk.get("usage"):
                usage = chunk["usage"]
            fr = chunk.get("choices", [{}])[0].get("finish_reason")
            if fr:
                finish_reason = fr
        except json.JSONDecodeError:
            continue

    return {
        "choices": [{
            "message": {"content": "".join(content_parts), "role": "assistant"},
            "finish_reason": finish_reason,
        }],
        "usage": usage,
    }


def measure_latency(port: int, model: str, prompt: str, max_tokens: int, label: str) -> dict:
    """测量单请求延迟 (非流式)."""
    t0 = time.perf_counter()
    resp = docker_chat(port, model, prompt, max_tokens, stream=False)
    elapsed = time.perf_counter() - t0

    if resp is None:
        return {"label": label, "error": True, "elapsed": 0, "comp_tokens": 0, "prompt_tokens": 0, "tok_s": 0}

    usage = resp.get("usage", {})
    comp = usage.get("completion_tokens", 0)
    prompt_tok = usage.get("prompt_tokens", 0)
    tok_s = comp / elapsed if elapsed > 0 and comp > 0 else 0

    return {
        "label": label,
        "error": False,
        "elapsed": round(elapsed, 3),
        "comp_tokens": comp,
        "prompt_tokens": prompt_tok,
        "tok_s": round(tok_s, 1),
    }


def measure_stream(port: int, model: str, prompt: str, max_tokens: int, label: str) -> dict:
    """测量流式吞吐."""
    t0 = time.perf_counter()
    resp = docker_chat(port, model, prompt, max_tokens, stream=True)
    elapsed = time.perf_counter() - t0

    if resp is None:
        return {"label": label, "error": True, "elapsed": 0, "comp_tokens": 0, "tok_s": 0}

    usage = resp.get("usage", {})
    comp = usage.get("completion_tokens", 0)
    # If usage not in stream response, estimate from content length
    if comp == 0:
        content = resp.get("choices", [{}])[0].get("message", {}).get("content", "")
        comp = max(1, len(content) // 3)  # rough estimate
    tok_s = comp / elapsed if elapsed > 0 and comp > 0 else 0

    return {
        "label": label,
        "error": False,
        "elapsed": round(elapsed, 3),
        "comp_tokens": comp,
        "tok_s": round(tok_s, 1),
    }


def bench_model(model_key: str) -> list[dict]:
    """测试单个模型, 返回结果列表."""
    info = MODELS[model_key]
    port = info["port"]
    model_name = info["name"]
    label = info["label"]
    results = []

    print(f"\n{C['cyan']}══════════════════════════════════════════════════════════════{C['nc']}")
    print(f"{C['bold']}📊 {label} ({model_name}) — Port {port}{C['nc']}")
    print(f"{C['cyan']}══════════════════════════════════════════════════════════════{C['nc']}")

    # Health check
    resp = docker_chat(port, model_name, "ping", 1, stream=False)
    if resp is None:
        print(f"  {C['red']}✗ API not responding{C['nc']}")
        return results
    print(f"  {C['green']}✓ API alive{C['nc']}")

    # ── 1. Latency (no stream) ──
    print(f"\n  {C['bold']}Latency (非流式){C['nc']}")
    print(f"  {'Prompt':<12} {'MaxTok':>8} {'耗时(s)':>10} {'输出tok':>8} {'tok/s':>7} {'输入tok':>8}")
    print(f"  {'-'*12} {'-'*8} {'-'*10} {'-'*8} {'-'*7} {'-'*8}")

    for pname in ["short", "medium", "code", "long"]:
        prompt = PROMPTS[pname]
        mt = MAX_TOKENS[pname]
        result = measure_latency(port, model_name, prompt, mt, pname)
        results.append({**result, "model": model_key, "mode": "latency"})
        if result["error"]:
            print(f"  {C['red']}{pname:<12} {mt:>8}  ⏱ TIMEOUT{C['nc']}")
        else:
            print(f"  {pname:<12} {mt:>8} {result['elapsed']:>10.3f} {result['comp_tokens']:>8} {result['tok_s']:>7.1f} {result['prompt_tokens']:>8}")

    # ── 2. Streaming ──
    print(f"\n  {C['bold']}Streaming (流式){C['nc']}")
    print(f"  {'Prompt':<12} {'MaxTok':>8} {'耗时(s)':>10} {'输出tok':>8} {'tok/s':>7}")
    print(f"  {'-'*12} {'-'*8} {'-'*10} {'-'*8} {'-'*7}")

    for pname in ["short", "medium"]:
        prompt = PROMPTS[pname]
        mt = MAX_TOKENS[pname]
        result = measure_stream(port, model_name, prompt, mt, pname)
        results.append({**result, "model": model_key, "mode": "stream"})
        if result["error"]:
            print(f"  {C['red']}{pname:<12} {mt:>8}  ⏱ TIMEOUT{C['nc']}")
        else:
            print(f"  {pname:<12} {mt:>8} {result['elapsed']:>10.3f} {result['comp_tokens']:>8} {result['tok_s']:>7.1f}")

    # ── 3. Warm vs Cold ──
    print(f"\n  {C['bold']}Warm vs Cold (流式, short){C['nc']}")
    # Cold: first request
    rc = measure_stream(port, model_name, PROMPTS["short"], MAX_TOKENS["short"], "cold")
    results.append({**rc, "model": model_key, "mode": "cold"})
    # Warm: second request immediately after
    rw = measure_stream(port, model_name, PROMPTS["short"], MAX_TOKENS["short"], "warm")
    results.append({**rw, "model": model_key, "mode": "warm"})

    if not rc["error"]:
        print(f"  {'Cold(冷启动)':<15} {rc['elapsed']:>10.3f} {rc['comp_tokens']:>8} {rc['tok_s']:>7.1f}")
    else:
        print(f"  {C['red']}{'Cold(冷启动)':<15}  TIMEOUT{C['nc']}")
    if not rw["error"]:
        print(f"  {'Warm(预热后)':<15} {rw['elapsed']:>10.3f} {rw['comp_tokens']:>8} {rw['tok_s']:>7.1f}")
    else:
        print(f"  {C['red']}{'Warm(预热后)':<15}  TIMEOUT{C['nc']}")

    return results


def print_summary(all_results: list[dict]):
    """打印汇总表."""
    print(f"\n{C['cyan']}══════════════════════════════════════════════════════════════{C['nc']}")
    print(f"{C['bold']}📋 三模型速度测试汇总{C['nc']}")
    print(f"{C['cyan']}══════════════════════════════════════════════════════════════{C['nc']}")
    print(f"{'模型':<20} {'模式':<10} {'场景':<8} {'耗时(s)':<10} {'tok/s':<8} {'输出tok':<8}")
    print(f"{'-'*20} {'-'*10} {'-'*8} {'-'*10} {'-'*8} {'-'*8}")

    # Group by model
    by_model = {}
    for r in all_results:
        by_model.setdefault(r["model"], []).append(r)

    for mk, mrs in by_model.items():
        label = MODELS[mk]["label"]
        first = True
        for r in mrs:
            mode = r.get("mode", "?")
            lbl = r.get("label", "?")
            err = r.get("error", False)
            if err:
                print(f"{label if first else '':<20} {mode:<10} {lbl:<8} {'TIMEOUT':<10} {'-':<8} {'-':<8}")
            else:
                e = r["elapsed"]
                ts = r["tok_s"]
                ct = r["comp_tokens"]
                print(f"{label if first else '':<20} {mode:<10} {lbl:<8} {str(e):<10} {str(ts):<8} {ct:<8}")
            first = False
        print()

    # GPU summary
    print(f"\n{C['bold']}📊 显存使用{C['nc']}")
    try:
        gpu_out = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,memory.used,memory.free", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5,
        )
        print(gpu_out.stdout)
    except Exception:
        pass


def main():
    parser = argparse.ArgumentParser(description="vLLM 三模型速度测试")
    parser.add_argument("model", nargs="?", choices=list(MODELS.keys()) + ["all"], default="all",
                        help="模型名称 (默认: all)")
    parser.add_argument("--parallel", action="store_true", help="并行测试三个模型")
    args = parser.parse_args()

    models_to_test = list(MODELS.keys()) if args.model == "all" else [args.model]

    print(f"{C['bold']}🚀 vLLM 模型速度测试{C['nc']}")
    print(f"  容器: {CONTAINER}")
    print(f"  时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    try:
        gpu_info = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,name,memory.total", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5,
        )
        print(gpu_info.stdout)
    except Exception:
        pass

    all_results = []

    if args.parallel and len(models_to_test) > 1:
        print(f"\n{C['yellow']}并行测试模式 (ThreadPoolExecutor){C['nc']}")
        with ThreadPoolExecutor(max_workers=len(models_to_test)) as executor:
            futures = {executor.submit(bench_model, mk): mk for mk in models_to_test}
            for future in as_completed(futures):
                try:
                    all_results.extend(future.result())
                except Exception as e:
                    print(f"  {C['red']}Error: {e}{C['nc']}")
    else:
        for mk in models_to_test:
            try:
                all_results.extend(bench_model(mk))
            except Exception as e:
                print(f"  {C['red']}Error testing {mk}: {e}{C['nc']}")

    print_summary(all_results)

    # Save to file
    output_path = f"/tmp/bench_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(output_path, "w") as f:
        json.dump({
            "timestamp": datetime.now().isoformat(),
            "models": all_results,
        }, f, indent=2)
    print(f"\n{C['dim']}详细结果已保存: {output_path}{C['nc']}")


if __name__ == "__main__":
    main()
