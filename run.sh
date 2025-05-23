#!/bin/bash

function work-linux-server() {
    if [[ $# -gt 0 && "$1" == "-f" ]]; then
        _remove_container "${USER}-work-server"
    fi
    local home; home="${HOME}/.docker_hmcc/home-work"
    local workspace; workspace="${HOME}/workspace"
    local share; share="${HOME}/share"
    local opt; opt="$HOME/.docker_hmcc/opt"
    local etc; etc="$HOME/.docker_hmcc/etc"
    local data; data=$(realpath /develop01)

    mkdir -p "$etc"
    getent passwd > "$etc/passwd"
    getent group > "$etc/group"
    getent shadow > "$etc/shadow"

    docker run -it \
           --privileged \
           --log-driver=none \
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
           --volume=/var/run/docker.sock:/var/run/docker.sock \
           --env-file "${home}/.ssh/vpn.cfg" \
           --detach \
           mattlu/work-dev:latest

    if [ -f custom_commands_drv.sh ]; then
        echo "executing custom commands"
        bash custom_commands_drv.sh
    fi
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

function _remove_container() {
    docker container rm -f "$1"
}

function tvm-linux-server() {
    if [[ $# -gt 0 && "$1" == "-f" ]]; then
        _remove_container "${USER}-tvm-server"
    fi
    local home; home=$(realpath ~/.docker_tvm/home-work)
    local workspace; workspace=$(realpath ~/workspace)
    local share; share=$(realpath ~/share)
    local tmp; tmp=$(realpath ~/.docker_tvm/tmp)
    local data; data=$(realpath /develop01)

    docker run -t \
           --privileged \
           --log-driver=none \
           --hostname="T$(hostname)" \
           --name "${USER}-tvm-server" \
           --detach-keys "ctrl-^,ctrl-@" \
           --volume="${home}:${HOME}":delegated \
           --volume="${workspace}:/workspace":cached \
           --volume="${tmp}:/tmp":cached \
           --volume="${data}:${data}":cached \
           --volume="${share}:/share:ro" \
           --volume="/etc/group:/etc/group:ro" \
           --volume="/etc/passwd:/etc/passwd:ro" \
           --volume="/etc/shadow:/etc/shadow:ro" \
           --volume=/var/run/docker.sock:/var/run/docker.sock \
           --env-file "${home}/.ssh/vpn.cfg" \
           --detach \
           -p 2222:22 \
           lizhi.lu/tvm-dev:latest
}

function tvm-linux-server-exec() {
    docker exec -ti --user ${UID} \
           --detach-keys "ctrl-^,ctrl-@" \
           "${USER}-tvm-server" /bin/bash
}
