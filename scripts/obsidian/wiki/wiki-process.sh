#!/usr/bin/env bash
# ============================================================================
# ⚠️ 已废弃 (2026-08-10) — 已被 llm-wiki-compiler (atomicstrata) 替代。
#    保留仅供历史参考；不要用于新部署。llmwiki 产物目录约定为 wiki/concepts/（复数）。
#
# wiki-process.sh — LLM Wiki 自动编译器（raw/ → wiki/）【旧方案】
#
# 功能:
#   1. 扫描 raw/ 中未处理的 Markdown 文件
#   2. 调 MixAPI (qwen3.6-27b) 编译为结构化 wiki 页
#   3. 按内容类型分拣到 wiki/{concept,entity,summary,synthesis}/
#   4. 更新 wiki/index.md 和 log.md
#
# 用法:
#   bash wiki-process.sh /path/to/vault            # 处理所有未处理文件
#   bash wiki-process.sh /path/to/vault --watch    # 持续监控(每60s扫描)
#   bash wiki-process.sh /path/to/vault --file xxx # 只处理指定文件
#
# 依赖:
#   - MixAPI 网关 (默认 <aliyun-ip>:3000, 见 hosts.cfg)
#   - curl + jq
# ============================================================================
set -euo pipefail
# 基础设施地址（gitignored: scripts/data/hosts.cfg）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
	for _d in "$(dirname "${BASH_SOURCE[0]}")/../../../data" "$(dirname "${BASH_SOURCE[0]}")/../../data"; do
		[[ -f "$_d/hosts.cfg" ]] && {
			HOSTS_CFG="$_d/hosts.cfg"
			break
		}
	done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
TENCENT_IP="${TENCENT_IP:-}"
ALIYUN_IP="${ALIYUN_IP:-}"
COMPANY_IP="${COMPANY_IP:-}"
SSH_USER="${SSH_USER:-}"

VAULT="${1:-}"
MODE="${2:-once}"
TARGET_FILE="${3:-}"
MIXAPI_URL="${MIXAPI_URL:-}"
[[ -z "$MIXAPI_URL" && -n "$ALIYUN_IP" ]] && MIXAPI_URL="http://${ALIYUN_IP}:3000"
MIXAPI_KEY="${MIXAPI_KEY:-rTOluHaft5Yh6UMFUH14B9R6h4jzz8amYki6FJ1Bhjeoeht6}"
MODEL="${MODEL:-qwen3.6-27b}"
LOG_FILE="log.md"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${GREEN}  [✓]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!]${NC} $*"; }
err() { echo -e "${RED}  [✗]${NC} $*" >&2; }

[[ -d "$VAULT/raw" ]] || {
	err "vault 缺少 raw/ 目录: $VAULT"
	exit 1
}
command -v curl >/dev/null || {
	err "缺少 curl"
	exit 1
}
command -v jq >/dev/null || {
	err "缺少 jq (brew install jq)"
	exit 1
}

# ── 分块编译: 大文件分段提炼后合并 ──────────────────────────────────────
compile_chunked() {
	local raw_file="$1" fname="$2" content="$3"
	local base chunks chunk summaries i

	base="$(basename "$raw_file" .md)"
	chunks=()
	for ((i = 0; i < ${#content}; i += 4000)); do
		chunks+=("${content:i:4000}")
	done
	info "分块处理: ${#chunks[@]} 块 (每块≤4000字符)"

	summaries=""
	i=0
	for chunk in "${chunks[@]}"; do
		i=$((i + 1))
		info "  块 $i/${#chunks[@]} 提炼..."
		local resp out
		resp="$(curl -s --max-time 180 -X POST "$MIXAPI_URL/v1/chat/completions" \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer $MIXAPI_KEY" \
			-d "$(jq -n --arg m "$MODEL" --arg p "你是知识库维护者。以下是长文档的第 $i/${#chunks[@]} 部分，请用中文提炼要点（bullet list），保留关键术语和概念，不要遗漏重要信息：\n\n$chunk" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:800,temperature:0.3}')")"
		out="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
		if [[ -z "$out" ]]; then
			warn "  块 $i 提炼失败，跳过"
			continue
		fi
		# 去 think 块
		out="$(printf '%s' "$out" | awk '
      /<think>/ { in_think = 1; next }
      in_think && /```/ { in_think = 0; next }
      in_think { next }
      { print }
    ')"
		summaries+="## 第${i}部分要点\n${out}\n\n"
	done

	if [[ -z "$summaries" ]]; then
		err "所有分块提炼失败: $fname"
		return 1
	fi

	info "合并提炼结果为 wiki 页..."
	local resp2 out2
	resp2="$(curl -s --max-time 180 -X POST "$MIXAPI_URL/v1/chat/completions" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $MIXAPI_KEY" \
		-d "$(jq -n --arg m "$MODEL" --arg p "你是知识库维护者。以下是长文档各部分要点，请整合为完整的 Obsidian wiki 页面。输出 Markdown，第一行 frontmatter:
---
type: concept|entity|summary|synthesis
source: \"[[raw/$fname]]\"
trusted: false
created: $(date +%F)
tags: []
---
正文用中文，结构清晰，重要概念用 [[wikilinks]]，不编造内容。

各部分要点:
$summaries" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:1200,temperature:0.3}')")"
	out2="$(printf '%s' "$resp2" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
	if [[ -z "$out2" ]]; then
		err "合并失败: $fname"
		return 1
	fi
	out2="$(printf '%s' "$out2" | awk '
    /<think>/ { in_think = 1; next }
    in_think && /```/ { in_think = 0; next }
    in_think { next }
    { print }
  ')"

	write_wiki_page "$fname" "$base" "$out2"
}

# ── 写入 wiki 页 + 更新 log/index ────────────────────────────────────────
write_wiki_page() {
	local fname="$1" base="$2" out="$3"
	local type dir
	type="$(printf '%s' "$out" | grep -m1 '^type:' | cut -d: -f2 | tr -d ' \"')"
	case "${type:-concept}" in
	entity) dir="entity" ;;
	summary) dir="summary" ;;
	synthesis) dir="synthesis" ;;
	*) dir="concept" ;;
	esac
	mkdir -p "$VAULT/wiki/$dir"

	local out_file="$VAULT/wiki/$dir/${base}.md"
	printf '%s\n' "$out" >"$out_file"
	info "已生成: wiki/$dir/${base}.md (type=$type)"

	echo "| $(date '+%F %T') | compile | [[raw/$fname]] | [[wiki/$dir/${base}.md]] |" >>"$VAULT/$LOG_FILE"

	local entry
	entry="* [[wiki/$dir/${base}.md]]"
	grep -qF "$entry" "$VAULT/wiki/index.md" 2>/dev/null || echo "$entry" >>"$VAULT/wiki/index.md"
}

