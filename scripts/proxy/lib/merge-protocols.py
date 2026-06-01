#!/usr/bin/env python3
"""
Merge ChromeGo source configs by protocol type into consolidated usable configs.

Merge strategy per format:
  1. clash.meta2/  -> merged-clash.yaml   (YAML, natively multi-proxy)
  2. xray/         -> merged-xray.json    (multi outbound + round-robin balancer)
  3. singbox/      -> merged-singbox.json (multi outbound + urltest fallback)
  4. Others        -> servers.json        (reference extraction only, no merge)

Usage:
  lib/merge-protocols.py                               # default data/chromego_configs/
  lib/merge-protocols.py <config-dir>
  lib/merge-protocols.py --skip-clash                  # skip Clash merge
  lib/merge-protocols.py --skip-xray                   # skip Xray merge
  lib/merge-protocols.py --skip-singbox                # skip Sing-box merge
"""

import json
import os
import re
import sys

import yaml


def _yaml_quote(name):
    if not name:
        return "''"
    if re.search(r': |[@#\[\]{}!*|>\'",?$`]', name) or name.startswith(
        ("-", "?", "&", ":")
    ):
        return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return name


def _write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"  ✅ {path}")


def _write_yaml(path, data):
    with open(path, "w") as f:
        yaml.dump(
            data,
            f,
            allow_unicode=True,
            default_flow_style=False,
            sort_keys=False,
            width=4096,
            indent=2,
        )
    print(f"  ✅ {path}")


# ═══════════ 1. Clash Meta ═══════════


def merge_clash(configs_dir, output_dir):
    src_dir = os.path.join(configs_dir, "clash.meta2")
    if not os.path.isdir(src_dir):
        print("  ⏭️  无 clash.meta2/，跳过")
        return

    yaml_files = sorted(f for f in os.listdir(src_dir) if f.endswith((".yaml", ".yml")))
    if not yaml_files:
        print("  ⏭️  无 YAML 文件，跳过")
        return

    all_proxies = []
    seen_servers = set()  # dedup by (server, port, type)

    for fn in yaml_files:
        fp = os.path.join(src_dir, fn)
        try:
            with open(fp) as f:
                data = yaml.safe_load(f)
        except yaml.YAMLError as e:
            print(f"  ⚠️  解析失败 {fn}: {e}")
            continue
        if not data or "proxies" not in data:
            continue
        for p in data["proxies"]:
            if isinstance(p, dict) and "name" in p:
                key = (p.get("server", ""), p.get("port", ""), p.get("type", ""))
                if key not in seen_servers:
                    seen_servers.add(key)
                    # dedup by server+port, so proxy name may not be unique
                    all_proxies.append(p)

    if not all_proxies:
        print("  ⚠️  未提取到有效代理节点")
        return

    proxy_names = [p["name"] for p in all_proxies]
    print(f"  提取 {len(all_proxies)} 个代理节点（来自 {len(yaml_files)} 个文件）")

    config = {
        "port": 7890,
        "socks-port": 7891,
        "allow-lan": True,
        "mode": "Rule",
        "log-level": "info",
        "external-controller": ":9090",
        "proxies": all_proxies,
        "proxy-groups": [
            {
                "name": "🚀 手动切换",
                "type": "select",
                "proxies": ["♻️ 自动选择", "🎯 全球直连"] + proxy_names,
            },
            {
                "name": "♻️ 自动选择",
                "type": "url-test",
                "url": "http://cp.cloudflare.com/generate_204",
                "interval": 300,
                "tolerance": 50,
                "proxies": proxy_names,
            },
            {"name": "🎯 全球直连", "type": "select", "proxies": ["DIRECT"]},
        ],
        "rules": [
            "DOMAIN-SUFFIX,cn,DIRECT",
            "DOMAIN-KEYWORD,baidu,DIRECT",
            "IP-CIDR,10.0.0.0/8,DIRECT",
            "IP-CIDR,172.16.0.0/12,DIRECT",
            "IP-CIDR,192.168.0.0/16,DIRECT",
            "IP-CIDR,100.64.0.0/10,DIRECT",
            "IP-CIDR,17.0.0.0/8,DIRECT",
            "MATCH,🚀 手动切换",
        ],
    }

    out_path = os.path.join(output_dir, "merged-clash.yaml")
    _write_yaml(out_path, config)


# ═══════════ 2. Xray ═══════════


