#!/usr/bin/env bash
#
# lib-tailnet.sh — Tailscale/Network 操作封装
#
# Usage: source "$(dirname "$0")/lib/lib-tailnet.sh"
#
# 依赖: lib-format.sh（必须先 source）
# 设计: 直接使用主机原生 tailscale，不再依赖 Docker 容器

# 只在首次 source 时定义
if [[ -z "${__LIB_TAILNET_LOADED:-}" ]]; then
  readonly __LIB_TAILNET_LOADED=1
fi

# ---------- 网络探测 ----------

# 快速端口探测
# 用法: check_port <ip> <port> [timeout_sec]
# 返回: 0=可达, 1=不可达
# 注意: 依赖 nc (netcat)，Ubuntu: apt install -y netcat-openbsd
check_port() {
  local ip="$1"
  local port="$2"
  local timeout="${3:-2}"
  timeout "${timeout}" bash -c "echo > /dev/tcp/${ip}/${port}" 2>/dev/null
}

# HTTP GET 请求
# 用法: http_get <ip> <port> <path> [timeout_sec]
# 返回: 响应内容（stdout），失败返回空
# 依赖: curl（tailnet IP 直连，无需 Docker 网络命名空间）
http_get() {
  local ip="$1"
  local port="$2"
  local path="$3"
  local timeout="${4:-5}"
  curl -sf --max-time "${timeout}" "http://${ip}:${port}${path}" 2>/dev/null || true
}

# HTTP POST 请求（带 body）
# 用法: http_post <ip> <port> <path> <content_type> <body_file> [timeout_sec]
# 返回: 响应内容（stdout）
http_post() {
  local ip="$1"
  local port="$2"
  local path="$3"
  local content_type="$4"
  local body_file="$5"
  local timeout="${6:-10}"
  curl -sf --max-time "${timeout}" \
    -X POST \
    -H "Content-Type: ${content_type}" \
    --data-binary "@${body_file}" \
    "http://${ip}:${port}${path}" 2>/dev/null || true
}

# ---------- tailscale 节点 ----------

# 获取所有在线 tailscale 节点
# 用法: ts_nodes
# 输出: 每行 "ip<空格>name"，只包含在线节点
# 返回: 0=成功, 1=无法获取
ts_nodes() {
  tailscale status 2>/dev/null \
    | awk '/^100\./ && !/offline/ {print $1, $2}'
}

# ---------- JSON 解析辅助 ----------

# 从 JSON 中提取指定键的字符串值（"key":"value" 模式）
# 用法: echo "$json" | extract_json_str <key>
# 示例: echo '{"name":"llama3"}' | extract_json_str "name" → llama3
extract_json_str() {
  local key="$1"
  grep -o "\"${key}\":\"[^\"]*\"" | sed "s/\"${key}\":\"//;s/\"//g"
}

# 从 JSON 对象数组中提取所有指定字段的值
# 用法: echo "$json" | extract_json_field <field>
# 示例: echo '[{"id":"m1"},{"id":"m2"}]' | extract_json_field "id" → m1\nm2
extract_json_field() {
  local key="$1"
  grep -o "\"${key}\":\"[^\"]*\"" | sed "s/\"${key}\":\"//;s/\"//g"
}
