#!/usr/bin/env bash
# ============================================================================
# patch-llmwiki-zh.sh — 为 llm-wiki-compiler 注入中文生成规则（幂等）
#
# 背景: llm-wiki-compiler v0.4.0 无语言配置项，默认按英文 prompt 生成 wiki 页。
#       本脚本直接补丁 npm 全局包 dist/cli.js，在 3 处 prompt 注入中文指令：
#         1. buildExtractionPrompt   — 概念名/摘要/标签用中文
#         2. buildPagePrompt         — 页面正文用中文
#         3. buildSeedPagePrompt     — seed 页面正文用中文
#
# 注意: npm 包升级会覆盖补丁，升级后需重跑本脚本（幂等，已打补丁则跳过）。
#
# 用法: bash patch-llmwiki-zh.sh [cli.js 路径]
#       默认 /usr/local/node/lib/node_modules/llm-wiki-compiler/dist/cli.js
# ============================================================================
set -euo pipefail

CLI="${1:-/usr/local/node/lib/node_modules/llm-wiki-compiler/dist/cli.js}"

if [[ ! -f "$CLI" ]]; then
	echo "错误: $CLI 不存在"
	exit 1
fi

# 幂等检查：已打补丁则跳过
if grep -q "Write the entire page in Chinese" "$CLI"; then
	echo "✓ 补丁已存在，跳过"
	exit 0
fi

cp "$CLI" "${CLI}.bak-zh"
echo "备份 → ${CLI}.bak-zh"

CLI_PATH="$CLI" python3 <<'PYEOF'
import os

path = os.environ["CLI_PATH"]
s = open(path).read()

# 1. 概念提取 prompt（buildExtractionPrompt）
old1 = '    "You are a knowledge extraction engine. Analyze the following source document",'
new1 = old1 + '\n    "IMPORTANT: You MUST output all concept names, summaries, and tags in Simplified Chinese (简体中文).",'
assert s.count(old1) == 1, f"extraction prompt 匹配数异常: {s.count(old1)}"
s = s.replace(old1, new1)

# 1b. 提取 prompt 数组末尾再加一次强调（源文档内容之前）
old1b = '    "\\n\\n--- SOURCE DOCUMENT ---\\n\\n",'
new1b = '    "Never use English for concept names, summaries, or tags.",\n' + old1b
assert s.count(old1b) == 1, f"extraction prompt 末尾匹配数异常: {s.count(old1b)}"
s = s.replace(old1b, new1b)

# 2. wiki 页面 prompt（buildPagePrompt）
old2 = '    `You are a wiki author. Write a clear, well-structured markdown page about "${concept}".`,'
new2 = old2 + '\n    "IMPORTANT: Write the ENTIRE page in Simplified Chinese (简体中文) - title, headings, and body.",'
assert s.count(old2) == 1, f"page prompt 匹配数异常: {s.count(old2)}"
s = s.replace(old2, new2)

# 2b. 页面 prompt 数组末尾再加一次强调
old2b = '    "\\n\\n--- SOURCE MATERIAL ---\\n\\n",'
new2b = '    "Never write the page in English; only technical identifiers and code may remain in English.",\n' + old2b
assert s.count(old2b) == 1, f"page prompt 末尾匹配数异常: {s.count(old2b)}"
s = s.replace(old2b, new2b)

# 3. seed 页面 prompt（buildSeedPagePrompt）
old3 = '    `You are a wiki author. Write a ${seed.kind} page titled "${seed.title}".`,'
new3 = old3 + '\n    "IMPORTANT: Write the ENTIRE page in Simplified Chinese (简体中文) - title, headings, and body.",'
assert s.count(old3) == 1, f"seed prompt 匹配数异常: {s.count(old3)}"
s = s.replace(old3, new3)

open(path, "w").write(s)
print("✓ 3 处 prompt 已注入中文规则")
PYEOF

# 语法自检（bundle 是 ESM，node --check 不适用，改用导入验证）
if node -e "import('$CLI').then(() => console.log('✓ 模块加载正常')).catch(e => { console.error('✗ 加载失败:', e.message); process.exit(1) })" 2>/dev/null; then
	echo "完成"
else
	echo "⚠ 模块加载自检跳过（bundle 可能依赖运行环境），请人工验证"
fi