def merge_xray(configs_dir, output_dir):
    src_dir = os.path.join(configs_dir, "xray")
    if not os.path.isdir(src_dir):
        print("  ⏭️  无 xray/，跳过")
        return

    json_files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    if not json_files:
        print("  ⏭️  无 JSON 文件，跳过")
        return

    all_outbounds = []
    seen_servers = set()

    for fn in json_files:
        fp = os.path.join(src_dir, fn)
        try:
            with open(fp) as f:
                cfg = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            print(f"  ⚠️  解析失败 {fn}: {e}")
            continue

        outbounds = cfg.get("outbounds", [])
        for ob in outbounds:
            protocol = ob.get("protocol", "")
            if protocol in ("freedom", "blackhole", "dns"):
                continue
            settings = ob.get("settings", {})
            vnext = settings.get("vnext") or settings.get("servers")
            if vnext:
                server = vnext[0].get("address", "")
                port = vnext[0].get("port", 0)
                key = (server, port)
                if key not in seen_servers:
                    seen_servers.add(key)
                    ob["tag"] = f"proxy-{len(all_outbounds)}"
                    all_outbounds.append(ob)
                    print(f"    + {protocol} {server}:{port}")
            else:
                svr = ob.get("server") or settings.get("server", "")
                port = ob.get("port") or settings.get("port", 0)
                if svr:
                    key = (svr, port) if isinstance(svr, str) else (str(svr), port)
                    if key not in seen_servers:
                        seen_servers.add(key)
                        ob["tag"] = f"proxy-{len(all_outbounds)}"
                        all_outbounds.append(ob)
                        print(f"    + {protocol} {svr}:{port}")

    if not all_outbounds:
        print("  ⚠️  未提取到有效 outbound")
        return

    first_cfg = json.load(open(os.path.join(src_dir, json_files[0])))
    inbounds = first_cfg.get("inbounds", [])
    balancer_selectors = [ob["tag"] for ob in all_outbounds]

    merged = {
        "log": first_cfg.get("log", {}),
        "inbounds": inbounds,
        "outbounds": all_outbounds + [{"protocol": "freedom", "tag": "direct"}],
        "routing": {
            "domainStrategy": "AsIs",
            "balancers": [
                {
                    "tag": "loadbalance",
                    "selector": balancer_selectors,
                    "strategy": {"type": "roundRobin"},
                }
            ],
            "rules": [
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:private", "geoip:cn"],
                },
                {"type": "field", "outboundTag": "direct", "domain": ["geosite:cn"]},
                {"type": "field", "balancerTag": "loadbalance", "network": "tcp,udp"},
            ],
        },
    }

    out_path = os.path.join(output_dir, "merged-xray.json")
    _write_json(out_path, merged)
    print(f"    合并 {len(all_outbounds)} 个服务器，round-robin 负载均衡")


# ═══════════ 3. Sing-box ═══════════


def merge_singbox(configs_dir, output_dir):
    src_dir = os.path.join(configs_dir, "singbox")
    if not os.path.isdir(src_dir):
        print("  ⏭️  无 singbox/，跳过")
        return

    json_files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    if not json_files:
        print("  ⏭️  无 JSON 文件，跳过")
        return

    all_outbounds = []
    seen_servers = set()

    for fn in json_files:
        fp = os.path.join(src_dir, fn)
        try:
            with open(fp) as f:
                cfg = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            print(f"  ⚠️  解析失败 {fn}: {e}")
            continue

        outbounds = cfg.get("outbounds", [])
        for ob in outbounds:
            ob_type = ob.get("type", "")
            if ob_type in ("direct", "block", "dns"):
                continue
            server = ob.get("server", "")
            port = ob.get("server_port", 0)
            if not server:
                continue
            key = (server, port)
            if key not in seen_servers:
                seen_servers.add(key)
                ob["tag"] = f"proxy-{len(all_outbounds)}"
                all_outbounds.append(ob)
                print(f"    + {ob_type} {server}:{port}")

    if not all_outbounds:
        print("  ⚠️  未提取到有效 outbound")
        return

    first_cfg = json.load(open(os.path.join(src_dir, json_files[0])))
    inbounds = first_cfg.get("inbounds", [])
    selectors = [ob["tag"] for ob in all_outbounds]

    merged = {
        "log": first_cfg.get("log", {}),
        "inbounds": inbounds,
        "outbounds": (
            all_outbounds
            + [{"type": "direct", "tag": "direct"}]
            + [
                {
                    "type": "urltest",
                    "tag": "urltest",
                    "outbounds": selectors,
                    "url": "http://cp.cloudflare.com/generate_204",
                    "interval": "5m",
                    "tolerance": 50,
                }
            ]
        ),
        "route": {
            "rules": [
                {
                    "inbound": [ib.get("tag") for ib in inbounds if ib.get("tag")],
                    "action": "sniff",
                },
                {"ip_is_private": True, "outbound": "direct"},
            ],
            "final": "urltest",
        },
    }

    out_path = os.path.join(output_dir, "merged-singbox.json")
    _write_json(out_path, merged)
    print(f"    合并 {len(all_outbounds)} 个服务器，urltest 自动优选")


# ═══════════ 4. Servers Summary ═══════════


def _protocol_from_path(path):
    parts = path.split(os.sep)
    try:
        idx = parts.index("chromego_configs")
        return parts[idx + 1] if idx + 1 < len(parts) else "unknown"
    except ValueError:
        return "unknown"


