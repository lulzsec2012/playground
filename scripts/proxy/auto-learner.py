#!/usr/bin/env python3
"""auto-learner.py — 监听 Clash API 日志，检测到失败自动调用 proxy-fix"""

import json, os, signal, subprocess, time, urllib.request, re

CLASH_API = "http://127.0.0.1:9090"
LEARNED_PATH = "/etc/sing-box/learned_domains.json"
FAIL_COOLDOWN = 300


def log(msg):
    print("[auto-learner] {}".format(msg), flush=True)


def stream_logs():
    req = urllib.request.Request(CLASH_API + "/logs")
    try:
        resp = urllib.request.urlopen(req, timeout=None)
        buf = ""
        while True:
            chunk = resp.read(4096).decode()
            if not chunk:
                break
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    if line.startswith("data:"):
                        try:
                            yield json.loads(line[5:].strip())
                        except json.JSONDecodeError:
                            pass
    except Exception as e:
        log("stream: {}".format(e))
        yield None


def extract_domain(payload):
    m = re.search(r"connection to ([^:\s]+):\d+", payload)
    if m:
        d = m.group(1)
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", d):
            return d
    return None


def get_learned():
    try:
        with open(LEARNED_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_learned(learned):
    with open(LEARNED_PATH, "w") as f:
        json.dump(learned, f, indent=2)


def main():
    log("started, watching {} ...".format(CLASH_API))
    learned = get_learned()
    log("loaded {} learned domains".format(len(learned)))
    retry_sec = 1

    while True:
        try:
            for entry in stream_logs():
                if entry is None:
                    retry_sec = min(retry_sec * 2, 30)
                    log("reconnect in {}s ...".format(retry_sec))
                    time.sleep(retry_sec)
                    break
                retry_sec = 1

                if entry.get("type") not in ("error", "warning"):
                    continue

                domain = extract_domain(entry.get("payload", ""))
                if not domain:
                    continue

                now = time.time()
                info = learned.get(domain)
                if info:
                    if info.get("group"):
                        if now - info.get("learned_at", 0) < FAIL_COOLDOWN:
                            continue
                    if info.get("group") is None:
                        if now - info.get("failed_at", 0) < FAIL_COOLDOWN:
                            continue

                log("detected: {} -> running proxy-fix".format(domain))
                learned[domain] = {"group": "testing", "learned_at": now}
                save_learned(learned)

                r = subprocess.run(
                    ["proxy-fix", domain],
                    capture_output=True, text=True, timeout=120
                )
                for line in r.stdout.strip().split("\n"):
                    if line.strip():
                        log(line)
                if r.returncode == 0:
                    log("done: {}".format(domain))
                else:
                    log("failed: {} (all proxies unreachable)".format(domain))

        except KeyboardInterrupt:
            log("exit")
            break
        except Exception as e:
            log("error: {}".format(e))
            time.sleep(5)


if __name__ == "__main__":
    main()
