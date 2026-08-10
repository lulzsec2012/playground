#!/usr/bin/env bash
# ============================================================================
# llmwiki-clean.sh — 清理 llmwiki 生成页面的 qwen think 残留块
#
# qwen3.6-27b 输出含 <think> 推理块（可能无 </think> 闭合），
# llmwiki 不会清理，需此脚本后处理。
#
# 用法: bash llmwiki-clean.sh <wiki-dir>   (默认: ./wiki)
# ============================================================================
set -euo pipefail

WIKI_DIR="${1:-wiki}"
[[ -d "$WIKI_DIR" ]] || {
	echo "❌ 目录不存在: $WIKI_DIR"
	exit 1
}

find "$WIKI_DIR" -name "*.md" -type f | while read -r f; do
	if grep -q "<think>" "$f"; then
		python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
c = open(path).read()
if "<think>" in c:
    if "</think>" in c:
        c = c.split("<think>", 1)[0] + c.split("</think>", 1)[1]
    else:
        parts = c.split("<think>", 1)
        tail = parts[1]
        idx = len(tail)
        for marker in ["```", "\n\n\n"]:
            m = tail.find(marker)
            if m != -1 and m < idx:
                idx = m
        c = parts[0] + tail[idx:].lstrip("\n")
        if c.startswith("```"):
            c = c.split("```", 1)[1]
            if c.rstrip().endswith("```"):
                c = c.rstrip()[:-3]
open(path, "w").write(c)
print(f"已清理: {path}")
PY
	fi
done
