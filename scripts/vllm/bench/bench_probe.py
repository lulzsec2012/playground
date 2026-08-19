#!/usr/bin/env python3
"""
Quick HTTP API probe for vLLM deployment.

Tests single-model inference performance via streaming API.
Designed as a lightweight health check — run against any running vLLM endpoint.

Usage:
  python bench/bench_probe.py --port 8002
  python bench/bench_probe.py --port 8002 --output result.json
  python bench/bench_probe.py --port 8002 --long
  python bench/bench_probe.py --port 8001 --model gemma4-26b-fp8
"""

import os, sys, json, time, argparse, statistics
from datetime import datetime
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
except ImportError:
    print("[ERROR] pip install requests")
    sys.exit(1)

N_RUNS = 5
TIMEOUT = 300
WARMUP = 1

SCENARIOS = [
    {
        "name": "short-func",
        "label": "短函数生成 (out~100)",
        "messages": [
            {
                "role": "user",
                "content": "Write a Python binary search tree with insert, delete, and search.",
            }
        ],
        "max_tokens": 100,
    },
    {
        "name": "code-review",
        "label": "代码审查 (out~300)",
        "messages": [
            {
                "role": "user",
                "content": "Review this quicksort implementation and fix any bugs:\n\ndef quicksort(arr):\n    if len(arr) <= 1:\n        return arr\n    pivot = arr[len(arr)//2]\n    left = [x for x in arr if x < pivot]\n    middle = [x for x in arr if x == pivot]\n    right = [x for x in arr if x > pivot]\n    return quicksort(left) + middle + quicksort(right)",
            }
        ],
        "max_tokens": 300,
    },
    {
        "name": "long-code",
        "label": "复杂编码 (out~500)",
        "messages": [
            {
                "role": "user",
                "content": "Write a complete async web scraper in Python. Include:\n- Async HTTP client with retry logic\n- Rate limiting per domain\n- HTML parsing with BeautifulSoup\n- Save results to SQLite\n- Graceful error handling\n- Progress logging\nInclude full code with type hints and docstrings.",
            }
        ],
        "max_tokens": 500,
    },
]

LONG_CODE_SCENARIO = {
    "name": "long-context",
    "label": "长上下文代码审查 (prompt~2K, out~300)",
    "messages": [
        {
            "role": "user",
            "content": """Review this web application code for bugs and security issues:

# --- app.py ---
from flask import Flask, request, jsonify, render_template
import sqlite3
import hashlib
app = Flask(__name__)

def get_db():
    conn = sqlite3.connect('users.db')
    return conn

@app.route('/login', methods=['POST'])
def login():
    username = request.form['username']
    password = request.form['password']
    conn = get_db()
    cursor = conn.cursor()
    hashed = hashlib.md5(password.encode()).hexdigest()
    query = f"SELECT * FROM users WHERE username='{username}' AND password='{hashed}'"
    cursor.execute(query)
    user = cursor.fetchone()
    if user:
        return jsonify({'status': 'ok', 'user': username})
    return jsonify({'status': 'fail'}), 401

@app.route('/search')
def search():
    q = request.args.get('q', '')
    conn = get_db()
    results = conn.execute(f"SELECT * FROM documents WHERE content LIKE '%{q}%'").fetchall()
    return render_template('results.html', results=results)

@app.route('/admin')
def admin():
    return render_template('admin.html')

# --- models.py ---
from sqlalchemy import create_engine, Column, Integer, String, ForeignKey
from sqlalchemy.orm import relationship, sessionmaker
Base = declarative_base()

class User(Base):
    __tablename__ = 'users'
    id = Column(Integer, primary_key=True)
    username = Column(String(80), unique=True, nullable=False)
    password = Column(String(120), nullable=False)

class Post(Base):
    __tablename__ = 'posts'
    id = Column(Integer, primary_key=True)
    title = Column(String(200))
    content = Column(String(10000))
    user_id = Column(Integer, ForeignKey('users.id'))
    author = relationship('User')

# --- utils.py ---
import pickle
import yaml

def load_config(path):
    with open(path, 'rb') as f:
        return pickle.load(f)

def save_session(data):
    return yaml.dump(data)

def unsafe_eval(expr):
    return eval(expr)

CACHE = {}

def cache_set(key, val):
    CACHE[key] = val

def cache_get(key):
    return CACHE.get(key, None)

# --- tasks.py ---
from celery import Celery
import subprocess

app = Celery('tasks', broker='redis://localhost:6379')

@app.task
def run_backup():
    subprocess.run(['tar', '-czf', '/tmp/backup.tar.gz', '/data'],
                   check=True, capture_output=True)

@app.task
def process_upload(file_id):
    import os
    filepath = f'/uploads/{file_id}'
    os.system(f'chmod 777 {filepath}')
    with open(filepath, 'r') as f:
        content = f.read()
    return len(content)

@app.task
def send_email(to, subject, body):
    subprocess.call(f'mail -s "{subject}" {to} <<< "{body}"', shell=True)
""",
        }
    ],
    "max_tokens": 300,
}

