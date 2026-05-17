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

if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
: "${HOST_PORT:=}"

# Dockerfiles: https://github.com/lulzsec2012/docker.git
declare -A INSTANCES=(
    [default]="2222:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
    [test-v1]="2223:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
    [test-v2]="2224:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
    [dev]="2225:lulzsec2012/work-cuda-dev:cuda13.0-ubuntu24.04"
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
        read -r port image <<< "${INSTANCES[$inst]}"
        printf "  %-12s port=%-4s %s\n" "$inst" "$port" "$image"
    done
}

work-server() {
    local instance="${1:-default}"
    local force=false
    [[ "$2" == "-f" ]] && force=true

    local IFS=":"
    read -r port image <<< "${INSTANCES[$instance]}"
    if [[ -z "$port" ]]; then
        echo "❌ Unknown instance: $instance"
        echo "Available: ${!INSTANCES[*]}"
        return 1
    fi

    local name="${USER}-work-server-${instance}"
    local config_dir
    config_dir=$(TMPDIR=/dev/shm mktemp -d -t "docker-instance-${instance}-XXXXXX")
    # shellcheck disable=SC2064  # intentional: expand $config_dir now (local var out of scope on RETURN)
    trap "rm -rf '${config_dir}'" RETURN

    echo "📝 Generating config for '$instance'..."
    bash "$SCRIPT_DIR/generate-home-config.sh" "$config_dir"

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

    declare -a shared_dirs=(
        "/share_data" "/software_data" "/data"
        "/zjshare_data" "/softhome" "/share" "/data_gpu"
    )
    for dir in "${shared_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            volumes+=(--volume="$dir:$dir")
        fi
    done

    declare -a gpu_opts=()
    if docker info 2>/dev/null | grep -qi "Runtimes.*nvidia"; then
        gpu_opts=(--gpus all)
    fi

    docker run -t --privileged "${gpu_opts[@]}" \
        --log-driver=none \
        --hostname="D$(hostname)" \
        --name "$name" \
        "${volumes[@]}" \
        -p "$port:22" \
        -e "HOST_IP=$HOST_IP" \
        -e "HOST_PORT=$port" \
        --env-file "$config_dir/.ssh/vpn.cfg" \
        --restart=unless-stopped --detach \
        "$image"

    echo "🔧 Setting up home directory and user..."
    sleep 2
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
    docker exec "$name" service ssh restart >/dev/null 2>&1

    local bridge_ip=$(docker inspect "$name" --format "{{.NetworkSettings.IPAddress}}")
    echo "✅ $name started (bridge=$bridge_ip, host=127.0.0.1:$port)"
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
