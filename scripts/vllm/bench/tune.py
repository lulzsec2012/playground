#!/usr/bin/env python3
"""
vLLM Tuning v3 — 自动化调参测试编排脚本

对 40 个预设配置组合逐一：
  1. 杀掉目标 GPU 上已有进程
  2. 启动 vLLM API server (Popen, no shell=True)
  3. 等待 health check
  4. 运行 bench_probe.py
  5. 记录结果
  6. 杀掉进程 -> 下一个
"""

import os, sys, json, time, csv, signal, subprocess, argparse
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, TimeoutError

import requests

# 自动检测路径: tune.py → vllm/ → scripts/ → playground/ → /workspace/
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent.parent.parent  # /workspace/
VLLM_DEPLOY_DIR = WORKSPACE_ROOT / "vllm_deploy"  # /workspace/vllm_deploy/
VLLM_DEPLOY_DIR.mkdir(parents=True, exist_ok=True)
LOGS_DIR = VLLM_DEPLOY_DIR / "logs"
LOGS_DIR.mkdir(parents=True, exist_ok=True)
BENCH_DIR = LOGS_DIR / "bench"
BENCH_DIR.mkdir(parents=True, exist_ok=True)
VENV_PYTHON = "/workspace/vllm_deploy/.venv/bin/python"
sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ops")
)
from kill_gpu import kill_gpus as _kill_gpus_fn

BENCH_PROBE = SCRIPT_DIR / "bench_probe.py"  # 同级目录
RESULTS_FILE = BENCH_DIR / "tune_v3_results.csv"
TIMEOUT_COMBO = 720  # 12 min per combo

# -- 40 combos ----------------------------------------------------------

COMBOS = []

A = dict(
    model_path=str(VLLM_DEPLOY_DIR / "models/qwen3.6-27b"),
    model_name="qwen3.6-27b",
    gpu="0,1,2,3",
    port=8003,
    tp=4,
    mtp=5,
    kv_dtype="int8_per_token_head",
    mem=0.93,
    prefetch=True,
    seqs=10,
    bt=8192,
    mml=262144,
    o3=True,
    extra_args=[],
    group="A",
)
COMBOS.extend(
    [
        {**A, "combo": "A1-baseline", "label": "Baseline"},
        {**A, "combo": "A2-mem090", "label": "mem=0.90", "mem": 0.90},
        {
            **A,
            "combo": "A3-mem095-seq15",
            "label": "mem=0.95+seq15",
            "mem": 0.95,
            "seqs": 15,
        },
        {
            **A,
            "combo": "A4-seqs20-bt16384",
            "label": "seqs=20+bt=16384",
            "seqs": 20,
            "bt": 16384,
        },
        {
            **A,
            "combo": "A5-sched5",
            "label": "sched_steps=5",
            "extra_args": ["--num-scheduler-steps", "5"],
        },
        {
            **A,
            "combo": "A6-sched10",
            "label": "sched_steps=10",
            "extra_args": ["--num-scheduler-steps", "10"],
        },
        {
            **A,
            "combo": "A7-block32",
            "label": "block_size=32",
            "extra_args": ["--block-size", "32"],
        },
        {
            **A,
            "combo": "A8-block64",
            "label": "block_size=64",
            "extra_args": ["--block-size", "64"],
        },
        {
            **A,
            "combo": "A9-mml131k-seq20",
            "label": "mml=131k+seqs=20",
            "mml": 131072,
            "seqs": 20,
        },
        {**A, "combo": "A10-fp8kv", "label": "kv=fp8", "kv_dtype": "fp8"},
        {**A, "combo": "A11-nopref", "label": "no pref-cache", "prefetch": False},
        {**A, "combo": "A12-noO3", "label": "no -O3", "o3": False},
    ]
)

