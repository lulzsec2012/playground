#!/usr/bin/env bash
# install.sh — 统一注册所有 scripts/*/register.sh
#
# 用法:
#   bash install.sh              # 全量注册
#   bash install.sh --dry-run    # 预览（只打印，不写入）
#   bash install.sh --help       # 帮助
#
# 行为:
#   1. 清空 ~/.config/playground/registrations.d/
#   2. 运行所有 scripts/*/register.sh
#   3. 确保 shell rc 文件加载 registrations.d/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG_DIR="$HOME/.config/playground/registrations.d"
DRY_RUN=false

# ====== Shell RC 检测 ======
detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "${HOME}/.zshrc" ;;
        bash)
            [[ -f "${HOME}/.bash_profile" ]] && echo "${HOME}/.bash_profile" && return
            echo "${HOME}/.bashrc" ;;
        *)    echo "${HOME}/.profile" ;;
    esac
}

# ====== 确保 rc 文件加载 registrations.d/ ======
ensure_rc_sources_reg_dir() {
    local rc_file
    rc_file="$(detect_rc)"
    [[ -z "$rc_file" || ! -f "$rc_file" ]] && return
    local line='[ -d "$HOME/.config/playground/registrations.d" ] && for f in "$HOME/.config/playground/registrations.d/"*.sh; do [ -f "$f" ] && . "$f" 2>/dev/null; done || true'

    if grep -qxF "$line" "$rc_file" 2>/dev/null; then
        echo "    ✓ rc 文件已包含 registrations.d/ 加载配置"
        return 0
    fi

    echo "" >> "$rc_file"
    echo "# Playground scripts registration" >> "$rc_file"
    echo "$line" >> "$rc_file"
    echo "   ✓ 已将 registrations.d/ 加载配置写入 ${rc_file}"
    echo ""
    echo "   执行以下命令立即生效:"
    echo "   source ${rc_file}"
}

# ====== 解析参数 ======
case "${1:-}" in
    --dry-run|-n)
        DRY_RUN=true
        ;;
    --help|-h)
        echo "用法: bash install.sh [--dry-run]"
        echo ""
        echo "  全量注册 playground 脚本到 shell 环境。"
        echo "  遍历所有 scripts/*/register.sh 并执行。"
        exit 0
        ;;
esac

# ====== 收集所有 register.sh ======
echo "🔍 扫描 register.sh..."
register_scripts=()
while IFS= read -r -d '' reg; do
    register_scripts+=("$reg")
done < <(find "$SCRIPT_DIR" -name 'register.sh' -print0 2>/dev/null)

if [[ ${#register_scripts[@]} -eq 0 ]]; then
    echo "❌ 未找到任何 register.sh"
    exit 1
fi

echo "   发现 ${#register_scripts[@]} 个:"
for reg in "${register_scripts[@]}"; do
    echo "   • ${reg#$SCRIPT_DIR/}"
done

# ====== 主流程 ======
if $DRY_RUN; then
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  [DRY RUN] 预览模式，不执行写入"
    echo "═══════════════════════════════════════════"
    echo ""
    for reg in "${register_scripts[@]}"; do
        name="$(basename "$(dirname "$reg")")"
        echo "── ${name}/register.sh ──"
        bash "$reg" --print 2>/dev/null || echo "  (错误: 执行失败)"
        echo ""
    done
else
    echo ""
    echo "📦 清空 registrations.d/..."
    rm -rf "$REG_DIR"
    mkdir -p "$REG_DIR"

    echo "📝 执行注册..."
    for reg in "${register_scripts[@]}"; do
        name="$(basename "$(dirname "$reg")")"
        echo "   → ${name}"
        bash "$reg"
    done

    echo ""
    echo "🔗 确保 rc 文件加载 registrations.d/..."
    ensure_rc_sources_reg_dir

    echo ""
    echo "═══════════════════════════════════════════"
    echo "  ✅ 注册完成"
    echo "═══════════════════════════════════════════"
    echo "   已注册: ${#register_scripts[@]} 个"
    echo "   目录: ${REG_DIR}/"
    ls -1 "$REG_DIR/" 2>/dev/null | sed 's/^/     • /'

    rc_file="$(detect_rc)"
    echo ""
    echo "💡 执行以下命令使所有注册立即生效:"
    echo "   source ${rc_file}"
fi