# ── 编译单个文件 ──────────────────────────────────────────────────────────
compile_file() {
	local raw_file="$1"
	local base fname content
	base="$(basename "$raw_file" .md)"
	fname="$(basename "$raw_file")"

	# 跳过已处理（log.md 中有记录）
	if grep -q "|.*|.*${base}" "$VAULT/$LOG_FILE" 2>/dev/null; then
		warn "跳过(已处理): $fname"
		return 0
	fi

	content="$(cat "$raw_file")"

	info "编译: $fname (${#content} 字符)"

	# 大材料分块: 每块 ~4000 字符，逐块提炼后合并
	if [[ ${#content} -gt 4000 ]]; then
		compile_chunked "$raw_file" "$fname" "$content"
		return $?
	fi

	local prompt
	prompt="你是知识库维护者。将 raw 材料编译为 Obsidian wiki 页面。

规则:
1. 输出 Markdown，第一行是 frontmatter:
   ---
   type: concept|entity|summary|synthesis
   source: \"[[raw/$fname]]\"
   trusted: false
   created: $(date +%F)
   tags: []
   ---
2. 正文用中文，结构清晰，重要概念用 [[wikilinks]] 链接
3. 根据内容判断类型: 技术概念→concept, 具体事物→entity, 单篇摘要→summary, 多源综合→synthesis
4. 不编造原文没有的内容

原始材料:
---
$content"

	local resp
	resp="$(curl -s --max-time 300 -X POST "$MIXAPI_URL/v1/chat/completions" \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $MIXAPI_KEY" \
		-d "$(jq -n --arg m "$MODEL" --arg p "$prompt" '{model:$m,messages:[{role:"user",content:$p}],max_tokens:2000,temperature:0.3}')")"

	# 写临时文件避免 echo 破坏 JSON
	local tmp_out
	tmp_out="$(mktemp)"
	echo "$resp" >"$tmp_out"

	local out
	out="$(jq -r '.choices[0].message.content // empty' "$tmp_out" 2>/dev/null)"
	if [[ -z "$out" ]]; then
		err "编译失败: $fname"
		jq -r '.error.message // .' "$tmp_out" 2>/dev/null | head -2
		rm -f "$tmp_out"
		return 1
	fi
	rm -f "$tmp_out"

	# 清理: 去 think 块(可能无闭合标签) + 去代码块包裹
	# qwen 返回的 think 块可能无 </think> 闭合，遇到首个 ``` 即视为 think 结束
	out="$(printf '%s' "$out" | awk '
    /<think>/ { in_think = 1; next }
    in_think && /```/ { in_think = 0; next }
    in_think { next }
    { print }
  ')"
	# 去掉外层 ```yaml / ```markdown 包裹
	out="$(printf '%s' "$out" | sed -e '1{/^```/d}' -e '${/^```/d}')"

	write_wiki_page "$fname" "$base" "$out"
}

# ── 主流程 ────────────────────────────────────────────────────────────────
process_once() {
	local count=0
	if [[ -n "$TARGET_FILE" ]]; then
		compile_file "$VAULT/raw/$TARGET_FILE"
	else
		for f in "$VAULT"/raw/*.md; do
			[[ -f "$f" ]] || continue
			compile_file "$f" && count=$((count + 1))
		done
	fi
	info "本轮处理完成: $count 个文件"
}

# ── 监控模式 ──────────────────────────────────────────────────────────────
watch_loop() {
	info "监控模式: 每 60s 扫描 $VAULT/raw/ (Ctrl+C 退出)"
	while true; do
		process_once
		sleep 60
	done
}

case "$MODE" in
--watch) watch_loop ;;
--file)
	TARGET_FILE="${3:-}"
	[[ -n "$TARGET_FILE" ]] || {
		err "缺少文件名"
		exit 1
	}
	process_once
	;;
*) process_once ;;
esac
