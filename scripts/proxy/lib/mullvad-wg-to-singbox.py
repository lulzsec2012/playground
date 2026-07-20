#!/usr/bin/env python3
"""Mullvad WireGuard .conf → sing-box outbound 转换器

将 Mullvad 的 WireGuard 配置文件转换为 sing-box WireGuard 出站格式，
并输出为 JSON 数组，供 generate-config.py 或 proxy-deploy-mullvad 使用。

用法:
  # 转换 data/mullvad/ 下所有 .conf 文件
  lib/mullvad-wg-to-singbox.py

  # 指定目录
  lib/mullvad-wg-to-singbox.py --dir data/mullvad

  # 指定输出文件
  lib/mullvad-wg-to-singbox.py --output /tmp/mullvad-outbounds.json

  # 输出也支持 --regions 指定区域配置文件（用于附加元信息）
  lib/mullvad-wg-to-singbox.py --regions config/mullvad-regions.yaml

输入格式 (Mullvad WireGuard .conf):
  [Interface]
  PrivateKey = ...
  Address = 10.64.0.1/32, fc00:.../128
  DNS = 10.64.0.1

  [Peer]
  PublicKey = ...
  AllowedIPs = 0.0.0.0/0, ::/0
  Endpoint = 123.123.123.123:51820
  PersistentKeepalive = 25

输出格式 (sing-box outbound):
  {
    "type": "wireguard",
    "tag": "mullvad-us-lax",
    "server": "123.123.123.123",
    "server_port": 51820,
    "local_address": ["10.64.0.1/32"],
    "private_key": "...",
    "peer_public_key": "...",
    "reserved": [0, 0, 0],
    "mtu": 1420,
    "system_interface": false,
    "gso": false
  }
"""

import argparse
import json
import os
import re
import sys
import yaml


def parse_wireguard_conf(conf_path: str) -> dict | None:
    """解析 Mullvad WireGuard .conf 文件，返回参数字典。"""
    if not os.path.isfile(conf_path):
        print(f"  ⚠️  文件不存在: {conf_path}", file=sys.stderr)
        return None

    with open(conf_path) as f:
        content = f.read()

    result = {}
    # 跳过注释行和空行，解析 [Interface] 和 [Peer] 区块
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
                # 取第一个 IPv4 地址 (忽略 IPv6 和多个地址)
                addrs = [a.strip() for a in value.split(",")]
                result["local_address"] = [addrs[0]]
            elif key == "dns":
                result["dns"] = value
        elif current_section == "peer":
            if key == "publickey":
                result["peer_public_key"] = value
            elif key == "presharedkey":
                result["preshared_key"] = value
            elif key == "endpoint":
                # 解析 host:port
                m = re.match(r"^\[?([^\]]+)\]?:(\d+)$", value)
                if m:
                    result["server"] = m.group(1)
                    result["server_port"] = int(m.group(2))
                else:
                    # 尝试 IPv6 格式 [::1]:port
                    m = re.match(r"^\[(.+)\]:(\d+)$", value)
                    if m:
                        result["server"] = m.group(1)
                        result["server_port"] = int(m.group(2))
            elif key == "persistentkeepalive":
                try:
                    result["keepalive"] = int(value)
                except ValueError:
                    pass

    # 验证必需字段
    required = ["private_key", "local_address", "peer_public_key", "server"]
    missing = [r for r in required if r not in result]
    if missing:
        print(
            f"  ⚠️  配置不完整 {conf_path}, 缺少: {', '.join(missing)}",
            file=sys.stderr,
        )
        return None

    return result


def to_singbox_outbound(
    params: dict,
    tag: str,
    mtu: int = 1420,
    reserved: list | None = None,
    system_iface: bool = False,
) -> dict:
    """将 WireGuard 参数转换为 sing-box outbound 格式。"""
    ob = {
        "type": "wireguard",
        "tag": tag,
        "server": params["server"],
        "server_port": params.get("server_port", 51820),
        "local_address": params["local_address"],
        "private_key": params["private_key"],
        "peer_public_key": params["peer_public_key"],
        "mtu": mtu,
        "system_interface": system_iface,
        "gso": False,
    }

    if reserved:
        ob["reserved"] = reserved

    if params.get("keepalive"):
        ob["keep_alive"] = params["keepalive"]

    if params.get("preshared_key"):
        ob["preshared_key"] = params["preshared_key"]

    # Mullvad DNS — 可选，仅供文档参考，不在出站中设置
    if params.get("dns"):
        ob["_dns_hint"] = params["dns"]

    return ob


def load_regions(regions_path: str | None) -> dict:
    """加载 mullvad-regions.yaml，返回 {key: info} 字典。"""
    if not regions_path or not os.path.isfile(regions_path):
        return {}

    with open(regions_path) as f:
        data = yaml.safe_load(f)

    if not data or "regions" not in data:
        print(f"  ⚠️  区域配置缺少 'regions' 字段: {regions_path}", file=sys.stderr)
        return {}

    return data["regions"]


def get_conf_files(conf_dir: str) -> list[str]:
    """获取目录下所有 .conf 文件，按文件名排序。"""
    if not os.path.isdir(conf_dir):
        print(f"  ⚠️  目录不存在，已自动创建: {conf_dir}", file=sys.stderr)
        os.makedirs(conf_dir, exist_ok=True)
        return []
    files = sorted(f for f in os.listdir(conf_dir) if f.endswith(".conf"))
    if not files:
        print(f"  ⚠️  在 {conf_dir} 中未找到任何 .conf 文件", file=sys.stderr)
    return files


