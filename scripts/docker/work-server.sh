#!/usr/bin/env bash
set -e

# ====== Source guard: 此脚本必须 source 执行，不可直接运行 ======
if ! (return 0 2>/dev/null); then
	echo "错误：此脚本必须 source 执行，不可直接运行。" >&2
	echo "" >&2
	echo "  正确用法：" >&2
	echo "    source scripts/docker/work-server.sh" >&2
	echo "    work-server default        # 启动实例" >&2
	echo "    work-server-ls             # 列出所有实例" >&2
	echo "    work-server-exec <name>    # 进入实例" >&2
	echo "    work-server-stop <name>    # 停止实例" >&2
	echo "    work-server-rm <name>      # 删除实例" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 基础设施地址（gitignored: scripts/data/hosts.cfg, 模板 hosts.cfg.example）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
	for _d in "$SCRIPT_DIR/../data" "$SCRIPT_DIR/../../data"; do
		[[ -f "$_d/hosts.cfg" ]] && {
			HOSTS_CFG="$_d/hosts.cfg"
			break
		}
	done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
TENCENT_IP="${TENCENT_IP:-}"

if [ -z "$HOST_IP" ]; then
	# Detect physical machine IP from host network namespace (works inside containers too)
	HOST_IP=$(docker run --rm --net=host alpine ip -o -4 addr show 2>/dev/null |
		grep -vE '\s+(lo|docker|br-)\s' |
		awk 'NR==1{print $4}' |
		cut -d/ -f1)
fi
if [ -z "$HOST_IP" ]; then
	HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
export HOST_IP
: "${HOST_PORT:=}"

# Dockerfiles: https://github.com/lulzsec2012/docker.git
declare -A INSTANCES=(
	[default]="2222:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
	[test]="2223:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
	# linux: 非 GPU 开发容器（原 cpu 实例；work-dev:ubuntu22.04 镜像已不可拉取，改用 work-cuda-dev）
	[linux]="2224:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
	[dev]="2225:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
	[lite]="2221:ubuntu-lite:24.04"
)

INSTANCES_DIR="$HOME/.docker/instances"
CLASH_CONFIG="$HOME/.docker/clash_config"

usage() {
	echo "Usage: source work-server.sh && <command> [instance] [-f]"
	echo ""
	echo "Commands:"
	echo "  work-server [instance] [-f]    Start container for instance"
	echo "  work-server-exec [instance]    Enter running container"
	echo "  work-server-ls                 List all instances"
	echo "  work-server-rm [instance]      Remove container"
	echo "  work-server-stop [instance]    Stop container"
	echo ""
	echo "Instances:"
	for inst in "${!INSTANCES[@]}"; do
		local IFS=":"
		read -r port image <<<"${INSTANCES[$inst]}"
		printf "  %-12s port=%-4s %s\n" "$inst" "$port" "$image"
	done
}