CONCURRENT = {
    "label": "并发 4 请求 (out=150)",
    "messages": [
        {
            "role": "user",
            "content": "Write a Python async producer-consumer queue with error handling.",
        }
    ],
    "max_tokens": 150,
    "concurrency": 4,
}


def tokenize(url, model, text, headers=None):
    """Count tokens using vLLM's /tokenize endpoint."""
    try:
        resp = requests.post(
            f"{url}/tokenize",
            json={"model": model, "prompt": text},
            headers=headers,
            timeout=10,
        )
        if resp.status_code == 200:
            data = resp.json()
            return data.get("count", 0)
    except Exception:
        pass
    return 0


def messages_to_text(messages):
    """Convert messages list to a single prompt string for tokenization."""
    parts = []
    for m in messages:
        role = m["role"]
        content = m.get("content", "")
        if role == "system":
            parts.append(f"<|im_start|>system\n{content}<|im_end|>")
        elif role == "user":
            parts.append(f"<|im_start|>user\n{content}<|im_end|>")
        elif role == "assistant":
            parts.append(f"<|im_start|>assistant\n{content}<|im_end|>")
        else:
            parts.append(content)
    parts.append("<|im_start|>assistant\n")
    return "\n".join(parts)


def test_streaming(url, model, messages, max_tokens, timeout=None, headers=None):
    """Test streaming inference. Uses /tokenize for accurate token counts.

    Args:
        url: Base URL of the vLLM API server.
        model: Model name to test.
        messages: Chat messages list.
        max_tokens: Maximum generation tokens.
        timeout: Request timeout in seconds (default: TIMEOUT global).
        headers: Optional HTTP headers (e.g., Authorization).

    Returns:
        dict with ttft_s, end_to_end_s, generation_s, prompt_tokens,
        completion_tokens, throughput_tok_s, tpot_s, total_tokens,
        response_preview, finish_reason.
    """
    _timeout = timeout if timeout is not None else TIMEOUT
    result = {
        "success": False,
        "error": None,
        "ttft_s": 0,
        "end_to_end_s": 0,
        "generation_s": 0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "total_tokens": 0,
        "throughput_tok_s": 0,
        "tpot_s": 0,
        "response_preview": "",
        "finish_reason": "",
    }
    try:
        # Tokenize input first
        prompt_text = messages_to_text(messages)
        result["prompt_tokens"] = tokenize(url, model, prompt_text, headers=headers)

        t_start = time.perf_counter()
        ttft_recorded = False
        first_token_time = 0.0
        output_parts = []
        finish_reason = ""

        resp = requests.post(
            f"{url}/v1/chat/completions",
            json={
                "model": model,
                "messages": messages,
                "max_tokens": max_tokens,
                "temperature": 0.0,
                "stream": True,
            },
            headers=headers,
            timeout=_timeout,
            stream=True,
        )
        if resp.status_code != 200:
            result["error"] = f"HTTP {resp.status_code}: {resp.text[:200]}"
            return result

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
                    # 兼容 reasoning 模型 (--reasoning-parser): reasoning/reasoning_content 都计入生成
                    content = delta.get("content", "") or ""
                    reasoning = delta.get("reasoning", "") or delta.get("reasoning_content", "") or ""
                    if content or reasoning:
                        output_parts.append(content + reasoning)
                        if not ttft_recorded:
                            first_token_time = time.perf_counter()
                            ttft_recorded = True
                            result["ttft_s"] = round(first_token_time - t_start, 4)
                    fr = choices[0].get("finish_reason")
                    if fr:
                        finish_reason = fr

                # Capture usage info if provided in stream
                usage = chunk.get("usage")
                if usage:
                    result["total_tokens"] = usage.get(
                        "total_tokens", result["total_tokens"]
                    )
                    if result["completion_tokens"] == 0:
                        result["completion_tokens"] = usage.get("completion_tokens", 0)
                    if result["prompt_tokens"] == 0:
                        result["prompt_tokens"] = usage.get("prompt_tokens", 0)

        t_end = time.perf_counter()
        result["end_to_end_s"] = round(t_end - t_start, 4)
        result["generation_s"] = (
            round(t_end - first_token_time, 4)
            if ttft_recorded
            else result["end_to_end_s"]
        )
        result["finish_reason"] = finish_reason

        # Tokenize output for accurate completion count
        output_text = "".join(output_parts)
        result["response_preview"] = output_text[:100]
        if output_text.strip() and result["completion_tokens"] == 0:
            result["completion_tokens"] = tokenize(
                url, model, output_text, headers=headers
            )

        result["total_tokens"] = result["prompt_tokens"] + result["completion_tokens"]

        comp = result["completion_tokens"]
        gen_s = result["generation_s"]
        if comp > 0 and gen_s > 0:
            result["throughput_tok_s"] = round(comp / gen_s, 2)
            result["tpot_s"] = round(gen_s / comp, 4)
        result["success"] = True

    except requests.exceptions.Timeout:
        result["error"] = f"Timeout after {_timeout}s"
    except requests.exceptions.ConnectionError as e:
        result["error"] = f"ConnectionError: {e}"
    except Exception as e:
        result["error"] = str(e)

    return result


