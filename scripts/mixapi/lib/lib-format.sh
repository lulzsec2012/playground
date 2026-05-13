#!/usr/bin/env bash
#
# lib-format.sh — 颜色、日志、格式化工具函数
#
# Usage: source "$(dirname "$0")/lib/lib-format.sh"
#
# 提供统一风格的终端输出函数，被所有 mixapi 脚本共用。

# 只在首次 source 时定义常量
if [[ -z "${__LIB_FORMAT_LOADED:-}" ]]; then
  readonly __LIB_FORMAT_LOADED=1

  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly CYAN='\033[0;36m'
  readonly RED='\033[0;31m'
  readonly NC='\033[0m'
fi

# 输出成功消息（stderr，不污染 stdout 数据通道）
ok() {
  echo -e "  ${GREEN}✓${NC} $*" >&2
}

# 输出警告消息（stderr）
warn() {
  echo -e "  ${YELLOW}⚠${NC} $*" >&2
}

# 输出信息标题（stderr）
info() {
  echo -e "${CYAN}$*${NC}" >&2
}

# 输出错误并退出（stderr）
die() {
  echo -e "${RED}❌ $*${NC}" >&2
  exit 1
}

# 输出等待提示，不换行（stderr）
wait_ok() {
  echo -ne "  ⏳ $*..." >&2
}

# 打印带分隔线的标题块（stderr）
section() {
  local title="$1"
  echo "" >&2
  info "══════════════════════════════════════"
  info "  ${title}"
  info "══════════════════════════════════════"
  echo "" >&2
}
