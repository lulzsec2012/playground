#!/usr/bin/env python3
"""
Convert ChromeGo proxy configs to unified sing-box format.

Reads all protocol configs from chromego_configs/ and generates a complete
sing-box config.json with:
  - SOCKS5 + HTTP mixed inbound (:1080)
  - All proxy nodes converted to sing-box outbound format
  - Selector group (manual switch) + urltest group (auto speed test)
  - Routing rules (CN traffic direct, rest via proxy)

Usage:
  python3 chromego-gen-config.py                              # generate config.json
  python3 chromego-gen-config.py --output /etc/sing-box/config.json
  python3 chromego-gen-config.py --configs /path/to/chromego_configs
"""

import json
import os
import re
import sys
from urllib.parse import urlparse

import yaml


CONFIGS_DIR = os.path.join(os.path.dirname(__file__), "chromego_configs")
OUTPUT_PATH = os.path.join(CONFIGS_DIR, "config.json")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _mbps(val):
    """Parse '11 Mbps' or '11 mbps' → 11."""
    if isinstance(val, (int, float)):
        return int(val)
    m = re.search(r'(\d+(?:\.\d+)?)', str(val))
    return int(float(m.group(1))) if m else 10


def _parse_bw(bandwidth):
    if isinstance(bandwidth, dict):
        up = _mbps(bandwidth.get("up", "10 mbps"))
        down = _mbps(bandwidth.get("down", "50 mbps"))
        return up, down
    return 10, 50


def _tag(label, idx, proto):
    safe = re.sub(r'[^a-zA-Z0-9_-]', '', label.split('/')[-1] if '/' in label else label)[:20]
    return f"{proto}-{safe}-{idx}" if safe else f"{proto}-{idx}"


def _add_outbound(obs, ob, seen_servers):
    key = (ob.get("type", ""), ob.get("server", ""), ob.get("server_port", 0))
    if key not in seen_servers:
        seen_servers.add(key)
        obs.append(ob)
        return True
    return False


# ---------------------------------------------------------------------------
# Protocol converters
# ---------------------------------------------------------------------------

