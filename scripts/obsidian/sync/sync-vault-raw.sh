#!/usr/bin/env bash
# ============================================================================
# sync-vault-raw.sh — 从 CouchDB (LiveSync 明文模式) 同步 vault 的 raw/ 到 llmwiki sources/
#
# 原理:
#   Obsidian LiveSync 把整个 vault 同步到腾讯云 CouchDB (db: my-vault)。
#   明文模式下: 文件路径存于文档的 path 字段(如 raw/xxx.md)，
#   文件内容存于 children 句柄指向的 leaf 文档 data 字段(明文)。
#   本脚本拉取 path 以 raw/ 开头的文档，落盘到 llmwiki 的 sources/ 目录。
#   wiki/ 产物由 LiveSync 反向同步回各设备。
#
# 用法:
#   bash sync-vault-raw.sh              # 增量同步（默认）
#   bash sync-vault-raw.sh --force      # 全量拉取
#   bash sync-vault-raw.sh --daemon     # 每60s循环（配合 systemd: vault-raw-sync.service）
#
# 凭据(按优先级):
#   1. 环境变量 COUCHDB_USER / COUCHDB_PASSWORD（systemd EnvironmentFile 或手动 export）
#   2. 同仓库 scripts/obsidian/configs/couchdb-connection.txt（gitignored）
#
# 依赖: curl + jq
# ============================================================================
set -euo pipefail

COUCH_URL="${COUCH_URL:-http://127.0.0.1:5984}"
COUCH_DB="${COUCH_DB:-my-vault}"
SYNC_DIR="${SYNC_DIR:-/opt/llmwiki/sources}"
STATE_FILE="${STATE_FILE:-/tmp/vault-raw-sync.state}"
MODE="${1:-once}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/../configs/couchdb-connection.txt"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[✗]${NC} $*" >&2; }

# ---- 凭据解析: 环境变量 > configs/couchdb-connection.txt ----
COUCH_USER="${COUCHDB_USER:-}"
COUCH_PASS="${COUCHDB_PASSWORD:-}"
if [[ -z "$COUCH_USER" || -z "$COUCH_PASS" ]] && [[ -f "$CONN_FILE" ]]; then
	COUCH_USER="${COUCH_USER:-$(grep -oP 'Username: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
	COUCH_PASS="${COUCH_PASS:-$(grep -oP 'Password: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
fi
if [[ -z "$COUCH_USER" || -z "$COUCH_PASS" ]]; then
	err "缺少 CouchDB 凭据: 设置 COUCHDB_USER/COUCHDB_PASSWORD 环境变量，或配置 ${CONN_FILE}"
	exit 1
fi
AUTH="$(printf '%s:%s' "$COUCH_USER" "$COUCH_PASS" | base64)"

mkdir -p "$SYNC_DIR"

# 拉取 leaf 文档内容（明文模式: children 句柄 → leaf 的 data 字段）
fetch_leaf_data() { # doc_json -> stdout
	local doc="$1"
	echo "$doc" | jq -r '.children[]?' 2>/dev/null | while read -r h; do
		[ -z "$h" ] && continue
		local enc_h
		enc_h="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$h")"
		curl -s --connect-timeout 10 -H "Authorization: Basic ${AUTH}" \
			"${COUCH_URL}/${COUCH_DB}/${enc_h}" | jq -r '.data // empty'
	done
}

# 增量同步（_changes 流）
sync_once() {
	local since="${1:-0}"
	local resp seq
	resp="$(curl -s --connect-timeout 10 -H "Authorization: Basic ${AUTH}" \
		"${COUCH_URL}/${COUCH_DB}/_changes?since=${since}&include_docs=true&limit=500")"
	seq="$(echo "$resp" | jq -r '.last_seq // "0"')"

	local count=0
	while IFS= read -r ch; do
		[ -z "$ch" ] && continue
		local path deleted rel_path out_file
		path="$(echo "$ch" | jq -r '.doc.path // empty')"
		deleted="$(echo "$ch" | jq -r '.deleted // false')"

		case "$path" in
		raw/*.md) ;;
		*) continue ;;
		esac

		rel_path="${path#raw/}"
		out_file="${SYNC_DIR}/${rel_path}"

		if [ "$deleted" = "true" ]; then
			rm -f "$out_file"
			info "删除: ${rel_path}"
			count=$((count + 1))
			continue
		fi

		mkdir -p "$(dirname "$out_file")"
		if fetch_leaf_data "$(echo "$ch" | jq -c '.doc')" >"$out_file.tmp"; then
			if [ -s "$out_file.tmp" ]; then
				mv "$out_file.tmp" "$out_file"
				count=$((count + 1))
				info "同步: ${rel_path} ($(wc -c <"$out_file") 字节)"
			else
				rm -f "$out_file.tmp"
				if [ -s "$out_file" ]; then
					warn "空内容跳过: ${rel_path}（保留现有文件，源数据可能未就绪）"
				else
					warn "空内容: ${rel_path}（可能仍在同步或结构变化）"
				fi
			fi
		fi
	done <<<"$(echo "$resp" | jq -c '.results[]?')"

	echo "$seq" >"$STATE_FILE"
	[ "$count" -gt 0 ] && info "本轮同步 ${count} 个文件 (seq=${seq})"
}

# 全量拉取 raw/ 文档
sync_full() {
	info "全量同步 raw/ ..."
	local resp
	resp="$(curl -s --connect-timeout 15 -H "Authorization: Basic ${AUTH}" \
		"${COUCH_URL}/${COUCH_DB}/_all_docs?include_docs=true&limit=5000")"
	while IFS= read -r doc; do
		[ -z "$doc" ] && continue
		local path rel_path out_file
		path="$(echo "$doc" | jq -r '.path // empty')"
		case "$path" in
		raw/*.md) ;;
		*) continue ;;
		esac
		rel_path="${path#raw/}"
		out_file="${SYNC_DIR}/${rel_path}"
		mkdir -p "$(dirname "$out_file")"
		if fetch_leaf_data "$doc" >"$out_file.tmp"; then
			if [ -s "$out_file.tmp" ]; then
				mv "$out_file.tmp" "$out_file"
				info "拉取: ${rel_path} ($(wc -c <"$out_file") 字节)"
			else
				rm -f "$out_file.tmp"
				if [ -s "$out_file" ]; then
					warn "空内容跳过: ${rel_path}（保留现有文件）"
				else
					warn "空内容: ${rel_path}"
				fi
			fi
		fi
	done <<<"$(echo "$resp" | jq -c '.rows[]?.doc // empty')"
}

case "$MODE" in
--force)
	sync_full
	;;
--daemon)
	info "守护模式: 每 ${SYNC_INTERVAL:-15}s 增量同步"
	while true; do
		sync_once "$(cat "$STATE_FILE" 2>/dev/null || echo 0)" || true
		sleep "${SYNC_INTERVAL:-15}"
	done
	;;
*)
	sync_once "$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
	;;
esac
