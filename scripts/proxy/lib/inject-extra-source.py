#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
import urllib.error

AU1RXX_URL = "https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/singbox.json"
CACHE_FILE = os.path.join(os.path.dirname(__file__), "..", "data", ".au1rxx-cache.json")

NON_PROXY_TYPES = {"selector", "urltest", "direct", "block", "dns", "dns-stub"}


def fetch_singbox(timeout=15):
    req = urllib.request.Request(AU1RXX_URL, headers={"User-Agent": "curl/8.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
        with open(CACHE_FILE, "w") as f:
            json.dump(data, f)
        return data
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as e:
        if os.path.exists(CACHE_FILE):
            print(f"  \u26a0\ufe0f  \u4e0b\u8f7d\u5931\u8d25 ({e})\uff0c\u4f7f\u7528\u672c\u5730\u7f13\u5b58", file=sys.stderr)
            with open(CACHE_FILE) as f:
                return json.load(f)
        raise


def load_local_cache():
    if not os.path.exists(CACHE_FILE):
        return None
    with open(CACHE_FILE) as f:
        return json.load(f)


def is_proxy_outbound(ob):
    return ob.get("type", "") not in NON_PROXY_TYPES and "server" in ob and "server_port" in ob


def dedup_key(ob):
    return (ob.get("type", ""), ob.get("server", ""), ob.get("server_port", 0))


def build_dedup_set(outbounds):
    seen = set()
    for ob in outbounds:
        if is_proxy_outbound(ob):
            seen.add(dedup_key(ob))
    return seen


def merge_extra_outbounds(config, extra_data):
    extra_outbounds = extra_data.get("outbounds", [])
    if not extra_outbounds:
        print("  WARN: Au1rxx source has no outbounds", file=sys.stderr)
        return 0, 0

    proxy_candidates = [ob for ob in extra_outbounds if is_proxy_outbound(ob)]
    total_extra = len(proxy_candidates)
    if not proxy_candidates:
        print("  WARN: Au1rxx source has no usable proxies", file=sys.stderr)
        return 0, 0

    existing = config.get("outbounds", [])
    seen = build_dedup_set(existing)

    new_outbounds = []
    for ob in proxy_candidates:
        key = dedup_key(ob)
        if key not in seen:
            seen.add(key)
            tag = ob.get("tag", "")
            if tag and not tag.startswith("au1rxx-"):
                ob["tag"] = f"au1rxx-{tag}"
            elif not tag:
                ob["tag"] = f"au1rxx-{key[0]}-{key[1]}-{key[2]}"
            new_outbounds.append(ob)

    if not new_outbounds:
        print("  Au1rxx nodes already exist, nothing new")
        return 0, total_extra

    config["outbounds"] = existing + new_outbounds

    new_tags = [ob["tag"] for ob in new_outbounds]
    for ob in config.get("outbounds", []):
        if ob.get("tag") == "proxy-select" and "outbounds" in ob:
            out_list = ob["outbounds"]
            insert_pos = len(out_list)
            for i, t in enumerate(out_list):
                if t == "proxy-urltest":
                    insert_pos = i + 1
                    break
            ob["outbounds"] = out_list[:insert_pos] + new_tags + out_list[insert_pos:]
        if ob.get("tag") == "proxy-urltest" and "outbounds" in ob:
            ob["outbounds"].extend(new_tags)

    return len(new_outbounds), total_extra


def main():
    args = sys.argv[1:]
    check_only = "--check" in args
    skip_download = "--skip-download" in args
    args = [a for a in args if not a.startswith("--")]

    if not args:
        print("用法: lib/inject-extra-source.py [--check] [--skip-download] <config.json>", file=sys.stderr)
        sys.exit(1)

    config_path = args[0]
    if not os.path.exists(config_path):
        print(f"错误: 文件不存在 {config_path}", file=sys.stderr)
        sys.exit(1)

    with open(config_path) as f:
        config = json.load(f)

    print("--- inject-extra-source ---")
    print()
    print(f"  source: {AU1RXX_URL}")

    try:
        if skip_download:
            extra_data = load_local_cache()
            if extra_data is None:
                print("  WARN: no local cache, run without --skip-download first", file=sys.stderr)
                sys.exit(1)
            print("  using local cache")
        else:
            extra_data = fetch_singbox()
            print("  download ok")
    except Exception as e:
        print(f"  FAIL: fetch source failed: {e}", file=sys.stderr)
        sys.exit(1)

    extra_outbounds = extra_data.get("outbounds", [])
    proxy_count = sum(1 for ob in extra_outbounds if is_proxy_outbound(ob))
    print(f"  Au1rxx: {len(extra_outbounds)} outbounds, {proxy_count} proxy nodes")
    print()

    added, total = merge_extra_outbounds(config, extra_data)
    print(f"  added {added}/{total} new nodes")
    print()

    if check_only:
        print("check mode, not written")
        return

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    print(f"updated: {config_path}")


if __name__ == "__main__":
    main()
