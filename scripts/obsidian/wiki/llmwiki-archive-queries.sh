#!/usr/bin/env bash
# ============================================================================
# llmwiki-archive-queries.sh — 将 llmwiki query --save 产生的问答页归档为正式概念页
#
# 原理:
#   llmwiki query --save 把答案保存到 wiki/queries/（保留原始问答上下文）。
#   问答页达到一定质量后，定期归档到 wiki/concepts/ 成为正式 wiki 概念页
#   （与手动整理的概念页同等待遇，参与 index 生成）。
#
# 用法:
#   bash llmwiki-archive-queries.sh [wiki-root]     # 默认 /opt/llmwiki
#
# 归档规则:
#   - 全部移动到 wiki/concepts/（原文件名保留）
#   - 自动在页头追加来源标记（记录原为 query 产物）
#   - 归档后自动触发一次编译（llmwiki compile）更新 index
# ============================================================================
set -euo pipefail

WIKI_ROOT="${1:-/opt/llmwiki}"
QUERIES_DIR="${WIKI_ROOT}/wiki/queries"
CONCEPTS_DIR="${WIKI_ROOT}/wiki/concepts"
export PATH=/usr/local/node/bin:$PATH

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

[[ -d "$QUERIES_DIR" ]] || {
	info "wiki/queries/ 不存在，无需归档"
	exit 0
}
mkdir -p "$CONCEPTS_DIR"

count=0
for f in "$QUERIES_DIR"/*.md; do
	[[ -f "$f" ]] || continue
	base="$(basename "$f")"
	# 追加来源标记（若尚未标记）
	if ! grep -q '^> *来源: llmwiki query' "$f"; then
		{
			echo "> 来源: llmwiki query --save（自动归档）"
			cat "$f"
		} >"${f}.tmp" &&
			mv "${f}.tmp" "$f"
	fi
	mv "$f" "${CONCEPTS_DIR}/${base}"
	info "归档: ${base}"
	count=$((count + 1))
done

if [[ "$count" -gt 0 ]]; then
	cd "$WIKI_ROOT"
	llmwiki compile >/dev/null 2>&1 && info "已重新编译 index（${count} 个问答页归档）" ||
		warn "编译失败（稍后 timer 会自动重试）"
else
	info "无待归档问答页"
fi
