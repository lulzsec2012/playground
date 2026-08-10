#!/usr/bin/env bash
# register.sh — 注册 headscale 常用命令到 shell 环境
#
# 用法:
#   bash register.sh              # 注册（默认）
#   bash register.sh --print      # 打印注册代码

set -euo pipefail
# 基础设施地址（gitignored: scripts/data/hosts.cfg, 模板 hosts.cfg.example）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
	for _d in "$(dirname "${BASH_SOURCE[0]}")/../../data" "$(dirname "${BASH_SOURCE[0]}")/../data"; do
		[[ -f "$_d/hosts.cfg" ]] && {
			HOSTS_CFG="$_d/hosts.cfg"
			break
		}
	done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
TENCENT_IP="${TENCENT_IP:-}"
ALIYUN_IP="${ALIYUN_IP:-}"
COMPANY_IP="${COMPANY_IP:-}"
DEV_HOST_IP="${DEV_HOST_IP:-}"
DEV_HOST2_IP="${DEV_HOST2_IP:-}"
TAILSCALE_HOST_IP="${TAILSCALE_HOST_IP:-}"
DEV_CONTAINER_IP="${DEV_CONTAINER_IP:-}"
NAS_IP="${NAS_IP:-}"
SSH_USER="${SSH_USER:-}"

NAME="headscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG_DIR="$HOME/.config/playground/registrations.d"
REG_FILE="${REG_DIR}/${NAME}.sh"

# ── Shell RC 检测 ─────────────────────────────────────────────────────────
detect_rc() {
	case "${SHELL##*/}" in
	zsh) echo "${HOME}/.zshrc" ;;
	bash)
		[[ -f "${HOME}/.bash_profile" ]] && echo "${HOME}/.bash_profile" && return
		echo "${HOME}/.bashrc"
		;;
	*) echo "${HOME}/.profile" ;;
	esac
}

# ── 生成注册代码 ──────────────────────────────────────────────────────────
gen_code() {
	cat <<CODE
# ${NAME} — headscale 自建控制面（控制服务器在腾讯云 ECS ${TENCENT_IP}）
HS_ECS="${SSH_USER}@${TENCENT_IP}"
alias hs-ctrl='ssh \${HS_ECS} sudo headscale'
alias hs-nodes='ssh \${HS_ECS} sudo headscale nodes list'
alias hs-users='ssh \${HS_ECS} sudo headscale users list'
alias hs-keys='ssh \${HS_ECS} sudo headscale preauthkeys list'
alias hs-join='sudo bash ${SCRIPT_DIR}/../nodes/join-client.sh'
alias hs-status='tailscale status'
# headscale 链路 SSH（经 NAS SOCKS5 跳板）— 替代失效的旧 tailscale alias
alias ssh-210-hs='ssh hs-210-2225'
alias ssh-ecs-hs='ssh hs-tencent'
alias ssh-210-2225='ssh hs-210-2225'
CODE
}

# ── 确保 rc 文件加载 registrations.d/ ────────────────────────────────────
ensure_rc_sources_reg_dir() {
	local rc_file
	rc_file="$(detect_rc)"
	local line='[ -d "$HOME/.config/playground/registrations.d" ] && for f in "$HOME/.config/playground/registrations.d/"*.sh; do [ -f "$f" ] && . "$f" 2>/dev/null; done || true'

	if grep -qxF "$line" "$rc_file" 2>/dev/null; then
		return 0
	fi
	echo "" >>"$rc_file"
	echo "# Playground scripts registration" >>"$rc_file"
	echo "$line" >>"$rc_file"
}

# ── 安装 ──────────────────────────────────────────────────────────────────
install() {
	mkdir -p "$REG_DIR"
	gen_code >"$REG_FILE"
	echo "   ✓ 写入 ${REG_FILE}"
	ensure_rc_sources_reg_dir
	source "$REG_FILE" 2>/dev/null || true
	echo "   ✓ ${NAME} 已注册"
}

# ── 主流程 ────────────────────────────────────────────────────────────────
case "${1:-}" in
--print | -p) gen_code ;;
--help | -h)
	echo "用法: bash register.sh [--print]"
	exit 0
	;;
*) install ;;
esac
