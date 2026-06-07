#!/usr/bin/env python3
"""Convert ChromeGo + Clash proxy configs to unified sing-box format with multi-group routing.

Features:
  - SOCKS5 + HTTP mixed inbound (:1080)
  - Parse ChromeGo protocols: xray (vless/vmess), hysteria, hysteria2, singbox,
    clash.meta (hysteria/tuic), juicity, naiveproxy
  - Parse Clash YAML proxies: ss, vmess, trojan, hysteria, hysteria2, vless,
    tuic, socks5, http
  - Multi-group routing: YouTube, GitHub, Telegram, AI (each with urltest +
    selector for manual override) + fallback for everything else
  - Per-site domain routing rules
  - Clash Dashboard (port 9090) with full selector support
  - CN traffic direct via geoip/geosite (auto-downloads databases)
  - Deduplication of proxy nodes (server:port key)

Usage:
  # ChromeGo only (legacy behavior)
  python3 chromego-gen-config.py

  # ChromeGo + Clash nodes (multi-group routing)
  python3 chromego-gen-config.py --proxy-yaml ../config.yaml

  # Full options
  python3 chromego-gen-config.py \\
    --configs /path/to/chromego_configs \\
    --proxy-yaml /path/to/clash.yaml \\
    --output /etc/sing-box/config.json \\
    --listen 0.0.0.0 --port 1080 \\
    --dashboard-port 9090
"""

import json
import os
import re

import yaml


CONFIGS_DIR = os.path.join(os.path.dirname(__file__), "chromego_configs")
OUTPUT_PATH = os.path.join(CONFIGS_DIR, "config.json")

FALLBACK_KEY = "fallback"
SITE_GROUPS_FILE = os.path.join(os.path.dirname(__file__), "site-groups.yaml")

# Hardcoded fallback when no site-groups.yaml exists
_FALLBACK_SITE_GROUPS = {
    "yt": {
        "label": "YouTube",
        "test_url": "http://cp.cloudflare.com/generate_204",
        "domains": [
            "youtube.com",
            "googlevideo.com",
            "ytimg.com",
            "youtu.be",
            "ggpht.com",
            "withgoogle.com",
        ],
    },
    "gh": {
        "label": "GitHub",
        "test_url": "http://cp.cloudflare.com/generate_204",
        "domains": [
            "github.com",
            "githubassets.com",
            "raw.githubusercontent.com",
            "githubusercontent.com",
            "github.io",
            "githubapp.com",
        ],
    },
    "tg": {
        "label": "Telegram",
        "test_url": "http://cp.cloudflare.com/generate_204",
        "domains": [
            "t.me",
            "telegram.org",
            "telegram.me",
            "telesco.pe",
        ],
    },
    "ai": {
        "label": "AI",
        "test_url": "http://cp.cloudflare.com/generate_204",
        "domains": [
            "openai.com",
            "chatgpt.com",
            "ai.com",
            "copilot.microsoft.com",
            "bing.com",
        ],
    },
}


def load_site_groups(path=None):
    """Load site groups from YAML config, falling back to hardcoded defaults."""
    if path and os.path.isfile(path):
        print(f"Loading site groups: {path}")
        with open(path) as f:
            data = yaml.safe_load(f)
        if data:
            return data
    default_path = os.path.join(os.path.dirname(__file__), "site-groups.yaml")
    if default_path != path and os.path.isfile(default_path):
        print(f"Loading site groups: {default_path}")
        with open(default_path) as f:
            data = yaml.safe_load(f)
        if data:
            return data
    print("No site-groups.yaml found, using hardcoded defaults")
    return _FALLBACK_SITE_GROUPS


def _mbps(val):
    if isinstance(val, (int, float)):
        return int(val)
    m = re.search(r"(\d+(?:\.\d+)?)", str(val))
    return int(float(m.group(1))) if m else 10


def _parse_bw(bandwidth):
    if isinstance(bandwidth, dict):
        up = _mbps(bandwidth.get("up", "10 mbps"))
        down = _mbps(bandwidth.get("down", "50 mbps"))
        return up, down
    return 10, 50


def _tag(label, idx, prefix):
    safe = re.sub(
        r"[^a-zA-Z0-9_-]", "", label.split("/")[-1] if "/" in label else label
    )[:30]
    return f"{prefix}-{safe}-{idx}" if safe else f"{prefix}-{idx}"


