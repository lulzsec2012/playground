#!/usr/bin/env python3
"""Mullvad WireGuard .conf -> sing-box v1.13+ endpoint 转换器"""

import argparse
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    yaml = None


def parse_wireguard_conf(conf_path):
    if not os.path.isfile(conf_path):
        print("  ! 文件不存在: {}".format(conf_path), file=sys.stderr)
        return None

    with open(conf_path) as f:
        content = f.read()

    result = {}
    current_section = None

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1].lower()
            continue
        if "=" not in line:
            continue

        key, _, value = line.partition("=")
        key = key.strip().lower()
        value = value.strip()

        if current_section == "interface":
            if key == "privatekey":
                result["private_key"] = value
            elif key == "address":
                addrs = [a.strip() for a in value.split(",")]
                result["address"] = [addrs[0]]
            elif key == "dns":
                result["dns"] = value
        elif current_section == "peer":
            if key == "publickey":
                result["peer_public_key"] = value
            elif key == "presharedkey":
                result["preshared_key"] = value
            elif key == "endpoint":
                m = re.match(r"^\[?([^\]]+)\]?:(\d+)$", value)
                if m:
                    result["peer_address"] = m.group(1)
                    result["peer_port"] = int(m.group(2))
                else:
                    m = re.match(r"^\[(.+)\]:(\d+)$", value)
                    if m:
                        result["peer_address"] = m.group(1)
                        result["peer_port"] = int(m.group(2))
            elif key == "persistentkeepalive":
                try:
                    result["keepalive"] = int(value)
                except ValueError:
                    pass

    required = ["private_key", "address", "peer_public_key", "peer_address"]
    missing = [r for r in required if r not in result]
    if missing:
        print("  ! 配置不完整 {} 缺少: {}".format(conf_path, ", ".join(missing)), file=sys.stderr)
        return None

    return result


def to_singbox_endpoint(params, tag, mtu=1420):
    peer = {
        "address": params["peer_address"],
        "port": params.get("peer_port", 51820),
        "public_key": params["peer_public_key"],
        "allowed_ips": ["0.0.0.0/0"],
    }
    if params.get("keepalive"):
        peer["persistent_keepalive_interval"] = params["keepalive"]
    if params.get("preshared_key"):
        peer["pre_shared_key"] = params["preshared_key"]
    if params.get("reserved"):
        peer["reserved"] = params["reserved"]

    return {
        "type": "wireguard",
        "tag": tag,
        "system": False,
        "mtu": mtu,
        "address": params["address"],
        "private_key": params["private_key"],
        "peers": [peer],
    }


def load_regions(regions_path):
    if not regions_path or not os.path.isfile(regions_path):
        return {}
    if yaml is None:
        print("  ! PyYAML not installed, skipping regions", file=sys.stderr)
        return {}
    with open(regions_path) as f:
        data = yaml.safe_load(f)
    if not data or "regions" not in data:
        return {}
    return data["regions"]


def get_conf_files(conf_dir):
    if not os.path.isdir(conf_dir):
        os.makedirs(conf_dir, exist_ok=True)
        return []
    files = sorted(f for f in os.listdir(conf_dir) if f.endswith(".conf"))
    return files


def convert_all(conf_dir, regions=None, mtu=1420):
    if regions is None:
        regions = {}

    conf_files = get_conf_files(conf_dir)
    endpoints = []
    mullvad_tags = []

    for conf_file in conf_files:
        tag = conf_file.replace(".conf", "")
        if not tag.startswith("mullvad-"):
            tag = "mullvad-{}".format(tag)

        conf_path = os.path.join(conf_dir, conf_file)
        params = parse_wireguard_conf(conf_path)
        if params is None:
            continue

        ep = to_singbox_endpoint(params, tag, mtu=mtu)
        endpoints.append(ep)
        mullvad_tags.append(tag)

        region_key = tag.replace("mullvad-", "", 1)
        region_info = regions.get(region_key, {})
        ep["_region_label"] = region_info.get("label", tag)
        ep["_country"] = region_info.get("country", "unknown")

        print("  v {:<30s} -> {:<25s}  {}:{}".format(
            conf_file, tag, params["peer_address"], params.get("peer_port", 51820)))

    group_outbounds = []
    if mullvad_tags:
        group_outbounds = [
            {
                "type": "selector",
                "tag": "mullvad-selector",
                "outbounds": ["mullvad-urltest"] + mullvad_tags,
                "default": "mullvad-urltest",
            },
            {
                "type": "urltest",
                "tag": "mullvad-urltest",
                "outbounds": mullvad_tags,
                "url": "http://cp.cloudflare.com/generate_204",
                "interval": "10m",
                "tolerance": 50,
            },
        ]

    return endpoints, group_outbounds


def main():
    parser = argparse.ArgumentParser(description="Mullvad WG -> sing-box endpoint converter")
    parser.add_argument("--dir", default=None)
    parser.add_argument("--regions", default=None)
    parser.add_argument("--output", default=None)
    parser.add_argument("--mtu", type=int, default=1420)
    parser.add_argument("--pretty", action="store_true", default=True)

    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    conf_dir = args.dir or os.path.join(script_dir, "..", "data", "mullvad")
    regions_path = args.regions or os.path.join(script_dir, "..", "config", "mullvad-regions.yaml")

    conf_dir = os.path.abspath(conf_dir)
    if regions_path:
        regions_path = os.path.abspath(regions_path)

    regions = load_regions(regions_path)
    print("Mullvad endpoint converter (sing-box v1.13+)")
    print("  Config dir:   {}".format(conf_dir))
    print("  Regions file: {}".format(regions_path))
    if regions:
        print("  Regions:      {}".format(", ".join(regions.keys())))
    print()

    endpoints, group_outbounds = convert_all(conf_dir, regions, mtu=args.mtu)

    if not endpoints:
        print("\n! No Mullvad configs found. Download WG configs from Mullvad and place in:")
        print("  {}".format(conf_dir))
        sys.exit(1)

    result = {"endpoints": endpoints, "outbounds": group_outbounds}
    print("\n  Total endpoints: {}".format(len(endpoints)))
    if group_outbounds:
        print("  Group outbounds: {}".format(len(group_outbounds)))

    json_kwargs = {"indent": 2, "ensure_ascii": False} if args.pretty else {}
    output_str = json.dumps(result, **json_kwargs)

    if args.output:
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w") as f:
            f.write(output_str)
        print("\n  Output: {}".format(args.output))
    else:
        print("\n" + output_str)


if __name__ == "__main__":
    main()