def convert_all(
    conf_dir: str,
    regions: dict | None = None,
    mtu: int = 1420,
    reserved: list | None = None,
) -> list[dict]:
    """转换 data/mullvad/ 下所有 .conf 文件为 sing-box outbound 列表。"""
    if regions is None:
        regions = {}

    conf_files = get_conf_files(conf_dir)
    outbounds = []

    for conf_file in conf_files:
        # 从文件名推断 tag: mullvad-us-lax.conf → mullvad-us-lax
        tag = conf_file.replace(".conf", "")
        if not tag.startswith("mullvad-"):
            tag = f"mullvad-{tag}"

        conf_path = os.path.join(conf_dir, conf_file)
        params = parse_wireguard_conf(conf_path)
        if params is None:
            continue

        ob = to_singbox_outbound(params, tag, mtu=mtu, reserved=reserved)
        outbounds.append(ob)

        # 附加区域信息
        region_key = tag.replace("mullvad-", "", 1)
        region_info = regions.get(region_key, {})
        ob["_region_label"] = region_info.get("label", tag)
        ob["_country"] = region_info.get("country", "unknown")

        print(
            f"  ✓ {conf_file:30s} → {tag:25s}  {params['server']}:{params.get('server_port', 51820)}"
        )

    return outbounds


def generate_mullvad_group_outbounds(
    mullvad_outbounds: list[dict],
    tag_prefix: str = "mullvad",
    fallback_tag: str = "fallback-selector",
) -> list[dict]:
    """生成 Mullvad 的 selector + urltest 组出站。"""
    mullvad_tags = [ob["tag"] for ob in mullvad_outbounds]
    if not mullvad_tags:
        return []

    group_outbounds = [
        {
            "type": "selector",
            "tag": f"{tag_prefix}-selector",
            "outbounds": [f"{tag_prefix}-urltest"] + mullvad_tags,
            "default": f"{tag_prefix}-urltest",
        },
        {
            "type": "urltest",
            "tag": f"{tag_prefix}-urltest",
            "outbounds": mullvad_tags,
            "url": "http://cp.cloudflare.com/generate_204",
            "interval": "10m",
            "tolerance": 50,
        },
    ]
    return group_outbounds


def main():
    parser = argparse.ArgumentParser(
        description="Mullvad WireGuard → sing-box outbound 转换器"
    )
    parser.add_argument(
        "--dir",
        default=None,
        help="Mullvad WireGuard 配置目录 (默认: ../data/mullvad 相对于脚本位置)",
    )
    parser.add_argument(
        "--regions",
        default=None,
        help="区域配置文件路径 (默认: ../config/mullvad-regions.yaml 相对于脚本位置)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="输出 JSON 文件路径 (默认: 输出到 stdout)",
    )
    parser.add_argument(
        "--mtu",
        type=int,
        default=1420,
        help="WireGuard MTU (默认: 1420)",
    )
    parser.add_argument(
        "--reserved",
        default=None,
        help="reserved 字节, 逗号分隔 (如 '0,0,0')",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        default=True,
        help="美化 JSON 输出 (默认: 启用)",
    )
    parser.add_argument(
        "--groups",
        action="store_true",
        help="同时生成 Mullvad 的 selector + urltest 组出站",
    )

    args = parser.parse_args()

    # 确定默认路径
    script_dir = os.path.dirname(os.path.abspath(__file__))
    conf_dir = args.dir or os.path.join(script_dir, "..", "data", "mullvad")
    regions_path = args.regions or os.path.join(
        script_dir, "..", "config", "mullvad-regions.yaml"
    )

    # 规范化路径
    conf_dir = os.path.abspath(conf_dir)
    if regions_path:
        regions_path = os.path.abspath(regions_path)

    # 解析 reserved
    reserved = None
    if args.reserved:
        try:
            reserved = [int(x.strip()) for x in args.reserved.split(",")]
        except ValueError:
            print("  ⚠️  reserved 格式错误，应为逗号分隔的数字", file=sys.stderr)
            sys.exit(1)

    # 加载区域配置
    regions = load_regions(regions_path)
    print(f"Mullvad outbound converter")
    print(f"  Config dir:   {conf_dir}")
    print(f"  Regions file: {regions_path}")
    if regions:
        print(f"  Regions:      {', '.join(regions.keys())}")
    print()

    # 转换
    mullvad_outbounds = convert_all(conf_dir, regions, mtu=args.mtu, reserved=reserved)

    if not mullvad_outbounds:
        print("\n⚠️  没有可用的 Mullvad 配置。请:")
        print("  1. 从 https://mullvad.net/zh/account/ 下载 WireGuard 配置")
        print(f"  2. 放入 {conf_dir}/")
        print("  3. 重新运行此脚本")
        sys.exit(1)

    # 合并结果
    result = {"outbounds": mullvad_outbounds}

    if args.groups:
        group_outbounds = generate_mullvad_group_outbounds(mullvad_outbounds)
        result["group_outbounds"] = group_outbounds
        print(f"\n  Mullvad groups: {len(group_outbounds)} outbounds generated")

    print(f"\n  Total Mullvad outbounds: {len(mullvad_outbounds)}")

    # 输出
    json_kwargs = {"indent": 2, "ensure_ascii": False} if args.pretty else {}
    output_str = json.dumps(result, **json_kwargs)

    if args.output:
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w") as f:
            f.write(output_str)
        print(f"\n  Output: {args.output}")
    else:
        print("\n" + output_str)


if __name__ == "__main__":
    main()