def test_non_streaming(url, model, messages, max_tokens, timeout=None, headers=None):
    """Non-streaming variant for concurrent/latency tests."""
    _timeout = timeout if timeout is not None else TIMEOUT
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
        prompt_text = messages_to_text(messages)
        result["prompt_tokens"] = tokenize(url, model, prompt_text, headers=headers)

        t0 = time.perf_counter()
        resp = requests.post(
            f"{url}/v1/chat/completions",
            json={
                "model": model,
                "messages": messages,
                "max_tokens": max_tokens,
                "temperature": 0.0,
                "stream": False,
            },
            headers=headers,
            timeout=_timeout,
        )
        elapsed = time.perf_counter() - t0
        result["latency_s"] = round(elapsed, 4)
        if resp.status_code != 200:
            result["error"] = f"HTTP {resp.status_code}: {resp.text[:200]}"
            return result
        data = resp.json()
        usage = data.get("usage", {})
        prompt_usage = usage.get("prompt_tokens", 0)
        comp_usage = usage.get("completion_tokens", 0)
        if result["prompt_tokens"] == 0 and prompt_usage > 0:
            result["prompt_tokens"] = prompt_usage
        result["completion_tokens"] = comp_usage if comp_usage > 0 else 0
        result["total_tokens"] = usage.get(
            "total_tokens", result["prompt_tokens"] + result["completion_tokens"]
        )
        comp = result["completion_tokens"]
        if comp > 0 and elapsed > 0:
            result["throughput_tok_s"] = round(comp / elapsed, 2)
        result["success"] = True
    except Exception as e:
        result["error"] = str(e)
    return result


