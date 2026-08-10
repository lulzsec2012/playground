#!/usr/bin/env python3
"""
MixAPI vs 本地直连 vLLM 性能对比测试

测试 MixAPI 转发接口下的两个模型性能，并与本地直连的 bench_probe.py 结果比对。
敏感数据通过环境变量传入：MIXAPI_BASE_URL, MIXAPI_API_KEY

用法:
  export MIXAPI_BASE_URL="https://your-mixapi-endpoint"
  export MIXAPI_API_KEY="sk-xxx"
  python scripts/bench_mixapi_vs_local.py

输出:
  - /workspace/vllm_deploy/logs/bench/bench_mixapi_vs_local.json   (原始数据)
  - /workspace/vllm_deploy/logs/bench/bench_mixapi_vs_local.md     (对比报告)
"""

import os, sys, json, time, argparse, statistics
from datetime import datetime
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# 复用 bench_probe 的函数
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_probe import test_streaming, test_non_streaming, compute_stats, messages_to_text

# 输出目录
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent  # /workspace/
VLLM_DEPLOY_DIR = WORKSPACE_ROOT / "vllm_deploy"
LOG_DIR = BASE_DIR / "logs" / "bench"
LOG_DIR.mkdir(parents=True, exist_ok=True)

N_RUNS = 5
WARMUP = 1

SCENARIOS = [
    {"name": "short-func",   "label": "短函数生成 (out~100)",
     "messages": [{"role": "user", "content": "Write a Python binary search tree with insert, delete, and search."}],
     "max_tokens": 100},
    {"name": "code-review",  "label": "代码审查 (out~300)",
     "messages": [{"role": "user", "content": "Review this quicksort implementation and fix any bugs:\n\ndef quicksort(arr):\n    if len(arr) <= 1:\n        return arr\n    pivot = arr[len(arr)//2]\n    left = [x for x in arr if x < pivot]\n    middle = [x for x in arr if x == pivot]\n    right = [x for x in arr if x > pivot]\n    return quicksort(left) + middle + quicksort(right)"}],
     "max_tokens": 300},
    {"name": "long-code",    "label": "复杂编码 (out~500)",
     "messages": [{"role": "user", "content": "Write a complete async web scraper in Python. Include:\n- Async HTTP client with retry logic\n- Rate limiting per domain\n- HTML parsing with BeautifulSoup\n- Save results to SQLite\n- Graceful error handling\n- Progress logging\nInclude full code with type hints and docstrings."}],
     "max_tokens": 500},
]

CONCURRENT = {
    "label": "并发 4 请求 (out=150)",
    "messages": [{"role": "user", "content": "Write a Python async producer-consumer queue with error handling."}],
    "max_tokens": 150,
    "concurrency": 4,
}


def get_headers():
    """从环境变量构建 MixAPI 认证头."""
    api_key = os.environ.get("MIXAPI_API_KEY", "")
    if not api_key:
        print("[WARN] MIXAPI_API_KEY 未设置，尝试无认证请求")
        return None
    return {"Authorization": f"Bearer {api_key}"}


def resolve_mixapi_url():
    """从环境变量解析 MixAPI URL，返回裸地址（不含 /v1 后缀），
    因为 test_streaming 内部会追加 /v1/chat/completions 等路径。"""
    base = os.environ.get("MIXAPI_BASE_URL", "").rstrip("/")
    if not base:
        print("[ERROR] MIXAPI_BASE_URL 环境变量未设置")
        sys.exit(1)
    # 去掉可能已有的 /v1 后缀——test_streaming 内部会追加 /v1/...
    return base.replace("/v1", "")


