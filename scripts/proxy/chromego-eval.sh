#!/usr/bin/env bash
# chromego-eval.sh — 评估所有代理节点延迟并推荐最佳节点
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "  sing-box 代理节点质量评估"
echo "========================================"
echo ""

if ! curl -s http://127.0.0.1:9090 >/dev/null 2>&1; then
  echo "X sing-box Clash API 不可用 (127.0.0.1:9090)"
  exit 1
fi

python3 chromego-eval.py

echo ""
echo "  切换最佳节点:"
echo '    curl -X PUT http://127.0.0.1:9090/proxies/proxy-select \'
echo "      -d '{\"name\":\"<node-name>\"}' \\"
echo '      -H "Content-Type: application/json"'