def compute_stats(values):
    """Compute statistics: mean, median, min, max, stdev, and percentiles."""
    if not values:
        return {
            "mean": 0,
            "median": 0,
            "min": 0,
            "max": 0,
            "stdev": 0,
            "p95": 0,
            "p99": 0,
        }
    s = sorted(values)
    n = len(s)
    mean = statistics.mean(s)
    return {
        "mean": round(mean, 4),
        "median": round(statistics.median(s), 4),
        "min": round(min(s), 4),
        "max": round(max(s), 4),
        "p95": round(s[int(n * 0.95)], 4) if n >= 20 else round(s[-1], 4),
        "p99": round(s[int(n * 0.99)], 4) if n >= 100 else round(s[-1], 4),
        "stdev": round(statistics.stdev(s, xbar=mean), 4) if n >= 2 else 0,
    }


def compute_aggregate_score(scenario_results):
    """Weighted aggregate: throughput (0.7) + TTFT (0.3)."""
    throughputs = []
    ttfts = []
    for sr in scenario_results:
        if "throughput_tok_s" in sr and isinstance(sr["throughput_tok_s"], dict):
            tp = sr["throughput_tok_s"].get("mean", 0)
            if tp > 0:
                throughputs.append(tp)
        if "ttft_sec" in sr and isinstance(sr["ttft_sec"], dict):
            ttft = sr["ttft_sec"].get("mean", 999)
            if ttft > 0:
                ttfts.append(ttft)

    if not throughputs:
        return 0.0

    avg_tp = statistics.mean(throughputs)
    tp_score = min(avg_tp / 1.5, 100.0)

    if ttfts:
        avg_ttft = statistics.mean(ttfts)
        ttft_score = max(0, 100 - (avg_ttft * 1000 / 5))
    else:
        ttft_score = 50

    return round(tp_score * 0.7 + ttft_score * 0.3, 2)