def test_mixapi(model_name, scenarios, concurrency_config, headers):
    """通过 MixAPI 转发测试指定模型的所有场景."""
    api_base = resolve_mixapi_url()
    # MixAPI 的 model 名通常与本地 served-model-name 一致
    model = model_name
    results = []

    print(f"\n{'='*60}")
    print(f"MixAPI Benchmark [{model_name}]")
    print(f"  Endpoint: {api_base}")
    print(f"  Time:     {datetime.now().isoformat()}")
    print(f"{'='*60}")

    # Warmup
    print(f"\n[WARMUP] {WARMUP} run(s)...")
    for _ in range(WARMUP):
        test_streaming(api_base, model, scenarios[0]["messages"], scenarios[0]["max_tokens"], headers=headers)

    # Streaming scenarios
    for scenario in scenarios:
        name = scenario["name"]
        label = scenario["label"]
        print(f"\n[{name}] {label} ({N_RUNS} runs)...")

        ttft_values, throughput_values = [], []
        prompt_tok = 0

        for i in range(N_RUNS):
            result = test_streaming(api_base, model, scenario["messages"], scenario["max_tokens"], headers=headers)
            if result["success"]:
                ttft_values.append(result["ttft_s"])
                throughput_values.append(result["throughput_tok_s"])
                if prompt_tok == 0:
                    prompt_tok = result["prompt_tokens"]
                comp = result["completion_tokens"]
                status = (f"✓  {result['throughput_tok_s']:>6.1f} tok/s  "
                          f"TTFT={result['ttft_s']*1000:.0f}ms  out={comp} tok")
            else:
                status = f"✗  {result['error']}"
            print(f"    Run {i+1}/{N_RUNS}: {status}")

        ttft_stats = compute_stats(ttft_values) if ttft_values else {}
        tp_stats = compute_stats(throughput_values) if throughput_values else {}

        scenario_result = {
            "scenario": name, "label": label, "n_runs": N_RUNS,
            "success_rate": f"{len(throughput_values)}/{N_RUNS}",
            "prompt_tokens": prompt_tok,
            "ttft_sec": ttft_stats, "throughput_tok_s": tp_stats,
        }
        results.append(scenario_result)

        print(f"  → Tput: {tp_stats.get('mean', 0):.1f} ± {tp_stats.get('stdev', 0):.1f} tok/s  "
              f"TTFT: {ttft_stats.get('mean', 0)*1000:.0f} ± {ttft_stats.get('stdev', 0)*1000:.0f} ms  "
              f"prompt={prompt_tok} tok")

    # Concurrent test
    cc = concurrency_config["concurrency"]
    print(f"\n[concurrent] {concurrency_config['label']} × {cc}...")
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=cc) as ex:
        futures = [ex.submit(test_non_streaming, api_base, model,
                             concurrency_config["messages"], concurrency_config["max_tokens"],
                             headers=headers) for _ in range(cc)]
        conc_results = [f.result() for f in as_completed(futures)]
    total_time = time.perf_counter() - t0
    successes = [r for r in conc_results if r["success"]]
    total_tokens = sum(r["completion_tokens"] for r in successes)
    combined_tp = round(total_tokens / total_time, 2) if total_time > 0 else 0
    print(f"  Result: {len(successes)}/{cc} success, {total_tokens} tok in {total_time:.1f}s = {combined_tp} tok/s combined")

    results.append({
        "scenario": "concurrent", "label": concurrency_config["label"],
        "concurrency": cc, "success_count": len(successes),
        "total_time_s": round(total_time, 2), "combined_throughput_tok_s": combined_tp,
    })

    # Aggregate score
    throughputs = [r["throughput_tok_s"]["mean"] for r in results
                   if "throughput_tok_s" in r and isinstance(r["throughput_tok_s"], dict)
                   and r["throughput_tok_s"].get("mean", 0) > 0]
    avg_tp = statistics.mean(throughputs) if throughputs else 0
    score = round(min(avg_tp / 1.5, 100.0) * 0.7 + 30, 2)  # simplified score

    print(f"\n{'='*60}")
    print(f"  SCORE: {score}  |  Avg throughput: {avg_tp:.1f} tok/s")
    print(f"{'='*60}\n")

    return {
        "model": model_name,
        "endpoint": api_base,
        "timestamp": datetime.now().isoformat(),
        "scenarios": results,
        "aggregate_score": score,
        "avg_throughput_tok_s": round(avg_tp, 2),
    }


def load_local_benchmark(model_name):
    """读取本地 bench_probe 的结果作为对比基准."""
    model_key = "qwen" if "qwen" in model_name.lower() else "gemma"
    path = BASE_DIR / "logs" / "bench" / f"bench_local_{model_key}.json"
    path_alt = Path(f"/tmp/bench_{model_key}.json")
    for p in [path, path_alt]:
        if p.exists():
            with open(p) as f:
                return json.load(f)
    return None