def convert_clash_meta(src_dir, obs, seen):
    """clash.meta2/*.yaml → hysteria / tuic outbounds"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith((".yaml", ".yml")))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            data = yaml.safe_load(f)
        if not data or "proxies" not in data:
            continue
        for p in data.get("proxies", []):
            if not isinstance(p, dict):
                continue
            ptype = p.get("type", "")
            if ptype == "hysteria":
                ob = {
                    "type": "hysteria",
                    "tag": _tag(p.get("name", ""), count, "hy1"),
                    "server": p["server"],
                    "server_port": p["port"],
                    "up_mbps": _mbps(p.get("up", "10 mbps")),
                    "down_mbps": _mbps(p.get("down", "50 mbps")),
                    "auth_str": p.get("auth-str") or p.get("auth_str", ""),
                    "tls": {
                        "enabled": True,
                        "server_name": p.get("sni", p["server"]),
                        "insecure": p.get("skip-cert-verify", True),
                        "alpn": p.get("alpn", ["h3"]),
                    },
                }
                if p.get("protocol") and p["protocol"] != "udp":
                    ob["protocol"] = p["protocol"]
                if _add_outbound(obs, ob, seen):
                    count += 1
            elif ptype == "tuic":
                ob = {
                    "type": "tuic",
                    "tag": _tag(p.get("name", ""), count, "tuic"),
                    "server": p["server"],
                    "server_port": p["port"],
                    "uuid": p.get("uuid", ""),
                    "password": p.get("password", ""),
                    "congestion_control": p.get("congestion_control", "bbr"),
                    "tls": {
                        "enabled": True,
                        "server_name": p.get("sni", p["server"]),
                        "insecure": p.get("skip-cert-verify", True),
                        "alpn": p.get("alpn", ["h3"]),
                    },
                }
                if p.get("udp_relay_mode"):
                    ob["udp_relay_mode"] = p["udp_relay_mode"]
                if _add_outbound(obs, ob, seen):
                    count += 1
    print(f"  clash.meta2/: {count} nodes (hysteria/tuic)")
    return count if count else "empty"


def convert_xray(src_dir, obs, seen):
    """xray/*.json → vless outbounds (VLESS + Reality)"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        for ob in cfg.get("outbounds", []):
            if ob.get("protocol") not in ("vless", "vmess"):
                continue
            settings = ob.get("settings", {})
            vnext = settings.get("vnext", [])
            if not vnext:
                continue
            svr = vnext[0]
            stream = ob.get("streamSettings", {})
            users = svr.get("users", [])
            user = users[0] if users else {}
            reality = stream.get("realitySettings", {})

            sing_ob = {
                "type": "vless",
                "tag": f"xray-vless-{count}",
                "server": svr["address"],
                "server_port": int(svr["port"]),
                "uuid": user.get("id", ""),
            }
            if user.get("flow"):
                sing_ob["flow"] = user["flow"]
            if stream.get("security") == "reality" and reality:
                sing_ob["tls"] = {
                    "enabled": True,
                    "server_name": reality.get("serverName", svr["address"]),
                    "utls": {"enabled": True,
                             "fingerprint": reality.get("fingerprint", "chrome")},
                    "reality": {
                        "enabled": True,
                        "public_key": reality.get("publicKey", ""),
                        "short_id": reality.get("shortId", ""),
                    },
                }
            elif stream.get("security") == "tls":
                sing_ob["tls"] = {
                    "enabled": True,
                    "server_name": (stream.get("tlsSettings") or {}).get(
                        "serverName", svr["address"]),
                    "insecure": (stream.get("tlsSettings") or {}).get(
                        "allowInsecure", False),
                }
            if _add_outbound(obs, sing_ob, seen):
                count += 1
    print(f"  xray/: {count} nodes (vless+reality)")
    return count if count else "empty"


def convert_singbox(src_dir, obs, seen):
    """singbox/*.json → extract outbounds directly (already sing-box format)"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        for i, ob in enumerate(cfg.get("outbounds", [])):
            ob_type = ob.get("type", "")
            if ob_type in ("direct", "block", "dns"):
                continue
            if not ob.get("server"):
                continue
            ob["tag"] = f"singbox-{ob_type}-{count}"
            if _add_outbound(obs, ob, seen):
                count += 1
    print(f"  singbox/: {count} nodes")
    return count if count else "empty"


def convert_hysteria2(src_dir, obs, seen):
    """hysteria2/*.json → hysteria2 outbounds"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        svr = cfg.get("server", "")
        host, port = _split_host_port(svr, 443)
        auth = cfg.get("auth", "")
        ob = {
            "type": "hysteria2",
            "tag": f"hy2-{count}",
            "server": host,
            "server_port": port,
            "password": auth,
            "tls": {
                "enabled": True,
                "server_name": (cfg.get("tls") or {}).get("sni", host),
                "insecure": (cfg.get("tls") or {}).get("insecure", True),
            },
        }
        up, down = _parse_bw(cfg.get("bandwidth", {}))
        ob["up_mbps"] = up
        ob["down_mbps"] = down
        if _add_outbound(obs, ob, seen):
            count += 1
    print(f"  hysteria2/: {count} nodes")
    return count if count else "empty"


def convert_hysteria(src_dir, obs, seen):
    """hysteria/*.json → hysteria outbounds"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        svr = cfg.get("server", "")
        host, port = _split_host_port(svr, 443)
        ob = {
            "type": "hysteria",
            "tag": f"hy1-legacy-{count}",
            "server": host,
            "server_port": port,
            "up_mbps": 10,
            "down_mbps": 50,
            "auth_str": cfg.get("auth_str") or cfg.get("auth", ""),
            "tls": {
                "enabled": True,
                "server_name": (cfg.get("tls") or {}).get("sni", host),
                "insecure": (cfg.get("tls") or {}).get("insecure", True),
            },
        }
        if _add_outbound(obs, ob, seen):
            count += 1
    print(f"  hysteria/: {count} nodes")
    return count if count else "empty"


def convert_juicity(src_dir, obs, seen):
    """juicity/*.json → juicity outbounds"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        svr = cfg.get("server", "")
        host, port = _split_host_port(svr, 443)
        ob = {
            "type": "juicity",
            "tag": f"juicity-{count}",
            "server": host,
            "server_port": port,
            "uuid": cfg.get("uuid", ""),
            "password": cfg.get("password", ""),
            "tls": {
                "enabled": True,
                "server_name": cfg.get("sni", host),
                "insecure": cfg.get("allow_insecure", True),
            },
        }
        if cfg.get("congestion_control"):
            ob["congestion_control"] = cfg["congestion_control"]
        if _add_outbound(obs, ob, seen):
            count += 1
    print(f"  juicity/: {count} nodes")
    return count if count else "empty"


def convert_naiveproxy(src_dir, obs, seen):
    """naiveproxy/*.json → naive outbounds"""
    if not os.path.isdir(src_dir):
        return "skip"
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        proxy_url = cfg.get("proxy", "")
        if not proxy_url:
            continue
        parsed = urlparse(proxy_url)
        host = parsed.hostname or ""
        port = parsed.port or 443
        ob = {
            "type": "naive",
            "tag": f"naive-{count}",
            "server": host,
            "server_port": port,
            "username": parsed.username or "",
            "password": parsed.password or "",
            "tls": {
                "enabled": True,
                "server_name": host,
            },
        }
        if _add_outbound(obs, ob, seen):
            count += 1
    print(f"  naiveproxy/: {count} nodes")
    return count if count else "empty"


def _split_host_port(s, default_port):
    """Parse 'host:port' or '[host]:port' → (host, port)"""
    s = s.strip()
    if s.startswith("["):
        m = re.match(r'\[(.+)\]:(\d+)', s)
        if m:
            return m.group(1), int(m.group(2))
        return s.strip("[]"), default_port
    parts = s.rsplit(":", 1)
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0], int(parts[1])
    return parts[0], default_port


# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------

def generate(configs_dir, output_path):
    print(f"📂 读取配置目录: {configs_dir}")
    print()

    all_outbounds = []
    seen = set()

    # Convert each protocol
    results = [
        ("Clash Meta", convert_clash_meta(os.path.join(configs_dir, "clash.meta2"), all_outbounds, seen)),
        ("Xray",       convert_xray(os.path.join(configs_dir, "xray"), all_outbounds, seen)),
        ("Sing-box",   convert_singbox(os.path.join(configs_dir, "singbox"), all_outbounds, seen)),
        ("Hysteria2",  convert_hysteria2(os.path.join(configs_dir, "hysteria2"), all_outbounds, seen)),
        ("Hysteria",   convert_hysteria(os.path.join(configs_dir, "hysteria"), all_outbounds, seen)),
        ("Juicity",    convert_juicity(os.path.join(configs_dir, "juicity"), all_outbounds, seen)),
        ("Naiveproxy", convert_naiveproxy(os.path.join(configs_dir, "naiveproxy"), all_outbounds, seen)),
    ]

    for name, result in results:
        if result == "skip":
            print(f"  {name}: ⏭️  无目录")
        elif result == "empty":
            print(f"  {name}: ⚠️  未提取到节点")

    proxy_tags = [ob["tag"] for ob in all_outbounds]
    print(f"\n📊 总计: {len(all_outbounds)} 个代理节点\n")

    if not all_outbounds:
        print("❌ 无可用节点，不生成配置")
        return False

    # Build the complete sing-box config
    config = {
        "log": {
            "level": "info",
            "output": "/var/log/sing-box.log" if os.geteuid() == 0
                      else os.path.expanduser("~/.local/share/sing-box.log"),
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "0.0.0.0",
                "listen_port": 1080,
                "sniff": True,
                "sniff_override_destination": False,
                "set_system_proxy": False,
            },
        ],
        "outbounds": all_outbounds + [
            {
                "type": "selector",
                "tag": "proxy-select",
                "outbounds": ["proxy-urltest", "direct"] + proxy_tags,
                "default": "proxy-urltest",
            },
            {
                "type": "urltest",
                "tag": "proxy-urltest",
                "outbounds": proxy_tags,
                "url": "http://cp.cloudflare.com/generate_204",
                "interval": "5m",
                "tolerance": 50,
            },
            {
                "type": "direct",
                "tag": "direct",
            },
        ],
        "route": {
            "rules": [
                {
                    "geoip": ["private"],
                    "outbound": "direct",
                },
                {
                    "geosite": "cn",
                    "outbound": "direct",
                },
                {
                    "geoip": "cn",
                    "outbound": "direct",
                },
            ],
            "final": "proxy-select",
            "auto_detect_interface": True,
        },
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": os.path.expanduser("~/.local/share/sing-box/cache.db"),
            },
            "clash_api": {
                "external_controller": "127.0.0.1:9090",
                "external_ui": "metacubexd",
                "external_ui_download_url": (
                    "https://github.com/metacubex/metacubexd/archive/refs/heads/gh-pages.zip"
                ),
                "external_ui_download_detour": "direct",
                "default_mode": "rule",
                "store_mode": True,
                "store_selected": True,
                "store_fakeip": True,
            },
        },
    }

    # Write output
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    print(f"✅ 配置生成完成: {output_path}")

    # Summary
    by_type = {}
    for ob in all_outbounds:
        t = ob["type"]
        by_type[t] = by_type.get(t, 0) + 1
    print(f"\n📋 节点类型分布:")
    for t, c in sorted(by_type.items()):
        print(f"   {t:15s} {c} 个")

    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    import argparse
    parser = argparse.ArgumentParser(description="ChromeGo → sing-box 配置转换")
    parser.add_argument("--configs", default=CONFIGS_DIR,
                        help=f"ChromeGo 配置目录 (默认 {CONFIGS_DIR})")
    parser.add_argument("--output", default=OUTPUT_PATH,
                        help=f"输出路径 (默认 {OUTPUT_PATH})")
    args = parser.parse_args()

    generate(args.configs, args.output)
    print(f"\n💡 启动 sing-box:   sing-box run -c {args.output}")
    print(f"💡 Dashboard 地址:  http://127.0.0.1:9090/ui")


if __name__ == "__main__":
    main()
