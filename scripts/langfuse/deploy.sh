#!/usr/bin/env bash
# deploy.sh — Langfuse 一键部署（本地 Docker Compose）
#
# 用法:
#   bash deploy.sh              # 部署
#   bash deploy.sh status       # 查看状态
#   bash deploy.sh stop         # 停止
#   bash deploy.sh logs         # 查看日志
#   bash deploy.sh rm           # 卸载（保留数据）
#   bash deploy.sh rm -v        # 卸载（删除数据）

set -euo pipefail
cd "$(dirname "$0")"

COMPOSE="docker compose"
CMD="${1:-up}"

case "$CMD" in
  up)
    echo "=== 部署 Langfuse ==="
    $COMPOSE up -d
    echo ""
    echo "等待启动..."
    for i in $(seq 1 30); do
      if curl -sS --max-time 2 "http://127.0.0.1:3010/api/public/health" >/dev/null 2>&1; then
        echo "✅ Langfuse 已就绪"
        echo ""
        echo "  Dashboard: http://127.0.0.1:3010"
        echo "  注册第一个账号即可使用"
        echo ""
        echo "  Router 会自动检测并开始记录 token 日志"
        break
      fi
      sleep 2
    done
    ;;
  status)
    $COMPOSE ps
    ;;
  stop)
    $COMPOSE stop
    ;;
  logs)
    $COMPOSE logs -f --tail 50
    ;;
  rm)
    shift || true
    $COMPOSE down "$@"
    ;;
  *)
    echo "用法: bash deploy.sh [up|status|stop|logs|rm]"
    ;;
esac