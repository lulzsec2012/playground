#!/usr/bin/env bash
#
# cron-install.sh — 安装/移除 fetch.sh 的每日自动更新 cron
#
# 用法: bash cron-install.sh install    # 安装 cron（每天 03:00）
#       bash cron-install.sh remove     # 移除 cron
#       bash cron-install.sh show       # 查看当前 cron 状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch.sh"
CRON_LINE="0 3 * * * cd ${SCRIPT_DIR} && bash ${FETCH_SCRIPT} >/dev/null 2>&1"

usage() {
    cat <<EOF
安装/移除 fetch.sh 的每日自动更新 cron

用法: bash $(basename "$0") <install|remove|show>

命令:
  install  安装 cron（每天 03:00 自动更新代理配置）
  remove   移除 cron
  show     查看当前 cron 状态
EOF
    exit 1
}

case "${1:-}" in
    install)
        if crontab -l 2>/dev/null | grep -qF "$FETCH_SCRIPT"; then
            echo "cron 已存在，跳过"
            exit 0
        fi
        (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
        echo "✅ cron 已安装: 每天 03:00 执行 fetch.sh"
        ;;
    remove)
        crontab -l 2>/dev/null | grep -vF "$FETCH_SCRIPT" | crontab - || true
        echo "✅ cron 已移除"
        ;;
    show)
        if crontab -l 2>/dev/null | grep -qF "$FETCH_SCRIPT"; then
            echo "cron 状态: 已安装"
            crontab -l 2>/dev/null | grep "fetch.sh"
        else
            echo "cron 状态: 未安装"
        fi
        ;;
    -h|--help) usage ;;
    *) echo "未知命令: ${1:-}"; usage ;;
esac