def build_comparison(mixapi_result, local_result):
    """构建 MixAPI vs 本地对比数据."""
    comparison = {
        "model": mixapi_result["model"],
        "mixapi_timestamp": mixapi_result["timestamp"],
        "local_timestamp": local_result.get("timestamp", "N/A") if local_result else "N/A",
        "aggregate": {
            "mixapi_score": mixapi_result["aggregate_score"],
            "local_score": local_result["aggregate_score"] if local_result else "N/A",
            "mixapi_avg_tput": mixapi_result["avg_throughput_tok_s"],
            "local_avg_tput": local_result.get("avg_throughput_tok_s", "N/A") if local_result else "N/A",
        },
        "scenarios": [],
    }

    for mix_sc in mixapi_result["scenarios"]:
        name = mix_sc["scenario"]
        local_sc = next((s for s in (local_result.get("scenarios", []) if local_result else [])
                         if s["scenario"] == name), None)

        entry = {"scenario": name, "label": mix_sc.get("label", name)}

        # 吞吐量对比
        if "throughput_tok_s" in mix_sc and isinstance(mix_sc["throughput_tok_s"], dict):
            mix_tput = mix_sc["throughput_tok_s"].get("mean", 0)
            entry["mixapi_throughput_tok_s"] = mix_tput
            if local_sc and "throughput_tok_s" in local_sc and isinstance(local_sc["throughput_tok_s"], dict):
                local_tput = local_sc["throughput_tok_s"].get("mean", 0)
                entry["local_throughput_tok_s"] = local_tput
                if local_tput > 0:
                    diff_pct = round((mix_tput - local_tput) / local_tput * 100, 1)
                    entry["throughput_diff_pct"] = diff_pct
                else:
                    entry["throughput_diff_pct"] = None
            else:
                entry["local_throughput_tok_s"] = None
                entry["throughput_diff_pct"] = None

        # TTFT 对比
        if "ttft_sec" in mix_sc and isinstance(mix_sc["ttft_sec"], dict):
            mix_ttft = mix_sc["ttft_sec"].get("mean", 0)
            entry["mixapi_ttft_ms"] = round(mix_ttft * 1000, 1)
            if local_sc and "ttft_sec" in local_sc and isinstance(local_sc["ttft_sec"], dict):
                local_ttft = local_sc["ttft_sec"].get("mean", 0)
                entry["local_ttft_ms"] = round(local_ttft * 1000, 1)
                if local_ttft > 0:
                    ttft_diff_pct = round((mix_ttft - local_ttft) / local_ttft * 100, 1)
                    entry["ttft_diff_pct"] = ttft_diff_pct
                else:
                    entry["ttft_diff_pct"] = None
            else:
                entry["local_ttft_ms"] = None
                entry["ttft_diff_pct"] = None

        # 并发对比
        if name == "concurrent":
            entry["mixapi_combined_tput"] = mix_sc.get("combined_throughput_tok_s")
            if local_sc:
                entry["local_combined_tput"] = local_sc.get("combined_throughput_tok_s")
                if local_sc.get("combined_throughput_tok_s", 0):
                    entry["combined_tput_diff_pct"] = round(
                        (mix_sc.get("combined_throughput_tok_s", 0) - local_sc.get("combined_throughput_tok_s", 0))
                        / local_sc["combined_throughput_tok_s"] * 100, 1)
            else:
                entry["local_combined_tput"] = None

        comparison["scenarios"].append(entry)

    return comparison


def print_comparison_table(comparison):
    """打印对比表格."""
    model = comparison["model"]
    print(f"\n{'='*70}")
    print(f"  对比报告: {model}")
    print(f"{'='*70}")

    # Aggregate
    agg = comparison["aggregate"]
    print(f"\n  综合评分:")
    print(f"    MixAPI: {agg['mixapi_score']}  |  本地: {agg['local_score']}")
    print(f"    平均吞吐: MixAPI {agg['mixapi_avg_tput']} tok/s  |  本地 {agg['local_avg_tput']} tok/s")

    print(f"\n  各场景对比:")
    print(f"  {'场景':<20} {'MixAPI tput':<14} {'本地 tput':<14} {'差异%':<10} {'MixAPI TTFT':<14} {'本地 TTFT':<14} {'TTFT差异%':<10}")
    print(f"  {'-'*96}")

    for sc in comparison["scenarios"]:
        label = sc.get("label", sc["scenario"])[:18]
        mt = f"{sc.get('mixapi_throughput_tok_s', '-')} tok/s" if sc.get("mixapi_throughput_tok_s") else "-"
        lt = f"{sc.get('local_throughput_tok_s', '-')} tok/s" if sc.get("local_throughput_tok_s") else "-"
        dp = f"{sc.get('throughput_diff_pct', '-')}%" if sc.get('throughput_diff_pct') is not None else "-"
        mtt = f"{sc.get('mixapi_ttft_ms', '-')} ms" if sc.get("mixapi_ttft_ms") else "-"
        ltt = f"{sc.get('local_ttft_ms', '-')} ms" if sc.get("local_ttft_ms") else "-"
        tdp = f"{sc.get('ttft_diff_pct', '-')}%" if sc.get('ttft_diff_pct') is not None else "-"

        # 并发行特殊处理
        if sc["scenario"] == "concurrent":
            mt = f"{sc.get('mixapi_combined_tput', '-')} tok/s"
            lt = f"{sc.get('local_combined_tput', '-')} tok/s"
            dp = f"{sc.get('combined_tput_diff_pct', '-')}%"

        print(f"  {label:<20} {mt:<14} {lt:<14} {dp:<10} {mtt:<14} {ltt:<14} {tdp:<10}")

    print(f"{'='*70}\n")