work-server() {
	local instance="${1:-default}"
	local force=false
	[[ "$2" == "-f" ]] && force=true

	local IFS=":"
	read -r port image <<<"${INSTANCES[$instance]}"
	if [[ -z "$port" ]]; then
		echo "❌ Unknown instance: $instance"
		echo "Available: ${!INSTANCES[*]}"
		return 1
	fi

	# Lite mode: only 'lite' instance skips GPU/privileged flags and uses /home/$USER config
	local is_lite=false
	[[ "$instance" == "lite" ]] && is_lite=true

	local name="${USER}-work-server-${instance}"
	local config_dir
	config_dir=$(TMPDIR=/dev/shm mktemp -d -t "docker-instance-${instance}-XXXXXX")
	# shellcheck disable=SC2064  # intentional: expand $config_dir now (local var out of scope on RETURN)
	trap "rm -rf '${config_dir}'" RETURN

	echo "📝 Generating config for '$instance'..."
	bash "$SCRIPT_DIR/generate-home-config.sh" "$config_dir"

	# Auto-configure Clash proxy — if no subscription URL, download free proxies
	if ! grep -qE '^CLASH_SUBSCRIPTION_URL=.+' "$config_dir/.ssh/vpn.cfg" 2>/dev/null; then
		if [ ! -f "$CLASH_CONFIG/clash_config.yaml" ]; then
			echo "📡 No Clash subscription URL. Fetching free proxies..."
			mkdir -p "$CLASH_CONFIG"
			if [ -f "$SCRIPT_DIR/../proxy/proxy-fetch.sh" ]; then
				if command -v timeout &>/dev/null; then
					timeout 90 bash "$SCRIPT_DIR/../proxy/proxy-fetch.sh" 2>/dev/null || true
				else
					bash "$SCRIPT_DIR/../proxy/proxy-fetch.sh" 2>/dev/null || true
				fi
				if [ -f "$SCRIPT_DIR/../proxy/config.yaml" ]; then
					NODES=$(grep -c '^- name:' "$SCRIPT_DIR/../proxy/config.yaml" 2>/dev/null || echo 0)
					if [ "$NODES" -gt 0 ]; then
						cp "$SCRIPT_DIR/../proxy/config.yaml" "$CLASH_CONFIG/clash_config.yaml"
						echo "  ✅ Free proxy config saved ($NODES nodes)"
					fi
				fi
			fi
			if [ ! -f "$CLASH_CONFIG/clash_config.yaml" ]; then
				echo "mixed-port: 7890" >"$CLASH_CONFIG/clash_config.yaml"
				echo "  ℹ️ Created minimal clash config (placeholder, no nodes)"
			fi
		fi
	fi

	if docker inspect "$name" >/dev/null 2>&1; then
		$force && docker container rm -f "$name" >/dev/null 2>&1
	fi

	declare -a volumes=(
		--volume="$HOME/workspace:/workspace:cached"
		--volume="/var/run/docker.sock:/var/run/docker.sock"
	)

	if [[ -d "$CLASH_CONFIG" ]]; then
		volumes+=(--volume="$CLASH_CONFIG:/clash_config:cached")
	fi

	# CUDA 实例挂载共享目录
	if ! $is_lite; then
		declare -a shared_dirs=(
			"/share_data" "/software_data" "/data"
			"/zjshare_data" "/softhome" "/share" "/data_gpu"
		)
		for dir in "${shared_dirs[@]}"; do
			if [[ -d "$dir" ]]; then
				volumes+=(--volume="$dir:$dir")
			fi
		done
	fi

	declare -a docker_opts=(
		--log-driver=none
	)
	if $is_lite; then
		docker_opts+=(--security-opt seccomp=unconfined --network host)
	else
		# CUDA: GPU access and performance tuning
		# linux 实例为非 GPU 开发容器，不挂 GPU；
		# 宿主机 nvidia 驱动异常（driver/library version mismatch）时可用 WORK_SERVER_GPU=0 强制禁用
		declare -a gpu_opts=()
		local use_gpu=true
		if $is_lite || [[ "$instance" == "linux" ]]; then
			use_gpu=false
		fi
		[[ "${WORK_SERVER_GPU:-1}" == "0" ]] && use_gpu=false
		if $use_gpu && docker info 2>/dev/null | grep -qi "Runtimes.*nvidia"; then
			gpu_opts=(--gpus all)
		fi
		docker_opts+=(--privileged "${gpu_opts[@]}" --ipc=host --ulimit memlock=-1:-1)
	fi

	declare -a port_opts=()
	if ! $is_lite; then
		port_opts+=(-p "$port:22")
	fi

	# headscale 组网：设置 HEADSCALE_AUTH_KEY 后透传 tailscale 环境变量（镜像 start.sh 消费）
	# 默认控制面 https://${TENCENT_IP}:8443（hosts.cfg），可用 HEADSCALE_SERVER 覆盖
	# 兼容旧约定：HEADSCALE_AUTH_KEY 未设置时回退 TAILSCALE_AUTH_KEY（旧 vpn.cfg/环境变量）
	local ts_env=()
	local ts_auth_key="${HEADSCALE_AUTH_KEY:-${TAILSCALE_AUTH_KEY:-}}"
	if [ -n "$ts_auth_key" ]; then
		ts_env+=(-e "TAILSCALE_AUTH_KEY=${ts_auth_key}")
		if [ -n "${HEADSCALE_SERVER:-}" ]; then
			ts_env+=(-e "TAILSCALE_SERVER=${HEADSCALE_SERVER}")
		elif [ -n "${TENCENT_IP:-}" ]; then
			ts_env+=(-e "TAILSCALE_SERVER=https://${TENCENT_IP}:8443")
		fi
		ts_env+=(-e "TAILSCALE_STATE_ARG=/var/lib/tailscale/tailscaled.state")
	fi

	# headscale CA：挂载自签 CA + SSL_CERT_FILE，保证容器内 tailscaled 首次启动即可信任控制面
	# （Go 的 x509 系统证书池只在进程启动时加载一次，事后 update-ca-certificates 不会生效）
	# 探测顺序: HEADSCALE_CA 环境变量 > scripts/data/headscale-ca.crt > 宿主机 ca-certificates
	local ca_src="${HEADSCALE_CA:-}"
	if [ -z "$ca_src" ] && [ -f "$SCRIPT_DIR/../data/headscale-ca.crt" ]; then
		ca_src="$SCRIPT_DIR/../data/headscale-ca.crt"
	elif [ -z "$ca_src" ] && [ -f /usr/local/share/ca-certificates/headscale-ca.crt ]; then
		ca_src=/usr/local/share/ca-certificates/headscale-ca.crt
	fi
	if [ -n "$ca_src" ] && [ -f "$ca_src" ]; then
		ts_env+=(-v "$ca_src:/usr/local/share/ca-certificates/headscale-ca.crt:ro")
		ts_env+=(-e "SSL_CERT_FILE=/usr/local/share/ca-certificates/headscale-ca.crt")
	fi

	if $is_lite; then
		# Lite: init proxy from workspace mount (scripts/proxy/data/)
		local proxy_data_dir="/workspace/playground/scripts/proxy/data"
		local init_script="$SCRIPT_DIR/../proxy/container-init.sh"
		docker run -t "${docker_opts[@]}" \
			--hostname="D$(hostname)" \
			--name "$name" \
			"${volumes[@]}" \
			"${port_opts[@]}" \
			-e "HOST_IP=$HOST_IP" \
			-e "HOST_PORT=$port" \
			-e "PROXY_DATA_DIR=$proxy_data_dir" \
			"${ts_env[@]}" \
			--env-file "$config_dir/.ssh/vpn.cfg" \
			--restart=unless-stopped --detach \
			--entrypoint bash \
			"$image" -c "$(cat "$init_script")"
	else
		docker run -t "${docker_opts[@]}" \
			--hostname="D$(hostname)" \
			--name "$name" \
			"${volumes[@]}" \
			"${port_opts[@]}" \
			-e "HOST_IP=$HOST_IP" \
			-e "HOST_PORT=$port" \
			"${ts_env[@]}" \
			--env-file "$config_dir/.ssh/vpn.cfg" \
			--restart=unless-stopped --detach \
			"$image"
	fi

	echo "🔧 Setting up home directory and user..."
	sleep 2

	# 将挂载的 headscale CA 合并进系统证书池（供容器内其他工具信任；tailscaled 走 SSL_CERT_FILE 已生效）
	if [ -n "$ca_src" ] && [ -f "$ca_src" ]; then
		docker exec "$name" bash -c "update-ca-certificates >/dev/null 2>&1 || true"
		echo "  ✅ headscale CA 已注入容器"
	fi

	if $is_lite; then
		# Lite: create user first, then copy config to user's home
		docker exec "$name" bash -c "
            getent group $(id -g) >/dev/null 2>&1 || groupadd -g $(id -g) $USER
            id -u $(id -u) >/dev/null 2>&1 || useradd -m -u $(id -u) -g $(id -g) -G sudo -s /bin/bash $USER
            passwd -d $USER >/dev/null 2>&1
            echo '$USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USER
        " 2>&1
		docker exec "$name" mkdir -p "/home/$USER"
		docker cp "$config_dir/." "$name:/home/$USER/"
		docker exec "$name" chmod 700 "/home/$USER/.ssh"
		docker exec "$name" chmod 600 "/home/$USER/.ssh/authorized_keys"
		docker exec "$name" chown -R "$(id -u):$(id -g)" "/home/$USER"
		docker exec "$name" bash -c "
            SOCKET_GID=\$(stat -c '%g' /var/run/docker.sock 2>/dev/null)
            if [ -n \"\$SOCKET_GID\" ] && [ \"\$SOCKET_GID\" != \"0\" ]; then
                getent group \$SOCKET_GID >/dev/null 2>&1 || groupadd -g \$SOCKET_GID docker
                usermod -aG \$SOCKET_GID $USER
            fi
        " 2>&1
	else
		# Full: copy config to \$HOME (image has user set up), then create user
		docker cp "$config_dir/." "$name:$HOME/"
		docker exec "$name" chmod 700 $HOME/.ssh
		docker exec "$name" chmod 600 $HOME/.ssh/authorized_keys
		docker exec "$name" chown -R "$(id -u):$(id -g)" $HOME/
		docker exec "$name" bash -c "
            getent group $(id -g) >/dev/null 2>&1 || groupadd -g $(id -g) $USER
            id -u $(id -u) >/dev/null 2>&1 || useradd -m -u $(id -u) -g $(id -g) -G sudo -s /bin/bash $USER
            passwd -d $USER >/dev/null 2>&1
            echo '$USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USER
            SOCKET_GID=\$(stat -c '%g' /var/run/docker.sock 2>/dev/null)
            if [ -n \"\$SOCKET_GID\" ] && [ \"\$SOCKET_GID\" != \"0\" ]; then
                getent group \$SOCKET_GID >/dev/null 2>&1 || groupadd -g \$SOCKET_GID docker
                usermod -aG \$SOCKET_GID $USER
            fi
        " 2>&1
	fi

	# Lite: change SSH to $port (default 2221) to avoid port 22 conflict with host on --network host
	# 整行锚定 ($) 防止重复执行时 Port 2221 → Port 222121
	if $is_lite; then
		docker exec "$name" bash -c "
			sed -i 's/^Port 22$/Port $port/' /etc/ssh/sshd_config 2>/dev/null
			sed -i 's/^#Port 22$/Port $port/' /etc/ssh/sshd_config 2>/dev/null
			grep -q '^Port $port' /etc/ssh/sshd_config || echo 'Port $port' >> /etc/ssh/sshd_config
		" 2>&1
	fi
	docker exec "$name" service ssh restart >/dev/null 2>&1

	# Lite: 安装 docker CLI 方便容器内操作
	if $is_lite; then
		docker exec "$name" bash -c "
			apt-get update -qq && apt-get install -y -qq --no-install-recommends docker.io >/dev/null 2>&1
		" 2>&1 || true
	fi

	# 设置 tailscale 节点 hostname 为 ts-<host>-<port>（如 ts-211-2224），便于 tailnet 识别
	# tailscaled 可能仍在启动/认证中，重试直到可用（最长 ~60s）
	local ts_hostname="ts-${HOST_IP##*.}-${port}"
	for _ in $(seq 1 30); do
		docker exec "$name" tailscale set --hostname="$ts_hostname" 2>/dev/null && break
		sleep 2
	done

	if $is_lite; then
		echo "✅ $name started (network=host, ssh=127.0.0.1:$port)"
	else
		# 新版 docker 把 bridge IP 放在 NetworkSettings.Networks 下（顶层 IPAddress 已废弃）
		local bridge_ip=$(docker inspect "$name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
		[ -n "$bridge_ip" ] || bridge_ip="?"
		echo "✅ $name started (bridge=$bridge_ip, host=127.0.0.1:$port)"
	fi
}

work-server-exec() {
	local instance="${1:-default}"
	docker exec -ti --user "$UID" --detach-keys "ctrl-^,ctrl-@" "${USER}-work-server-${instance}" /bin/bash
}

work-server-ls() {
	printf "%-12s %-5s %-40s %s\n" "INSTANCE" "PORT" "CONTAINER" "STATUS"
	printf "%-12s %-5s %-40s %s\n" "--------" "----" "---------" "------"
	for inst in "${!INSTANCES[@]}"; do
		local name="${USER}-work-server-${inst}"
		local port="${INSTANCES[$inst]%%:*}"
		local status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "stopped")
		printf "%-12s %-5s %-40s %s\n" "$inst" "$port" "$name" "$status"
	done
}

work-server-rm() {
	local instance="${1:-default}"
	echo "❌ Removing ${USER}-work-server-${instance}..."
	docker container rm -f "${USER}-work-server-${instance}" 2>/dev/null || true
}

work-server-stop() {
	local instance="${1:-default}"
	docker container stop "${USER}-work-server-${instance}" 2>/dev/null || true
}
