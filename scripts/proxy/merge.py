#!/usr/bin/env python3
"""
用 yaml 库解析各源 proxies，统一缩进注入 RenzheCloud 模板。

用法: merge.py <模板.yaml> <输出.yaml> <源文件1.yaml> [源文件2.yaml ...]

流程:
  1. 用 yaml.safe_load 解析每个源文件，提取 proxies 列表
  2. 合并去重（节点名相同只保留第一个）
  3. 保留 RenzheCloud 的 proxy-groups(31个) 和 rules
  4. 用 yaml.dump 重新输出 proxies（缩进统一，格式正确）
  5. 找出"终端组"并填入所有免费节点名
"""
import re
import sys
import unicodedata
import yaml
import copy

def main():
    if len(sys.argv) < 4:
        print("用法: merge.py <模板.yaml> <输出.yaml> <源文件1.yaml> [源文件2.yaml ...]", file=sys.stderr)
        sys.exit(1)

    template_path = sys.argv[1]
    output_path = sys.argv[2]
    source_paths = sys.argv[3:]

    # ---- 1. 读取模板 ----
    with open(template_path) as f:
        template = f.read()

    # ---- 2. 定位各段边界 ----
    proxies_idx = template.index("proxies:")
    groups_idx = template.index("proxy-groups:")
    rules_idx = template.index("rules:")

    before_proxies = template[:proxies_idx]
    proxies_section = template[proxies_idx:groups_idx]
    groups_section = template[groups_idx:rules_idx]
    after_rules = template[rules_idx:]

    # ---- 3. 提取 RenzheCloud 自有节点 ----
    rc_match = re.search(r'proxies:\n((?:\s+- .*\n?)*)', proxies_section)
    rc_proxies_text = rc_match.group(1) if rc_match else ""

    # 用 yaml 解析 RenzheCloud proxies
    rc_proxies = []
    if rc_proxies_text.strip():
        try:
            rc_data = yaml.safe_load("proxies:\n" + rc_proxies_text)
            rc_proxies = rc_data.get("proxies", []) if rc_data else []
        except yaml.YAMLError as e:
            print(f"警告: RenzheCloud 自有节点解析失败: {e}", file=sys.stderr)

    # ---- 4. 用 yaml 解析每个源文件，提取 proxies ----
    all_proxies = {}  # {name: proxy_dict}
    seen_names = set()

    # 先加入 RenzheCloud 节点（优先级高）
    for p in rc_proxies:
        if isinstance(p, dict) and "name" in p:
            name = p["name"]
            all_proxies[name] = copy.deepcopy(p)
            seen_names.add(name)

    # 再处理各源
    for src_path in source_paths:
        try:
            with open(src_path) as f:
                raw = f.read()
        except (IOError, OSError) as e:
            print(f"  跳过 [{src_path}]: {e}", file=sys.stderr)
            continue

        # 找到 proxies: 段并提取
        pidx = raw.find("proxies:")
        if pidx < 0:
            continue

        # 提取从 proxies: 到下一个顶层 key 或文件结束
        rest = raw[pidx:]
        proxies_yaml = rest
        # 去掉 proxies: 后的下一个顶层 key
        for m in re.finditer(r'\n[a-z_][-a-z_0-9]*:', rest):
            nxt = m.start()
            if nxt > 0:
                proxies_yaml = rest[:nxt]
                break

        try:
            data = yaml.safe_load(proxies_yaml)
            if not data or "proxies" not in data:
                continue
            for p in data["proxies"]:
                if isinstance(p, dict) and "name" in p:
                    name = p["name"]
                    if name not in seen_names:
                        all_proxies[name] = copy.deepcopy(p)
                        seen_names.add(name)
        except yaml.YAMLError as e:
            print(f"  解析失败 [{src_path}]: {e}", file=sys.stderr)
            continue

    if not all_proxies:
        print("错误: 未找到任何有效代理节点", file=sys.stderr)
        sys.exit(1)

    proxy_count = len(all_proxies)
    proxy_names = list(all_proxies.keys())

    # ---- 5. 用 yaml.dump 生成格式统一的 proxies 段 ----
    # yaml.dump 默认每行 80 字符，有些 inline proxy 可能超长
    # 设置 width=4096 避免换行
    proxies_list = list(all_proxies.values())
    proxies_yaml_out = yaml.dump(
        {"proxies": proxies_list},
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
        width=4096,
        indent=2
    )
    # 去掉 yaml.dump 的文件头 (---\n)
    if proxies_yaml_out.startswith("---\n"):
        proxies_yaml_out = proxies_yaml_out[4:]

    # ---- 6. 提取所有 proxy-group 名 ----
    group_names = set()
    for m in re.finditer(r'^\s+-\s+name:\s*[\x27\x22]?([^\x27\x22,}\n]+)', groups_section, re.MULTILINE):
        gname = m.group(1).strip()
        if gname:
            group_names.add(gname)

    # ---- 7. 生成终端组的 proxy 列表 (YAML list, 特殊字符加引号) ----
    def yaml_quote(n):
        if not n:
            return "''"
        # 包含 :空格、@、#、[]、{}、!、*、|、>、开头是-?等 → 需要双引号
        if re.search(r': |[@#\[\]{}!*|>\'",?$`]', n) or n.startswith(('-', '?', '&', ':')):
            return '"' + n.replace('\\', '\\\\').replace('"', '\\"') + '"'
        return n
    proxy_list_yaml = "\n".join(f"      - {yaml_quote(name)}" for name in proxy_names)

    # ---- 8. 处理 proxy-groups ----
    BUILTINS = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "PROXY"}

    groups_parts = re.split(r'\n(?=\s+- name:)', groups_section)
    modified_parts = []

    for part in groups_parts:
        part = part.rstrip("\n")
        if not part:
            continue

        m = re.search(r'^\s+-\s+name:\s*[\x27\x22]?([^\x27\x22,}\n]+)', part)
        if not m:
            modified_parts.append(part)
            continue
        gname = m.group(1).strip()

        ref_match = re.search(r'proxies:\n(\s+- .*(?:\n\s+- .*)*)', part)
        if not ref_match:
            modified_parts.append(part)
            continue

        refs_text = ref_match.group(1)
        ref_names = set()
        for ref in re.finditer(r'^\s+-\s+(.+)$', refs_text, re.MULTILINE):
            r = ref.group(1).strip().strip("'\"").strip(",")
            if r:
                ref_names.add(r)

        has_builtin = ref_names & BUILTINS
        has_group_ref = ref_names & group_names
        has_proxy_ref = ref_names - BUILTINS - group_names - {""}

        is_terminal = False
        if has_proxy_ref:
            is_terminal = True
        elif has_group_ref and not has_proxy_ref:
            is_terminal = False
        elif has_builtin and not has_group_ref and not has_proxy_ref:
            if any(0x1F1E6 <= ord(ch) <= 0x1F1FF for ch in gname):
                is_terminal = True
            else:
                is_terminal = False

        if is_terminal:
            part = re.sub(
                r'(proxies:\n)((?:\s+- .*\n?)*)',
                lambda m: m.group(1) + proxy_list_yaml + "\n    ",
                part,
                count=1
            )

        modified_parts.append(part)

    new_groups_text = "\n".join(modified_parts)

    # ---- 9. 组装输出 ----
    output = before_proxies + proxies_yaml_out + "\n" + new_groups_text + "\n" + after_rules

    with open(output_path, 'w') as f:
        f.write(output)

    print(f"✅ 生成完成: {output_path}")
    print(f"   代理节点: {proxy_count} 个")
    print(f"   代理分组: {len(group_names)} 个")

if __name__ == "__main__":
    main()