def extract_servers(configs_dir, output_dir):
    servers = []

    for root, dirs, files in os.walk(configs_dir):
        proto = _protocol_from_path(root)
        if not files:
            continue

        for fn in sorted(files):
            if not fn.endswith((".json", ".yaml", ".yml")):
                continue
            if fn.startswith("merged-"):
                continue  # skip merged output files
            fp = os.path.join(root, fn)

            try:
                with open(fp) as f:
                    if fn.endswith((".yaml", ".yml")):
                        data = yaml.safe_load(f)
                    else:
                        data = json.load(f)
            except Exception as e:
                servers.append({"source": fn, "protocol": proto, "error": str(e)})
                continue

            if not isinstance(data, dict):
                continue

            if "proxies" in data and isinstance(data["proxies"], list):
                for p in data["proxies"]:
                    if isinstance(p, dict) and "server" in p:
                        servers.append(
                            {
                                "source": fn,
                                "protocol": f"clash-{p.get('type', '?')}",
                                "server": f'{p.get("server", "")}:{p.get("port", "")}',
                                "name": p.get("name", ""),
                            }
                        )
                continue

            if "outbounds" in data:
                info = _extract_outbound_info(data)
                if info:
                    servers.append({"source": fn, "protocol": proto, **info})
                continue

            info = _extract_simple_server(data)
            if info:
                servers.append({"source": fn, "protocol": proto, **info})

    if not servers:
        print("  ⚠️  未提取到服务器信息")
        return

    out_path = os.path.join(output_dir, "servers.json")
    _write_json(out_path, {"count": len(servers), "servers": servers})
    print(
        f"    共 {len(servers)} 条记录（{len(set(s['protocol'] for s in servers))} 种协议）"
    )


def _extract_outbound_info(data):
    for ob in data.get("outbounds", []):
        ob_type = ob.get("type") or ob.get("protocol", "")
        if ob_type in ("direct", "freedom", "blackhole", "dns", "block"):
            continue
        settings = ob.get("settings", {})
        vnext = settings.get("vnext") or settings.get("servers")
        if vnext:
            svr = vnext[0].get("address", "")
            port = vnext[0].get("port", 0)
            return {"server": f"{svr}:{port}", "protocol": ob_type}
        svr = ob.get("server") or settings.get("server", "")
        port = ob.get("port") or ob.get("server_port") or settings.get("port", 0)
        if svr:
            return {"server": f"{svr}:{port}", "protocol": ob_type}
    return None


def _extract_simple_server(data):
    svr = data.get("server", "") or data.get("proxy", "")
    if not svr:
        profiles = data.get("profiles", [])
        if profiles:
            for p in profiles:
                servers = p.get("servers", [])
                for s in servers:
                    ip = s.get("ipAddress", "")
                    bindings = s.get("portBindings", [])
                    if ip and bindings:
                        return {"server": f"{ip}:{bindings[0].get('port', '')}"}
        return None
    auth = data.get("auth") or data.get("password") or ""
    return {
        "server": svr,
        "auth": auth[:30] + "..." if len(str(auth)) > 30 else str(auth),
    }


# ═══════════ Main ═══════════


def main():
    import argparse

    parser = argparse.ArgumentParser(description="ChromeGo 配置合并工具")
    parser.add_argument(
        "configs_dir",
        nargs="?",
        default=os.path.join(os.path.dirname(__file__), "chromego_configs"),
    )
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--skip-clash", action="store_true")
    parser.add_argument("--skip-xray", action="store_true")
    parser.add_argument("--skip-singbox", action="store_true")
    parser.add_argument("--skip-servers", action="store_true")
    args = parser.parse_args()

    configs_dir = args.configs_dir
    output_dir = args.output_dir or configs_dir

    if not os.path.isdir(configs_dir):
        print(f"❌ 目录不存在: {configs_dir}")
        sys.exit(1)

    print(f"📂 输入: {configs_dir}")
    print(f"📂 输出: {output_dir}")
    print()

    if not args.skip_clash:
        print("🔀 [1/4] 合并 Clash Meta 配置…")
        merge_clash(configs_dir, output_dir)

    if not args.skip_xray:
        print("🔀 [2/4] 合并 Xray 配置…")
        merge_xray(configs_dir, output_dir)

    if not args.skip_singbox:
        print("🔀 [3/4] 合并 Sing-box 配置…")
        merge_singbox(configs_dir, output_dir)

    if not args.skip_servers:
        print("📋 [4/4] 提取所有服务器信息…")
        extract_servers(configs_dir, output_dir)

    print()
    print("✅ 合并完成")
    print(f"   输出目录: {output_dir}")
    print(f"   merged-clash.yaml   — Clash Meta 聚合配置（可直接用于 mihomo）")
    print(f"   merged-xray.json    — Xray 聚合配置（多 outbound + round-robin）")
    print(f"   merged-singbox.json — Sing-box 聚合配置（多 outbound + urltest）")
    print(f"   servers.json        — 所有服务器参考清单")


if __name__ == "__main__":
    main()
