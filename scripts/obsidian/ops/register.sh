#!/usr/bin/env bash
# register.sh — 注册 obsidian CLI 工具到 shell 环境
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 打印注册代码
#
# 注册内容:
#   - obsidian-export → PATH (cargo bin)
#   - open -a Obsidian → alias ob

set -euo pipefail
NAME="obsidian"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../register-lib.sh"

gen_code() {
    cat <<CODE
# ${NAME} — Obsidian CLI 工具
export PATH="\${PATH}:\${HOME}/.cargo/bin"
alias ob='open -a Obsidian'
CODE
}

playground_register_main "$@"
