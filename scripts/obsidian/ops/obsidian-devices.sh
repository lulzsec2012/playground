#!/usr/bin/env bash
# ============================================================================
# obsidian-devices.sh — 服务器层面标注/查看 Obsidian LiveSync 客户端设备
#
# 原理:
#   1. CouchDB milestone 文档 node_info 记录每个客户端的设备名/vault名/最后连接
#   2. CouchDB 访问日志记录外部 IP
#   3. devices.conf 注册表把 IP 标注为易读名称（如 "Windows电脑"）
#
# 用法:
#   bash obsidian-devices.sh           # 查看设备列表 + IP 标注
#   bash obsidian-devices.sh --live    # 实时跟随日志（Ctrl+C 退出）
#   bash obsidian-devices.sh --recent  # 最近 N 小时连接标注（默认 1）
#
# 注册表: 同目录 devices.conf（IP 设备名），支持 # 注释
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SCRIPT_DIR}/../devices.conf"
CONN_FILE="${SCRIPT_DIR}/configs/couchdb-connection.txt"
COUCH_DB="my-vault"
CONTAINER="${COUCHDB_CONTAINER:-couchdb}"
WINDOW="${1:-1h}"

# ---- CouchDB 凭据: 环境变量 > configs/couchdb-connection.txt ----
COUCH_USER="${COUCHDB_USER:-}"
COUCH_PASS="${COUCHDB_PASSWORD:-}"
if [[ -z "$COUCH_USER" || -z "$COUCH_PASS" ]] && [[ -f "$CONN_FILE" ]]; then
	COUCH_USER="${COUCH_USER:-$(grep -oP 'Username: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
	COUCH_PASS="${COUCH_PASS:-$(grep -oP 'Password: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
fi
if [[ -z "$COUCH_USER" || -z "$COUCH_PASS" ]]; then
	echo "错误: 缺少 CouchDB 凭据（设置 COUCHDB_USER/COUCHDB_PASSWORD 或配置 $CONN_FILE）" >&2
	exit 1
fi
COUCH="http://${COUCH_USER}:${COUCH_PASS}@localhost:5984"

# ---- 读取注册表 IP -> 名称 ----
declare -A NAMES
if [[ -f "$CONF" ]]; then
	while IFS= read -r line; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		ip=$(echo "$line" | awk '{print $1}')
		name=$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}')
		[[ -n "$ip" && -n "$name" ]] && NAMES["$ip"]="$name"
	done <"$CONF"
fi

label() { # IP -> 名称（无注册则显示原 IP）
	echo "${NAMES[$1]:-$1}"
}

# ---- 从 milestone 读设备节点 -> 临时文件 ----
node_info() {
	curl -s --max-time 8 "${COUCH}/${COUCH_DB}/_local/obsydian_livesync_milestone" 2>/dev/null |
		python3 -c '
import json, sys, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for nid, info in d.get("node_info", {}).items():
    last = info.get("last_connected", 0)
    ts = datetime.datetime.fromtimestamp(last/1000).strftime("%m-%d %H:%M:%S") if last else "?"
    tweaks = d.get("tweak_values", {}).get(nid, {})
    print("%s|%s|%s|%s|%s|%s" % (nid, info.get("device_name","?"), info.get("vault_name","?"), info.get("app_version","?"), ts, tweaks.get("encrypt","?")))
' 2>/dev/null
}

# ---- 从 docker logs 提取外部 IP 时间线 ----
recent_ips() {
	docker logs "$CONTAINER" --since "$1" 2>&1 |
		grep ":5984" |
		grep -vE "172\.17\.0\.1|127\.0\.0\.1" |
		sed -E 's/.*T([0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]+Z.*62\.234\.69\.194:5984 ([0-9.]+) .*/\1 \2/' |
		sort -u
}

echo "============================================================"
echo " Obsidian LiveSync 设备标注 (CouchDB: $COUCH_DB)"
echo "============================================================"

echo ""
echo "【里程碑注册节点】(设备名来自客户端上报)"
printf "  %-14s %-30s %-12s %-10s %-16s %s\n" "NODE" "DEVICE_NAME" "VAULT" "APP" "LAST_SEEN" "E2EE"
node_info >/tmp/obsidian-nodes.tmp
if [[ -s /tmp/obsidian-nodes.tmp ]]; then
	while IFS='|' read -r nid dname vname app last enc; do
		printf "  %-14s %-30s %-12s %-10s %-16s %s\n" "$nid" "$dname" "$vname" "$app" "$last" "$enc"
	done </tmp/obsidian-nodes.tmp
else
	echo "  (milestone 无节点信息或读取失败)"
fi
rm -f /tmp/obsidian-nodes.tmp

echo ""
echo "【最近 $WINDOW 外部连接标注】"
recent_ips "$WINDOW" >/tmp/obsidian-ips.tmp
if [[ -s /tmp/obsidian-ips.tmp ]]; then
	while read -r time ip; do
		printf "  %-8s %-16s -> %s\n" "$time" "$ip" "$(label "$ip")"
	done </tmp/obsidian-ips.tmp
else
	echo "  (无外部连接)"
fi
rm -f /tmp/obsidian-ips.tmp

echo ""
echo "【注册表】(devices.conf — 编辑后即生效)"
if [[ -f "$CONF" ]]; then
	sed 's/^/  /' "$CONF"
else
	echo "  (不存在，创建 $CONF 添加 IP 标注)"
fi