def main():
    parser = argparse.ArgumentParser(
        description="Quick HTTP API probe for vLLM deployment"
    )
    parser.add_argument("--port", type=int, required=True, help="vLLM API port")
    parser.add_argument(
        "--model", type=str, default="qwen3.6-27b", help="Model name served by vLLM"
    )
    parser.add_argument("--output", type=str, default=None, help="Output JSON path")
    parser.add_argument("--host", type=str, default="localhost", help="API host")
    parser.add_argument("--quick", action="store_true", help="Skip concurrent test")
    parser.add_argument(
        "--long", action="store_true", help="Long-context mode (~2K token prompt)"
    )
    parser.add_argument(
        "--tag", type=str, default=None, help="Experiment tag for results"
    )
    args = parser.parse_args()

    url = f"http://{args.host}:{args.port}"
    model = args.model
    tag = args.tag or ("long-context" if args.long else "baseline")

    print(f"\n{'='*60}")
    print(f"vLLM Benchmark [{'长上下文' if args.long else '标准'}] [{tag}]")
    print(f"  Target: {url}")
    print(f"  Model:  {model}")
    print(f"  Time:   {datetime.now().isoformat()}")
    print(f"{'='*60}\n")

    # ── 1. Health check ──
    try:
        r = requests.get(f"{url}/v1/models", timeout=5)
        models = r.json().get("data", [])
        model_ids = [m["id"] for m in models]
        print(f"[HEALTH] Models available: {model_ids}")
        if model not in model_ids:
            print(f"[WARN]  '{model}' not found. Available: {model_ids}")
    except Exception as e:
        print(f"[ERROR] Health check failed: {e}")
        sys.exit(1)

    # ── 2. Warmup ──
    print(f"\n[WARMUP] {WARMUP} run(s)...")
    warmup_scenario = LONG_CODE_SCENARIO if args.long else SCENARIOS[0]
    for _ in range(WARMUP):
        test_streaming(
            url, model, warmup_scenario["messages"], warmup_scenario["max_tokens"]
        )

    # ── 3. Streaming scenarios ──
    scenario_results = []
    scenarios = [LONG_CODE_SCENARIO] if args.long else SCENARIOS

    for scenario in scenarios:
        name = scenario["name"]
        label = scenario["label"]
        print(f"\n[{name}] {label} ({N_RUNS} runs)...")

        ttft_values, throughput_values = [], []
        prompt_tok = 0
        for i in range(N_RUNS):
            result = test_streaming(
                url, model, scenario["messages"], scenario["max_tokens"]
            )
            if result["success"]:
                ttft_values.append(result["ttft_s"])
                throughput_values.append(result["throughput_tok_s"])
                if prompt_tok == 0:
                    prompt_tok = result["prompt_tokens"]
                comp = result["completion_tokens"]
                status = (
                    f"✓  {result['throughput_tok_s']:>6.1f} tok/s  "
                    f"TTFT={result['ttft_s']*1000:.0f}ms  "
                    f"out={comp} tok"
                )
            else:
                status = f"✗  {result['error']}"
            print(f"    Run {i+1}/{N_RUNS}: {status}")

        ttft_stats = (
            compute_stats(ttft_values)
            if ttft_values
            else {"mean": 0, "median": 0, "min": 0, "max": 0, "stdev": 0}
        )
        tp_stats = (
            compute_stats(throughput_values)
            if throughput_values
            else {"mean": 0, "median": 0, "min": 0, "max": 0, "stdev": 0}
        )

        scenario_result = {
            "scenario": name,
            "label": label,
            "n_runs": N_RUNS,
            "success_rate": f"{len(throughput_values)}/{N_RUNS}",
            "prompt_tokens": prompt_tok,
            "ttft_sec": ttft_stats,
            "throughput_tok_s": tp_stats,
        }
        scenario_results.append(scenario_result)

        print(
            f"  → Tput: {tp_stats['mean']:.1f} ± {tp_stats['stdev']:.1f} tok/s  "
            f"TTFT: {ttft_stats['mean']*1000:.0f} ± {ttft_stats['stdev']*1000:.0f} ms  "
            f"prompt={prompt_tok} tok"
        )

    # ── 4. Concurrent test (skip in long mode) ──
    if not args.quick and not args.long:
        concurrency = CONCURRENT["concurrency"]
        print(f"\n[concurrent] {CONCURRENT['label']} × {concurrency}...")
        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=concurrency) as ex:
            futures = [
                ex.submit(
                    test_non_streaming,
                    url,
                    model,
                    CONCURRENT["messages"],
                    CONCURRENT["max_tokens"],
                )
                for _ in range(concurrency)
            ]
            conc_results = [f.result() for f in as_completed(futures)]
        total_time = time.perf_counter() - t0
        successes = [r for r in conc_results if r["success"]]
        total_tokens = sum(r["completion_tokens"] for r in successes)
        combined_tp = round(total_tokens / total_time, 2) if total_time > 0 else 0
        print(
            f"  Result: {len(successes)}/{concurrency} success, "
            f"{total_tokens} tok in {total_time:.1f}s = {combined_tp} tok/s combined"
        )

        scenario_results.append(
            {
                "scenario": "concurrent",
                "label": CONCURRENT["label"],
                "concurrency": concurrency,
                "success_count": len(successes),
                "total_time_s": round(total_time, 2),
                "combined_throughput_tok_s": combined_tp,
            }
        )

    # ── 5. Aggregate score ──
    score = compute_aggregate_score(scenario_results)
    avg_tp = (
        statistics.mean(
            [
                r["throughput_tok_s"]["mean"]
                for r in scenario_results
                if "throughput_tok_s" in r
                and isinstance(r["throughput_tok_s"], dict)
                and r["throughput_tok_s"]["mean"] > 0
            ]
        )
        if scenario_results
        else 0
    )

    print(f"\n{'='*60}")
    print(f"  SCORE: {score}  |  Avg throughput: {avg_tp:.1f} tok/s")
    print(f"{'='*60}\n")

    report = {
        "tag": tag,
        "timestamp": datetime.now().isoformat(),
        "target": {"host": args.host, "port": args.port, "model": model, "url": url},
        "config": {"n_runs": N_RUNS, "warmup": WARMUP},
        "scenarios": scenario_results,
        "aggregate_score": score,
        "avg_throughput_tok_s": round(avg_tp, 2),
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"[SAVED] {args.output}")
    else:
        print(json.dumps(report, indent=2))

    return report


if __name__ == "__main__":
    main()
