#!/bin/sh
# ============================================================
# entrypoint.sh — Tailscale 容器入口脚本
# 用于 basic / exit / subnet 三种模式
#
# 密钥安全：
#   1. 从 /dev/shm/authkey 读取密钥（仅容器启动时存在）
#   2. 认证成功后立即 unset 密钥、删除密钥文件
#   3. 使用持久化 state 卷，后续重启不需再次认证
# ============================================================
set -e

# 读取认证密钥（优先从 /dev/shm 只读挂载的文件读取）
AUTH_KEY=""
if [ -f /dev/shm/authkey ]; then
	AUTH_KEY=$(cat /dev/shm/authkey)
elif [ -n "${HEADSCALE_AUTH_KEY:-}" ]; then
	AUTH_KEY="${HEADSCALE_AUTH_KEY}"
fi

# 如果没有密钥，检查是否已有持久化 state（重启场景）
if [ -z "$AUTH_KEY" ] && [ -f "${TAILSCALE_STATE_ARG:-/var/lib/tailscale/tailscaled.state}" ]; then
	echo "No auth key provided, but state file exists — attempting restart without re-auth."
fi

trap 'kill -TERM $PID' TERM INT

echo "Starting tailscaled..."
tailscaled -no-logs-no-support --state="${TAILSCALE_STATE_ARG}" &
PID=$!
sleep 1

# 如果有密钥，执行认证
if [ -n "$AUTH_KEY" ]; then
	# 构建 tailscale up 参数
	UP_ARGS="--authkey=${AUTH_KEY} --hostname=${TAILSCALE_HOSTNAME}"

	# 自定义登录服务器（Headscale 等）
	if [ -n "${TAILSCALE_SERVER:-}" ]; then
		UP_ARGS="${UP_ARGS} --login-server=${TAILSCALE_SERVER}"
	fi

	# 宣告路由（exit / subnet 模式）
	if [ -n "${ADVERTISE_ROUTES:-}" ]; then
		UP_ARGS="${UP_ARGS} --advertise-routes=${ADVERTISE_ROUTES}"
	fi

	# 接受路由
	if [ "${ACCEPT_ROUTES:-}" = "true" ]; then
		UP_ARGS="${UP_ARGS} --accept-routes"
	fi

	# exit node 标记
	if [ "${TAILSCALE_EXIT_NODE:-}" = "true" ]; then
		UP_ARGS="${UP_ARGS} --advertise-exit-node"
	fi

	echo "Authenticating to tailnet..."
	until tailscale up ${UP_ARGS}; do
		sleep 0.1
	done

	# ♻️ 安全清除：认证完成后立即清除密钥
	unset AUTH_KEY HEADSCALE_AUTH_KEY UP_ARGS
	rm -f /dev/shm/authkey 2>/dev/null || true
	echo "Auth key cleared from memory."
else
	echo "No auth key available. Starting tailscaled without authentication."
	echo "If state exists from previous auth, node should reconnect automatically."
fi

tailscale status

echo "Tailscale ready. PID=${PID}"

wait ${PID}
