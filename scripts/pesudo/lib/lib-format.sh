#!/usr/bin/env bash
#
# lib-format.sh — 颜色、日志、格式化工具函数
#
# Usage: source "$(dirname "$0")/lib/lib-format.sh"
#
# 与 scripts/mixapi/lib/lib-format.sh 保持一致的输出风格

# 只在首次 source 时定义常量
if [[ -z "${__LIB_FORMAT_LOADED:-}" ]]; then
  readonly __LIB_FORMAT_LOADED=1
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly CYAN='\033[0;36m'
  readonly RED='\033[0;31m'
  readonly NC='\033[0m'
fi

ok()    { echo -e "  ${GREEN}✓${NC} $*" >&2; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*" >&2; }
info()  { echo -e "${CYAN}$*${NC}" >&2; }
die()   { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }
wait_ok() { echo -ne "  ⏳ $*..." >&2; }
section() {
  local title="$1"
  echo "" >&2
  info "══════════════════════════════════════"
  info "  ${title}"
  info "══════════════════════════════════════"
  echo "" >&2
}