def _add_outbound(obs, ob, seen_servers):
    key = (ob.get("type", ""), ob.get("server", ""), ob.get("server_port", 0))
    if key not in seen_servers:
        seen_servers.add(key)
        obs.append(ob)
        return True
    return False


def _split_host_port(s, default_port):
    s = s.strip()
    if s.startswith("["):
        m = re.match(r"\[(.+)\]:(\d+)", s)
        if m:
            return m.group(1), int(m.group(2))
        return s.strip("[]"), default_port
    parts = s.rsplit(":", 1)
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0], int(parts[1])
    return parts[0], default_port


# ---------- ChromeGo protocol converters ----------


def convert_clash_meta(src_dir, obs, seen, counter):
    """Parse clash.meta2 YAML files to sing-box hysteria/tuic outbounds."""
    if not os.path.isdir(src_dir):
        return 0
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
            idx = next(counter)
            if ptype == "hysteria":
                ob = {
                    "type": "hysteria",
                    "tag": _tag(p.get("name", ""), idx, "hy1"),
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
                    "tag": _tag(p.get("name", ""), idx, "tuic"),
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
    return count


def convert_xray(src_dir, obs, seen, counter):
    """Parse Xray JSON configs to sing-box vless outbounds (supports reality/tls)."""
    if not os.path.isdir(src_dir):
        return 0
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

            idx = next(counter)
            sing_ob = {
                "type": "vless",
                "tag": f"xray-vless-{idx}",
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
                    "utls": {
                        "enabled": True,
                        "fingerprint": reality.get("fingerprint", "chrome"),
                    },
                    "reality": {
                        "enabled": True,
                        "public_key": reality.get("publicKey", ""),
                        "short_id": reality.get("shortId", ""),
                    },
                }
            elif stream.get("security") == "tls":
                sing_ob["tls"] = {
                    "enabled": True,
                    "server_name": (
                        (stream.get("tlsSettings") or {}).get(
                            "serverName", svr["address"]
                        )
                    ),
                    "insecure": (
                        (stream.get("tlsSettings") or {}).get("allowInsecure", False)
                    ),
                }
            if _add_outbound(obs, sing_ob, seen):
                count += 1
    print(f"  xray/: {count} nodes (vless+reality)")
    return count


def convert_singbox(src_dir, obs, seen, counter):
    """Copy sing-box format outbounds directly (already compatible)."""
    if not os.path.isdir(src_dir):
        return 0
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        for ob in cfg.get("outbounds", []):
            if ob.get("type") in ("direct", "block", "dns"):
                continue
            if not ob.get("server"):
                continue
            idx = next(counter)
            ob["tag"] = f"singbox-{idx}"
            if _add_outbound(obs, ob, seen):
                count += 1
    print(f"  singbox/: {count} nodes")
    return count


def convert_hysteria2(src_dir, obs, seen, counter):
    if not os.path.isdir(src_dir):
        return 0
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        svr = cfg.get("server", "")
        host, port = _split_host_port(svr, 443)
        auth = cfg.get("auth", "")
        idx = next(counter)
        ob = {
            "type": "hysteria2",
            "tag": f"hy2-{idx}",
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
    return count


def convert_hysteria(src_dir, obs, seen, counter):
    if not os.path.isdir(src_dir):
        return 0
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    count = 0
    for fn in files:
        fp = os.path.join(src_dir, fn)
        with open(fp) as f:
            cfg = json.load(f)
        svr = cfg.get("server", "")
        host, port = _split_host_port(svr, 443)
        idx = next(counter)
        ob = {
            "type": "hysteria",
            "tag": f"hy1-legacy-{idx}",
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
    return count


def convert_juicity(src_dir, obs, seen, counter):
    """DEPRECATED: juicity removed in sing-box 1.11+. Skip all nodes."""
    if not os.path.isdir(src_dir):
        return 0
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    if files:
        print(
            f"  juicity/: {len(files)} nodes (SKIPPED - deprecated in sing-box 1.11+)"
        )
    return 0


def convert_naiveproxy(src_dir, obs, seen, counter):
    """DEPRECATED: naive removed in sing-box 1.11+. Skip all nodes."""
    if not os.path.isdir(src_dir):
        return 0
    files = sorted(f for f in os.listdir(src_dir) if f.endswith(".json"))
    if files:
        print(
            f"  naiveproxy/: {len(files)} nodes (SKIPPED - deprecated in sing-box 1.11+)"
        )
    return 0


# ---------- Clash YAML conversion ----------


def _clash_tls(p):
    """Build tls block from Clash proxy dict. Returns None if no TLS."""
    if not p.get("tls") and not p.get("sni") and not p.get("servername"):
        return None
    tls = {
        "enabled": True,
        "server_name": p.get("sni") or p.get("servername") or p.get("server", ""),
        "insecure": p.get("skip-cert-verify", False),
    }
    if p.get("alpn"):
        tls["alpn"] = p["alpn"] if isinstance(p["alpn"], list) else [p["alpn"]]
    return tls


def _clash_ws(p):
    ws_opts = p.get("ws-opts") or {}
    network = p.get("network", "tcp")
    if network != "ws":
        return None
    return {
        "type": "ws",
        "path": ws_opts.get("path", p.get("ws-path", "/")),
        "headers": ws_opts.get("headers", {}),
        "max_early_data": ws_opts.get("max-early-data", 0),
        "early_data_header_name": ws_opts.get("early-data-header-name", ""),
    }


def _clash_grpc(p):
    grpc_opts = p.get("grpc-opts") or {}
    network = p.get("network", "tcp")
    if network != "grpc":
        return None
    return {
        "type": "grpc",
        "service_name": grpc_opts.get("grpc-service-name", ""),
    }


def _clash_transport(p):
    ws = _clash_ws(p)
    if ws:
        return ws
    return _clash_grpc(p)


def _convert_clash_proxy(p, idx):
    """Convert single Clash proxy dict to sing-box outbound dict. Returns None if type unsupported."""
    ptype = p.get("type", "")
    tag = _tag(p.get("name", ""), idx, "clash")

    if ptype == "ss":
        ob = {
            "type": "shadowsocks",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "method": p.get("cipher", "aes-256-gcm"),
            "password": p.get("password", ""),
        }
        return ob

    elif ptype == "vmess":
        ob = {
            "type": "vmess",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "uuid": p.get("uuid", ""),
            "security": p.get("cipher", "auto"),
        }
        tls = _clash_tls(p)
        if tls:
            ob["tls"] = tls
        transport = _clash_transport(p)
        if transport:
            ob["transport"] = transport
        if p.get("packet-encoding"):
            ob["packet_encoding"] = p["packet-encoding"]
        return ob

    elif ptype == "trojan":
        ob = {
            "type": "trojan",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "password": p.get("password", ""),
        }
        tls = _clash_tls(p)
        if tls:
            ob["tls"] = tls
        transport = _clash_transport(p)
        if transport:
            ob["transport"] = transport
        return ob

    elif ptype == "hysteria":
        ob = {
            "type": "hysteria",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "up_mbps": _mbps(p.get("up", "10 mbps")),
            "down_mbps": _mbps(p.get("down", "50 mbps")),
            "auth_str": p.get("auth-str") or p.get("auth_str", ""),
        }
        tls = _clash_tls(p)
        ob["tls"] = tls or {
            "enabled": True,
            "server_name": p.get("server", ""),
            "insecure": True,
        }
        if p.get("protocol") and p["protocol"] != "udp":
            ob["protocol"] = p["protocol"]
        if p.get("recv_window_conn"):
            ob["recv_window_conn"] = p["recv_window_conn"]
        if p.get("recv_window"):
            ob["recv_window"] = p["recv_window"]
        if p.get("obfs"):
            ob["obfs"] = p["obfs"]
        return ob

    elif ptype == "hysteria2":
        ob = {
            "type": "hysteria2",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "password": p.get("password", ""),
        }
        tls = _clash_tls(p)
        ob["tls"] = tls or {
            "enabled": True,
            "server_name": p.get("server", ""),
            "insecure": True,
        }
        if p.get("up") or p.get("down"):
            ob["up_mbps"] = _mbps(p.get("up", "0"))
            ob["down_mbps"] = _mbps(p.get("down", "0"))
        return ob

    elif ptype == "vless":
        ob = {
            "type": "vless",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "uuid": p.get("uuid", ""),
        }
        tls = _clash_tls(p)
        if tls:
            ob["tls"] = tls
        transport = _clash_transport(p)
        if transport:
            ob["transport"] = transport
        if p.get("flow"):
            ob["flow"] = p["flow"]
        if p.get("packet-encoding"):
            ob["packet_encoding"] = p["packet-encoding"]
        reality_opts = p.get("reality-opts") or {}
        if reality_opts.get("public-key"):
            ob["tls"] = ob.get("tls", {})
            ob["tls"]["enabled"] = True
            ob["tls"]["server_name"] = (
                p.get("sni") or p.get("servername") or p["server"]
            )
            ob["tls"]["utls"] = {
                "enabled": True,
                "fingerprint": reality_opts.get("fingerprint", "chrome"),
            }
            ob["tls"]["reality"] = {
                "enabled": True,
                "public_key": reality_opts["public-key"],
                "short_id": reality_opts.get("short-id", ""),
            }
        return ob

    elif ptype == "tuic":
        ob = {
            "type": "tuic",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
            "uuid": p.get("uuid", ""),
            "password": p.get("password", ""),
            "congestion_control": p.get("congestion-control", "bbr"),
        }
        tls = _clash_tls(p)
        ob["tls"] = tls or {
            "enabled": True,
            "server_name": p.get("server", ""),
            "insecure": True,
        }
        if p.get("udp-relay-mode"):
            ob["udp_relay_mode"] = p["udp-relay-mode"]
        if p.get("alpn"):
            ob["tls"]["alpn"] = (
                p["alpn"] if isinstance(p["alpn"], list) else [p["alpn"]]
            )
        if p.get("reduce-rtt"):
            ob["reduce_rtt"] = p["reduce-rtt"]
        if p.get("request-timeout"):
            ob["request_timeout"] = p["request-timeout"]
        return ob

    elif ptype == "socks5":
        ob = {
            "type": "socks",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
        }
        if p.get("username"):
            ob["username"] = p["username"]
        if p.get("password"):
            ob["password"] = p["password"]
        return ob

    elif ptype == "http":
        ob = {
            "type": "http",
            "tag": tag,
            "server": p["server"],
            "server_port": p["port"],
        }
        if p.get("username"):
            ob["username"] = p["username"]
        if p.get("password"):
            ob["password"] = p["password"]
        tls = _clash_tls(p)
        if tls:
            ob["tls"] = tls
        return ob

    return None


def convert_clash_yaml(yaml_path, obs, seen, counter):
    if not os.path.isfile(yaml_path):
        return 0
    with open(yaml_path) as f:
        data = yaml.safe_load(f)
    if not data:
        return 0
    proxies = data.get("proxies", [])
    if not proxies:
        return 0
    count = 0
    for p in proxies:
        if not isinstance(p, dict):
            continue
        ob = _convert_clash_proxy(p, next(counter))
        if ob and _add_outbound(obs, ob, seen):
            count += 1
    print(f"  clash-yaml/{os.path.basename(yaml_path)}: {count} nodes")
    return count


# ---------- Multi-group config generation ----------


def generate(
    configs_dir,
    proxy_yaml,
    output_path,
    listen="127.0.0.1",
    port=1080,
    dashboard_port=9090,
    site_groups=None,
):
    if site_groups is None:
        site_groups = _FALLBACK_SITE_GROUPS
    print(f"Config dir: {configs_dir}")
    if proxy_yaml:
        print(f"Clash YAML: {proxy_yaml}")
    print()

    all_outbounds = []
    seen = set()
    counter = iter(range(100000))

    convert_clash_meta(
        os.path.join(configs_dir, "clash.meta2"), all_outbounds, seen, counter
    )
    convert_xray(os.path.join(configs_dir, "xray"), all_outbounds, seen, counter)
    convert_singbox(os.path.join(configs_dir, "singbox"), all_outbounds, seen, counter)
    convert_hysteria2(
        os.path.join(configs_dir, "hysteria2"), all_outbounds, seen, counter
    )
    convert_hysteria(
        os.path.join(configs_dir, "hysteria"), all_outbounds, seen, counter
    )
    convert_juicity(os.path.join(configs_dir, "juicity"), all_outbounds, seen, counter)
    convert_naiveproxy(
        os.path.join(configs_dir, "naiveproxy"), all_outbounds, seen, counter
    )

    clash_count = 0
    if proxy_yaml:
        clash_count = convert_clash_yaml(proxy_yaml, all_outbounds, seen, counter)

    proxy_tags = [ob["tag"] for ob in all_outbounds]
    print(f"\nTotal: {len(all_outbounds)} proxy nodes")
    if clash_count:
        print(f"  {clash_count} from Clash YAML")

    if not all_outbounds:
        print("No usable nodes, skipping config generation")
        return False

    group_outbounds = []

    for key, info in site_groups.items():
        selector_tag = f"{key}-selector"
        urltest_tag = f"{key}-urltest"

        group_outbounds.append(
            {
                "type": "selector",
                "tag": selector_tag,
                "outbounds": [urltest_tag] + proxy_tags,
                "default": urltest_tag,
            }
        )
        group_outbounds.append(
            {
                "type": "urltest",
                "tag": urltest_tag,
                "outbounds": proxy_tags,
                "url": info["test_url"],
                "interval": "5m",
                "tolerance": 100,
            }
        )

    group_outbounds.extend(
        [
            {
                "type": "selector",
                "tag": f"{FALLBACK_KEY}-selector",
                "outbounds": [f"{FALLBACK_KEY}-urltest"] + proxy_tags,
                "default": f"{FALLBACK_KEY}-urltest",
            },
            {
                "type": "urltest",
                "tag": f"{FALLBACK_KEY}-urltest",
                "outbounds": proxy_tags,
                "url": "http://cp.cloudflare.com/generate_204",
                "interval": "5m",
                "tolerance": 50,
            },
        ]
    )

    group_outbounds.extend(
        [
            {"type": "direct", "tag": "direct"},
            {"type": "block", "tag": "block"},
        ]
    )

    route_rules = [
        {"geoip": ["private"], "outbound": "direct"},
        {"geosite": "cn", "outbound": "direct"},
        {"geoip": "cn", "outbound": "direct"},
    ]
    for key, info in site_groups.items():
        route_rules.append(
            {
                "domain_suffix": info["domains"],
                "outbound": f"{key}-selector",
            }
        )

    config = {
        "log": {
            "level": "info",
            "output": "/var/log/sing-box.log",
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": listen,
                "listen_port": port,
                "sniff": True,
                "sniff_override_destination": False,
                "set_system_proxy": False,
            },
        ],
        "outbounds": all_outbounds + group_outbounds,
        "route": {
            "rules": route_rules,
            "final": "fallback-selector",
            "auto_detect_interface": True,
            "geoip": {
                "path": "/var/lib/sing-box/geoip.db",
            },
            "geosite": {
                "path": "/var/lib/sing-box/geosite.db",
            },
        },
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": "/var/lib/sing-box/cache.db",
            },
            "clash_api": {
                "external_controller": f"127.0.0.1:{dashboard_port}",
                "default_mode": "rule",
            },
        },
    }

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    print(f"\nConfig written: {output_path}")

    by_type = {}
    for ob in all_outbounds:
        t = ob["type"]
        by_type[t] = by_type.get(t, 0) + 1
    print("\nNode type distribution:")
    for t, c in sorted(by_type.items()):
        print(f"  {t:15s} {c}")
    print()
    print(
        f"Route groups: {', '.join(info['label'] for info in site_groups.values())}, Fallback"
    )
    print(f"Dashboard: http://127.0.0.1:{dashboard_port}/ui")

    return True


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="ChromeGo to sing-box config converter (multi-group routing)"
    )
    parser.add_argument(
        "--configs",
        default=CONFIGS_DIR,
        help=f"ChromeGo config directory (default {CONFIGS_DIR})",
    )
    parser.add_argument(
        "--proxy-yaml",
        default=None,
        help="Clash YAML path (e.g. fetch.sh output config.yaml)",
    )
    parser.add_argument(
        "--output", default=OUTPUT_PATH, help=f"Output path (default {OUTPUT_PATH})"
    )
    parser.add_argument(
        "--listen", default="0.0.0.0", help="Listen address (default 0.0.0.0)"
    )
    parser.add_argument(
        "--port", type=int, default=1080, help="Listen port (default 1080)"
    )
    parser.add_argument(
        "--dashboard-port", type=int, default=9090, help="Dashboard port (default 9090)"
    )
    parser.add_argument(
        "--site-groups",
        default=None,
        help="Site groups YAML config path (default: site-groups.yaml next to script)",
    )
    args = parser.parse_args()

    site_groups = load_site_groups(args.site_groups)
    generate(
        args.configs,
        args.proxy_yaml,
        args.output,
        listen=args.listen,
        port=args.port,
        dashboard_port=args.dashboard_port,
        site_groups=site_groups,
    )

    print(f"\nStart:   sing-box run -c {args.output}")
    print(f"Dashboard: http://127.0.0.1:{args.dashboard_port}/ui")


if __name__ == "__main__":
    main()