B = dict(
    model_path=str(VLLM_DEPLOY_DIR / "models/qwen3.6-27b"),
    model_name="qwen3.6-27b",
    gpu="2,3",
    port=8004,
    tp=2,
    mtp=5,
    kv_dtype="int8_per_token_head",
    mem=0.93,
    prefetch=True,
    seqs=5,
    bt=8192,
    mml=131072,
    o3=True,
    extra_args=[],
    group="B",
)
COMBOS.extend(
    [
        {**B, "combo": "B1-baseline", "label": "TP2 Baseline"},
        {**B, "combo": "B2-mem090", "label": "mem=0.90", "mem": 0.90},
        {**B, "combo": "B3-mem095", "label": "mem=0.95", "mem": 0.95},
        {**B, "combo": "B4-seqs10", "label": "seqs=10", "seqs": 10},
        {
            **B,
            "combo": "B5-sched5",
            "label": "sched_steps=5",
            "extra_args": ["--num-scheduler-steps", "5"],
        },
        {
            **B,
            "combo": "B6-mml65k-seq10",
            "label": "mml=65k+seqs=10",
            "mml": 65536,
            "seqs": 10,
        },
        {**B, "combo": "B7-fp8kv", "label": "kv=fp8", "kv_dtype": "fp8"},
        {
            **B,
            "combo": "B8-block32",
            "label": "block_size=32",
            "extra_args": ["--block-size", "32"],
        },
        {**B, "combo": "B9-nospec", "label": "MTP=0", "mtp": 0},
        {**B, "combo": "B10-mtp3", "label": "MTP=3", "mtp": 3},
    ]
)

C = dict(
    model_path=str(VLLM_DEPLOY_DIR / "models/gemma4-26b-fp8"),
    spec_model_path=str(VLLM_DEPLOY_DIR / "models/gemma4-26b-mtp-vllm"),
    model_name="gemma4-26b-fp8",
    gpu="0,1",
    port=8005,
    tp=2,
    spec_tokens=4,
    kv_dtype="fp8",
    mem=0.95,
    prefetch=True,
    chunked=True,
    seqs=2,
    bt=8192,
    mml=262144,
    o3=True,
    extra_args=[],
    group="C",
)
COMBOS.extend(
    [
        {**C, "combo": "C1-baseline", "label": "Gemma TP2 Baseline"},
        {
            **C,
            "combo": "C2-seqs4-bt16k",
            "label": "seqs=4+bt=16k",
            "seqs": 4,
            "bt": 16384,
        },
        {**C, "combo": "C3-seqs8", "label": "seqs=8", "seqs": 8},
        {
            **C,
            "combo": "C4-sched5",
            "label": "sched_steps=5",
            "extra_args": ["--num-scheduler-steps", "5"],
        },
        {
            **C,
            "combo": "C5-sched10",
            "label": "sched_steps=10",
            "extra_args": ["--num-scheduler-steps", "10"],
        },
        {**C, "combo": "C6-nochunk", "label": "no chunked", "chunked": False},
        {**C, "combo": "C7-nopref", "label": "no pref-cache", "prefetch": False},
        {**C, "combo": "C8-spec5", "label": "spec=5", "spec_tokens": 5},
        {
            **C,
            "combo": "C9-block32",
            "label": "block=32",
            "extra_args": ["--block-size", "32"],
        },
        {
            **C,
            "combo": "C10-mem090-s4",
            "label": "mem=0.90+seqs=4",
            "mem": 0.90,
            "seqs": 4,
        },
    ]
)

D = dict(
    model_path=str(VLLM_DEPLOY_DIR / "models/gemma4-26b-fp8"),
    spec_model_path=str(VLLM_DEPLOY_DIR / "models/gemma4-26b-mtp-vllm"),
    model_name="gemma4-26b-fp8",
    gpu="0,1,2,3",
    port=8006,
    tp=4,
    spec_tokens=4,
    kv_dtype="fp8",
    mem=0.93,
    prefetch=True,
    chunked=False,
    seqs=5,
    bt=8192,
    mml=262144,
    o3=True,
    extra_args=[],
    group="D",
)
COMBOS.extend(
    [
        {**D, "combo": "D1-baseline", "label": "Gemma TP4 Baseline"},
        {
            **D,
            "combo": "D2-seqs10-bt16k",
            "label": "seqs=10+bt=16k",
            "seqs": 10,
            "bt": 16384,
        },
        {
            **D,
            "combo": "D3-seqs20-bt32k",
            "label": "seqs=20+bt=32k",
            "seqs": 20,
            "bt": 32768,
        },
        {
            **D,
            "combo": "D4-mem095-s15",
            "label": "mem=0.95+seqs=15",
            "mem": 0.95,
            "seqs": 15,
        },
        {
            **D,
            "combo": "D5-sched5",
            "label": "sched_steps=5",
            "extra_args": ["--num-scheduler-steps", "5"],
        },
        {**D, "combo": "D6-chunked", "label": "chunked ON", "chunked": True},
        {
            **D,
            "combo": "D7-mml131k-s20",
            "label": "mml=131k+seqs=20",
            "mml": 131072,
            "seqs": 20,
        },
        {
            **D,
            "combo": "D8-block32",
            "label": "block=32",
            "extra_args": ["--block-size", "32"],
        },
    ]
)

