#!/usr/bin/env bash
# ============================================================================
# setup-wiki-schema.sh — 在 Obsidian vault 中初始化 LLM Wiki 结构（阶段3）
#
# 创建:
#   <vault>/raw/         原始材料（剪藏、文章、会话记录）
#   <vault>/wiki/        编译产物（index.md + entities/ + concepts/ + summaries/ + syntheses/）
#   <vault>/trusted/     人工审核内容
#   <vault>/log.md       编译操作日志
#   <vault>/AGENTS.md    LLM 维护规则（Karpathy 模式）
#
# 用法:
#   bash setup-wiki-schema.sh /path/to/vault
# ============================================================================
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
NC='\033[0m'

VAULT_PATH="${1:-}"
if [[ -z "$VAULT_PATH" ]]; then
	echo "用法: bash $0 /path/to/vault"
	exit 1
fi

[[ -d "$VAULT_PATH" ]] || {
	echo "❌ 目录不存在: $VAULT_PATH"
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 创建目录 ──────────────────────────────────────────────────────────────
mkdir -p "$VAULT_PATH"/{raw,wiki,trusted}
mkdir -p "$VAULT_PATH"/wiki/{entities,concepts,summaries,syntheses}
echo "  ✓ 目录结构: raw/ wiki/{entities,concepts,summaries,syntheses}/ trusted/"

# ── AGENTS.md ─────────────────────────────────────────────────────────────
if [[ ! -f "$VAULT_PATH/AGENTS.md" ]]; then
	cp "${SCRIPT_DIR}/../wiki-schema/AGENTS.md" "$VAULT_PATH/AGENTS.md"
	echo "  ✓ AGENTS.md (LLM 维护规则)"
fi

# ── index.md ──────────────────────────────────────────────────────────────
if [[ ! -f "$VAULT_PATH/wiki/index.md" ]]; then
	cat >"$VAULT_PATH/wiki/index.md" <<'MD'
# Knowledge Index

> 由 LLM 维护的导航索引 — 每次 compile 后更新

## Entities
```dataview
LIST FROM "wiki/entities" WHERE file.name != "index"
```

## Concepts
```dataview
LIST FROM "wiki/concepts" WHERE file.name != "index"
```

## Summaries
```dataview
LIST FROM "wiki/summaries" WHERE file.name != "index"
```

## Syntheses
```dataview
LIST FROM "wiki/syntheses" WHERE file.name != "index"
```
MD
	echo "  ✓ wiki/index.md (Dataview 导航)"
fi

# ── log.md ────────────────────────────────────────────────────────────────
if [[ ! -f "$VAULT_PATH/log.md" ]]; then
	echo "# 编译日志" >"$VAULT_PATH/log.md"
	echo "" >>"$VAULT_PATH/log.md"
	echo "| 时间 | 操作 | 输入 | 输出 |" >>"$VAULT_PATH/log.md"
	echo "|:-----|:-----|:-----|:-----|" >>"$VAULT_PATH/log.md"
	echo "  ✓ log.md"
fi

# ── raw/.gitkeep ──────────────────────────────────────────────────────────
touch "$VAULT_PATH/raw/.gitkeep" "$VAULT_PATH/trusted/.gitkeep"
echo "  ✓ 初始化完成"

cat <<EOF

${GREEN}============================================================${NC}
  LLM Wiki 结构就绪
${GREEN}============================================================${NC}
  Vault: ${VAULT_PATH}
    raw/        投喂原始材料（剪藏/文章/会话）
    wiki/       LLM 编译产物（entity/concept/summary/synthesis）
    trusted/    人工审核通过的内容
    AGENTS.md   LLM 维护规则

  使用方式:
    1. 剪藏文章 → raw/
    2. 让 OpenCode/Copilot 读 AGENTS.md 执行 compile
    3. 人工 review wiki/ 中新页面 → 标记 trusted
EOF
