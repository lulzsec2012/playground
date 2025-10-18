#!/bin/bash

function work-linux-server() {
    if [[ $# -gt 0 && "$1" == "-f" ]]; then
        docker container rm -f "${USER}-work-server"
    fi
    local base="$HOME/.docker"
    local home; home="${base}/home-work"
    local workspace; workspace="${HOME}/workspace"
    local share; share="${HOME}/share"
    local opt; opt="${base}/opt"
    local etc; etc="${base}/etc"
    local data; data=$(realpath /develop01)

    mkdir -p "$etc"
    getent passwd > "$etc/passwd"
    getent group > "$etc/group"
    getent shadow > "$etc/shadow"

    docker run -it \
           --privileged \
           --log-driver=none \
           --group-add=$(getent group docker | cut -d: -f3) \
           --hostname="D$(hostname)" \
           --name "${USER}-work-server" \
           --detach-keys "ctrl-^,ctrl-@" \
           --volume="${home}:${HOME}":delegated \
           --volume="${workspace}:/workspace":cached \
           --volume="${opt}:/opt":cached \
           --volume="${data}:${data}":cached \
           --volume="${share}:/share:ro" \
           --volume="$etc/group:/etc/group:ro" \
           --volume="$etc/passwd:/etc/passwd:ro" \
           --volume="$etc/shadow:/etc/shadow:ro" \
           --volume="$(realpath "$base/clash_config"):/clash_config:cached" \
           --volume=/var/run/docker.sock:/var/run/docker.sock \
           --env-file "${home}/.ssh/vpn.cfg" \
           --detach \
           -p 2222:22 \
           --restart unless-stopped \
           lizhi.lu/work-dev:latest

    # if [ -f custom_commands_drv.sh ]; then
    #     echo "executing custom commands"
    #     bash custom_commands_drv.sh
    # fi
}

function work-linux-server-exec() {
    #docker cp ~/.ssh "${USER}-work-server":/home/$(whoami)/ && \
    docker exec -ti --user ${UID} \
           --detach-keys "ctrl-^,ctrl-@" \
           "${USER}-work-server" /bin/bash
}

function add-network() {
    docker network create --driver bridge lizhi.lu-net
}


function work-linux-cuda-server() {
    # Assumes a ".docker" (this project) and a "workspace" folder exist in $HOME.
    # cd ~/
    # ln -s your/original/.docker/path .docker
    # ln -s your/original/workspace/path workspace

    if [[ $# -gt 0 && "$1" == "-f" ]]; then
        docker container rm -f "${USER}-work-cuda-server"
    fi

    local base="$HOME/.docker"
    declare -a volumes=(
        --volume="$(realpath "$HOME/workspace"):/workspace:cached"
        --volume="$(realpath "$base/home-work"):/home/$(whoami):delegated"
        --volume="$(realpath "$base/tmp"):/tmp:cached"
        --volume="$(realpath "$base/clash_config"):/clash_config:cached"
        --volume="/var/run/docker.sock:/var/run/docker.sock"
    )

    # List your shared dirs here (expand as needed)
    declare -a shared_dirs=(
        "/share_data"
        "/software_data"
        "/data"
        "/zjshare_data"
        "/softhome"
        "/share"
        "/data_gpu"
    )
    for dir in "${shared_dirs[@]}"; do
        if [ -d "$dir" ]; then
            volumes+=(--volume="$(realpath "$dir"):$dir")
        fi
    done

    mkdir -p "$base/etc"
    # Use awk to find the current user's line and replace the home directory (field 6).
    getent passwd | awk -F: '$3 < 1000 {print}' >"$base/etc/passwd" # system accounts
    getent passwd "$(whoami)" | awk -F: 'BEGIN{OFS=FS}{$6="/home/"$1}1' >>"$base/etc/passwd"
    getent group >"$base/etc/group"
    getent group "$(id -g -n)" >>"$base/etc/group"

    volumes+=(--volume="$base/etc/passwd:/etc/passwd:ro" --volume="$base/etc/group:/etc/group:ro")

    docker run -t \
        --privileged \
        --gpus all \
        --log-driver=none \
        --hostname="D$(hostname)" \
        --group-add=$(getent group docker | cut -d: -f3) \
        --name "${USER}-work-cuda-server" \
        --detach-keys "ctrl-^,ctrl-@" \
        "${volumes[@]}" \
        --env-file "$base/home-work/.ssh/vpn.cfg" \
        --restart=always --detach \
        mattlu/work-cuda-dev:cuda13.0-ubuntu22.04

}

function work-linux-cuda-server-exec() {
    #docker cp ~/.ssh "${USER}-work-server":/home/$(whoami)/ && \
    docker exec -ti --user ${UID} \
           --detach-keys "ctrl-^,ctrl-@" \
           "${USER}-work-cuda-server" /bin/bash
}
