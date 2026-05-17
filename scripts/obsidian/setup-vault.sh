#!/usr/bin/env bash
# ============================================================================
# Obsidian Vault 初始化脚本
# 用法: bash setup-vault.sh /path/to/vault [--force]
# ============================================================================
set -euo pipefail

VAULT_PATH="${1:-}"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --force)  FORCE=true ;;
    --help|-h)
      echo "用法: bash setup-vault.sh /path/to/vault [--force]"
      echo ""
      echo "  创建 Obsidian vault 目录结构 + 默认配置"
      echo "  --force    覆盖已存在的 .obsidian/ 配置"
      exit 0 ;;
  esac
done

if [[ -z "$VAULT_PATH" ]]; then
  echo "用法: bash setup-vault.sh /path/to/vault [--force]"
  exit 1
fi

VAULT_PATH="$(cd "$(dirname "$VAULT_PATH")" 2>/dev/null && pwd)/$(basename "$VAULT_PATH")"
OBS_DIR="${VAULT_PATH}/.obsidian"
PLUGINS_DIR="${OBS_DIR}/plugins"
THEMES_DIR="${OBS_DIR}/themes"
SNIPPETS_DIR="${OBS_DIR}/snippets"

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}  [INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $1"; }
step()  { echo -e "\n${CYAN}  >>>${NC} ${BOLD}$1${NC}"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }

# ── 检查 ──────────────────────────────────────────────────────────────────
if [[ -d "$OBS_DIR" ]]; then
  if $FORCE; then
    warn "已存在 .obsidian/ 配置, --force 覆盖"
  else
    echo "❌ ${VAULT_PATH} 已初始化过的 vault (.obsidian/ 已存在)"
    echo "   使用 --force 覆盖配置"
    exit 1
  fi
fi

# ── 创建 vault 目录层级 ──────────────────────────────────────────────────
step "创建 vault 目录结构"

mkdir -p "$VAULT_PATH"/{daily,projects,reference}
mkdir -p "$OBS_DIR" "$PLUGINS_DIR" "$THEMES_DIR" "$SNIPPETS_DIR"
ok "vault: ${VAULT_PATH}"

# ── 默认社区插件配置 ──────────────────────────────────────────────────────
step "社区插件配置"

cat > "${OBS_DIR}/community-plugins.json" <<'JSON'
[
  "obsidian-local-rest-api",
  "dataview"
]
JSON
ok "community-plugins.json (Local REST API + Dataview)"

# ── 应用设置 ──────────────────────────────────────────────────────────────
step "应用设置"

cat > "${OBS_DIR}/config" <<'JSON'
{
  "alwaysUpdateLinks": true,
  "attachmentFolderPath": "./attachments",
  "newFileLocation": "folder",
  "newFileFolderPath": "daily",
  "showLineNumber": true,
  "spellcheck": true,
  "tabSize": 2,
  "useTab": false,
  "vimMode": false,
  "readableLineLength": true,
  "strictLineBreaks": false,
  "showFrontmatter": true,
  "showIndentGuide": true,
  "autoPairBrackets": true,
  "autoPairMarkdown": true,
  "smartIndentList": true,
  "promptDelete": false,
  "trashOption": "local",
  "communityThemeEnabled": true,
  "theme": "obsidian",
  "baseFontSize": 16,
  "enabledPlugins": [
    "obsidian-local-rest-api",
    "dataview"
  ]
}
JSON
ok "config 已写入"

# ── 外观设置 ──────────────────────────────────────────────────────────────
step "外观设置"

cat > "${OBS_DIR}/appearance.json" <<'JSON'
{
  "accentColor": "",
  "cssTheme": "",
  "enabledCssSnippets": [],
  "theme": "obsidian",
  "baseFontSize": 16,
  "interfaceFontFamily": "",
  "textFontFamily": "",
  "monospaceFontFamily": ""
}
JSON
ok "appearance.json"

# ── 快捷键 ──────────────────────────────────────────────────────────────
step "快捷键"

cat > "${OBS_DIR}/hotkeys.json" <<'JSON'
[]
JSON
ok "hotkeys.json (默认)"

# ── 首页笔记 ──────────────────────────────────────────────────────────────
step "首页笔记"

cat > "${VAULT_PATH}/README.md" <<'EOF'
---
created: {{DATE}}
tags: [meta]
---

# 我的 Obsidian Vault

## 目录结构

```
/
├── daily/          # 日常笔记
├── projects/       # 项目笔记
└── reference/      # 知识库
```

## OpenCode 集成

参考 `scripts/obsidian/README.md` 中的集成方案。
EOF

ok "README.md"

# ── .gitignore (可选, 放在 vault 根目录) ──────────────────────────────────
step "vault .gitignore"

cat > "${VAULT_PATH}/.gitignore" <<'EOF'
# Obsidian 配置 (各设备独立)
.obsidian/workspace
.obsidian/workspace.json
.obsidian/plugins/*/node_modules/
.obsidian/plugins/*/dist/

# 系统文件
.DS_Store
Thumbs.db
EOF
ok ".gitignore"

# ── 完成 ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Vault 初始化完成${NC}"
echo ""
echo "  路径: ${VAULT_PATH}"
echo "  打开方式:"
echo "    open -a Obsidian                                      # macOS"
echo "    obsidian-export ${VAULT_PATH} /tmp/export             # CLI 导出"
echo ""
echo "  接下来:"
echo "    1. 在 Obsidian 中打开此 vault: 设置 → 管理 vault → 打开其他 vault"
echo "    2. 安装推荐插件 (已在 community-plugins.json 中):"
echo "       - Local REST API (OpenCode 集成必需)"
echo "       - Dataview (会话知识库面板)"
echo "    3. 配置 REST API key 供 OpenCode 使用"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