assert len(COMBOS) == 40, "Expected 40 combos, got %d" % len(COMBOS)


def log(msg):
    print("[%s] %s" % (datetime.now().strftime("%H:%M:%S"), msg), flush=True)


def kill_gpus(gpu_list):
    log("  杀掉 GPU %s 上所有进程..." % gpu_list)
    _kill_gpus_fn(gpu_list)
    time.sleep(3)
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
        for line in r.stdout.strip().split("\n"):
            parts = line.split(", ")
            if len(parts) == 2 and parts[1].strip() != "0":
                mem = int(parts[1].strip())
                if mem > 500:
                    log("  GPU %s 仍有 %d MiB 占用" % (parts[0].strip(), mem))
    except Exception:
        pass


def launch_vllm(cfg):
    """Start vLLM with Popen (list args, no shell=True -> no quoting issues)."""
    args = [
        str(VENV_PYTHON),
        "-m",
        "vllm.entrypoints.openai.api_server",
        "--model",
        cfg["model_path"],
        "--served-model-name",
        cfg["model_name"],
        "--port",
        str(cfg["port"]),
        "--host",
        "0.0.0.0",
        "--tensor-parallel-size",
        str(cfg["tp"]),
        "--dtype",
        "auto",
        "--gpu-memory-utilization",
        str(cfg["mem"]),
        "--max-model-len",
        str(cfg["mml"]),
        "--max-num-batched-tokens",
        str(cfg["bt"]),
        "--max-num-seqs",
        str(cfg["seqs"]),
        "--no-enforce-eager",
        "--kv-cache-dtype",
        cfg["kv_dtype"],
        "--enable-prefix-caching" if cfg["prefetch"] else "--no-enable-prefix-caching",
    ]
    if "qwen" in cfg["model_name"]:
        args += [
            "--enable-auto-tool-choice",
            "--tool-call-parser",
            "qwen3_coder",
            "--language-model-only",
        ]
        if cfg["mtp"] > 0:
            args += [
                "--speculative-config",
                '{"method":"mtp","num_speculative_tokens":%d}' % cfg["mtp"],
            ]
    if "gemma" in cfg["model_name"]:
        args += ["--enable-auto-tool-choice", "--tool-call-parser", "gemma4"]
        spec = cfg.get("spec_model_path", "")
        if cfg["spec_tokens"] > 0 and spec:
            args += ["--spec-model", spec, "--spec-tokens", str(cfg["spec_tokens"])]
        if cfg.get("chunked", False):
            args += ["--enable-chunked-prefill"]
    args += cfg.get("extra_args", [])
    if cfg["o3"]:
        args += ["-O3"]

    log_file = str(LOGS_DIR / ("tune_v3_%s.log" % cfg["combo"]))
    env = os.environ.copy()
    env["CUDA_VISIBLE_DEVICES"] = cfg["gpu"]
    env["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
    log_fh = open(log_file, "w")
    proc = subprocess.Popen(
        args,
        cwd="/tmp",
        env=env,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    log("  已启动 vLLM (PID %d, log: %s)" % (proc.pid, log_file))
    return proc


def wait_for_server(host, port, timeout=300):
    url = "http://%s:%d/v1/models" % (host, port)
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            r = requests.get(url, timeout=5)
            if r.status_code == 200:
                models = r.json().get("data", [])
                log(
                    "  服务已就绪 (%.0fs) models: %s"
                    % (time.time() - t0, [m["id"] for m in models])
                )
                return True
        except Exception:
            pass
        time.sleep(5)
    log("  超时 %ds - 服务未就绪" % timeout)
    return False


def run_bench(port, model_name, output_json):
    cmd = [
        str(VENV_PYTHON),
        str(BENCH_PROBE),
        "--port",
        str(port),
        "--model",
        model_name,
        "--output",
        output_json,
        "--quick",
    ]
    log("  运行 bench_probe.py ...")
    t0 = time.time()
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300, cwd=str(SCRIPT_DIR)
        )
        log("  bench 完成 (%ds)" % (time.time() - t0))
        if os.path.exists(output_json):
            with open(output_json) as f:
                return json.load(f)
        log("  输出文件未生成: %s" % output_json)
        if proc.stderr:
            log("  stderr: %s" % proc.stderr[:300])
        return None
    except subprocess.TimeoutExpired:
        log("  bench 超时 300s")
        return None
    except Exception as e:
        log("  bench 异常: %s" % e)
        return None


def run_combo(cfg):
    combo_id = cfg["combo"]
    label = cfg["label"]
    group = cfg["group"]
    port = cfg["port"]
    model_name = cfg["model_name"]
    gpu = cfg["gpu"]
    tp = cfg["tp"]

    print("\n%s" % ("=" * 60))
    print("[%s] %s - GPU %s TP%d port %d" % (combo_id, label, gpu, tp, port))
    print("%s" % ("=" * 60))

    # 1. Kill
    kill_gpus(gpu)

    # 2. Launch (Popen, no shell=True)
    proc = launch_vllm(cfg)
    time.sleep(5)

    # 3. Wait for health
    if not wait_for_server("localhost", port, 360):
        proc.kill()
        kill_gpus(gpu)
        return dict(
            combo=combo_id,
            label=label,
            group=group,
            status="FAIL_LOAD",
            score=0,
            throughput=0,
            ttft_ms=0,
            error="Server did not start",
        )

    # 4. Bench
    output_json = str(BENCH_DIR / ("tune_v3_%s.json" % combo_id))
    report = run_bench(port, model_name, output_json)

    # 5. Kill
    proc.kill()
    kill_gpus(gpu)

    # 6. Parse
    if report and report.get("aggregate_score", 0) > 0:
        score = report["aggregate_score"]
        throughput = report.get("avg_throughput_tok_s", 0)
        ttft_list = []
        for s in report.get("scenarios", []):
            ttft = s.get("ttft_sec", {})
            if isinstance(ttft, dict) and ttft.get("mean", 0) > 0:
                ttft_list.append(ttft["mean"])
        avg_ttft = sum(ttft_list) / len(ttft_list) if ttft_list else 0
        return dict(
            combo=combo_id,
            label=label,
            group=group,
            status="OK",
            score=score,
            throughput=throughput,
            ttft_ms=round(avg_ttft * 1000, 1),
            error="",
        )
    else:
        err = report.get("error", "No valid score") if report else "No report"
        return dict(
            combo=combo_id,
            label=label,
            group=group,
            status="FAIL_BENCH",
            score=0,
            throughput=0,
            ttft_ms=0,
            error=err,
        )


def save_report(results):
    fields = [
        "combo",
        "label",
        "group",
        "status",
        "score",
        "throughput",
        "ttft_ms",
        "error",
        "timestamp",
        "duration_s",
    ]
    exists = RESULTS_FILE.exists()
    with open(RESULTS_FILE, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        if not exists:
            w.writeheader()
        for r in results:
            row = {k: r.get(k, "") for k in fields}
            row["timestamp"] = datetime.now().isoformat()
            w.writerow(row)


def print_summary(results):
    ok = [r for r in results if r["status"] == "OK"]
    ok.sort(key=lambda x: x["score"], reverse=True)
    print("\n%s" % ("=" * 60))
    print("  %d/%d 成功" % (len(ok), len(results)))
    if ok:
        print("  Top-3:")
        for i, r in enumerate(ok[:3]):
            print(
                "    %d. %-12s Score=%.1f  吞吐=%.1f tok/s  TTFT=%.0fms"
                % (i + 1, r["combo"], r["score"], r["throughput"], r["ttft_ms"])
            )
    failed = [r for r in results if r["status"] != "OK"]
    if failed:
        print("  失败: %d" % len(failed))
        for r in failed:
            print("    %-12s %s: %s" % (r["combo"], r["status"], r["error"][:80]))
    print("%s\n" % ("=" * 60))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--groups", default="A,B,C,D", help="Comma-separated groups")
    p.add_argument("--resume", default=None, help="Resume from combo ID")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    groups = set(args.groups.upper().split(","))
    combos = [c for c in COMBOS if c["group"] in groups]

    if args.resume:
        idx = next((i for i, c in enumerate(combos) if c["combo"] == args.resume), -1)
        if idx == -1:
            print("Combo %s not found" % args.resume)
            sys.exit(1)
        combos = combos[idx:]

    if args.dry_run:
        print("\n%s" % ("=" * 60))
        print("  vLLM Tuning v3 - %d combos (dry-run)" % len(combos))
        print("%s" % ("=" * 60))
        for c in combos:
            print(
                "  %-12s | %-24s | GPU %-8s | TP%d | port %d"
                % (c["combo"], c["label"], c["gpu"], c["tp"], c["port"])
            )
        print("\n  Total: %d combos" % len(combos))
        return

    BENCH_DIR.mkdir(parents=True, exist_ok=True)
    results = []
    t_start = time.time()

    for i, cfg in enumerate(combos, 1):
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=1) as ex:
            future = ex.submit(run_combo, cfg)
            try:
                result = future.result(timeout=TIMEOUT_COMBO)
            except TimeoutError:
                log("Combo %s 超时 %ds" % (cfg["combo"], TIMEOUT_COMBO))
                kill_gpus(cfg["gpu"])
                result = dict(
                    combo=cfg["combo"],
                    label=cfg["label"],
                    group=cfg["group"],
                    status="TIMEOUT",
                    score=0,
                    throughput=0,
                    ttft_ms=0,
                    error="Timeout %ds" % TIMEOUT_COMBO,
                )
            except Exception as e:
                log("Combo %s 异常: %s" % (cfg["combo"], e))
                kill_gpus(cfg["gpu"])
                result = dict(
                    combo=cfg["combo"],
                    label=cfg["label"],
                    group=cfg["group"],
                    status="ERROR",
                    score=0,
                    throughput=0,
                    ttft_ms=0,
                    error=str(e),
                )

        result["duration_s"] = int(time.time() - t0)
        results.append(result)
        icon = "OK" if result["status"] == "OK" else "FAIL"
        log(
            "[%d/%d] %s %-12s %s score=%.1f (%ds)"
            % (
                i,
                len(combos),
                icon,
                result["combo"],
                result["status"],
                result["score"],
                result["duration_s"],
            )
        )
        save_report([result])
        print_summary(results)

    total = time.time() - t_start
    print("\n%s" % ("=" * 60))
    print(
        "  全部完成! %d combos in %ds (%.1fmin)" % (len(combos), int(total), total / 60)
    )
    print("  结果: %s" % RESULTS_FILE)
    print("%s" % ("=" * 60))

    ok = sorted(
        [r for r in results if r["status"] == "OK"],
        key=lambda x: x["score"],
        reverse=True,
    )
    print("\n  Final Ranking:")
    print(
        "%-5s %-14s %-6s %-8s %-12s %-10s"
        % ("Rank", "Combo", "Group", "Score", "Throughput", "TTFT(ms)")
    )
    print("%s" % ("-" * 55))
    for i, r in enumerate(ok, 1):
        print(
            "%-5d %-14s %-6s %-8.1f %-12.1f %-10.0f"
            % (i, r["combo"], r["group"], r["score"], r["throughput"], r["ttft_ms"])
        )


if __name__ == "__main__":
    main()