def main():
    parser = argparse.ArgumentParser(description="MixAPI vs 本地 vLLM 性能对比")
    parser.add_argument("--models", nargs="+", default=["qwen3.6-27b", "gemma4-26b-fp8"],
                        help="要测试的模型名列表")
    parser.add_argument("--quick", action="store_true", help="跳过并发测试")
    parser.add_argument("--save", action="store_true", default=True, help="保存结果")
    args = parser.parse_args()

    headers = get_headers()
    all_mixapi_results = []
    all_comparisons = []

    for model_name in args.models:
        print(f"\n{'#'*70}")
        print(f"# 测试模型: {model_name}")
        print(f"{'#'*70}")

        # 1. 通过 MixAPI 测试
        result = test_mixapi(model_name, SCENARIOS if not args.quick else SCENARIOS[:1],
                             CONCURRENT if not args.quick else CONCURRENT, headers)
        all_mixapi_results.append(result)

        # 2. 加载本地基准数据
        local_result = load_local_benchmark(model_name)
        if local_result:
            comparison = build_comparison(result, local_result)
            all_comparisons.append(comparison)
            print_comparison_table(comparison)
        else:
            print(f"\n[WARN] 未找到 {model_name} 的本地基准数据，跳过对比")

    # 保存结果
    if args.save:
        report = {
            "generated_at": datetime.now().isoformat(),
            "mixapi_results": all_mixapi_results,
            "comparisons": all_comparisons,
        }
        json_path = LOG_DIR / "bench_mixapi_vs_local.json"
        with open(json_path, "w") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        print(f"\n[SAVED] {json_path}")

        # 生成 Markdown 报告
        md_lines = [
            f"# MixAPI vs 本地直连 vLLM 性能对比报告",
            f"生成时间: {datetime.now().isoformat()}",
            "",
        ]
        for comp in all_comparisons:
            model = comp["model"]
            md_lines.extend([
                f"## {model}",
                "",
                f"| 场景 | MixAPI 吞吐 | 本地吞吐 | 吞吐差异% | MixAPI TTFT | 本地 TTFT | TTFT 差异% |",
                f"|------|:----------:|:--------:|:--------:|:----------:|:--------:|:--------:|",
            ])
            for sc in comp["scenarios"]:
                label = sc.get("label", sc["scenario"])
                if sc["scenario"] == "concurrent":
                    mt = f"{sc.get('mixapi_combined_tput', '-')} tok/s"
                    lt = f"{sc.get('local_combined_tput', '-')} tok/s"
                    dp = f"{sc.get('combined_tput_diff_pct', '-')}%"
                else:
                    mt = f"{sc.get('mixapi_throughput_tok_s', '-')} tok/s"
                    lt = f"{sc.get('local_throughput_tok_s', '-')} tok/s"
                    dp = f"{sc.get('throughput_diff_pct', '-')}%"
                mtt = f"{sc.get('mixapi_ttft_ms', '-')} ms"
                ltt = f"{sc.get('local_ttft_ms', '-')} ms"
                tdp = f"{sc.get('ttft_diff_pct', '-')}%"
                md_lines.append(f"| {label} | {mt} | {lt} | {dp} | {mtt} | {ltt} | {tdp} |")

            agg = comp["aggregate"]
            md_lines.extend([
                "",
                f"**综合评分**: MixAPI {agg['mixapi_score']} vs 本地 {agg['local_score']}",
                f"**平均吞吐**: MixAPI {agg['mixapi_avg_tput']} tok/s vs 本地 {agg['local_avg_tput']} tok/s",
                "",
                "---",
                "",
            ])

        md_path = LOG_DIR / "bench_mixapi_vs_local.md"
        with open(md_path, "w") as f:
            f.write("\n".join(md_lines) + "\n")
        print(f"[SAVED] {md_path}")

    # 汇总打印
    if all_comparisons:
        print(f"\n{'='*70}")
        print("  汇总: MixAPI vs 本地差异")
        print(f"{'='*70}")
        for comp in all_comparisons:
            agg = comp["aggregate"]
            score_diff = ""
            if isinstance(agg["local_score"], (int, float)):
                sd = agg["mixapi_score"] - agg["local_score"]
                score_diff = f"({'⬆' if sd > 0 else '⬇'} {abs(sd):.1f})"
            print(f"  {comp['model']}: MixAPI score={agg['mixapi_score']}  vs  本地={agg['local_score']} {score_diff}")
        print(f"{'='*70}\n")


if __name__ == "__main__":
    main()
