#!/bin/bash

function work-linux-server() {
    # Assumes a ".docker" (this project) and a "workspace" folder exist in $HOME.
    # cd ~/
    # ln -s your/original/.docker/path .docker
    # ln -s your/original/workspace/path workspace
    local home; home=$(realpath ~/.docker_hmcc/home-work)
    local workspace; workspace=$(realpath ~/workspace)
    local share; share=$(realpath ~/share)
    local tmp; tmp=$(realpath ~/.docker_hmcc/tmp)
    local opt; opt=$(realpath ~/.docker_hmcc/opt)
    local data; data=$(realpath /develop01)

    docker run -t \
           --privileged \
           --log-driver=none \
           --hostname="D$(hostname)" \
           --name "${USER}-work-server" \
           --detach-keys "ctrl-^,ctrl-@" \
           --volume="${home}:${HOME}":delegated \
           --volume="${workspace}:/workspace":cached \
           --volume="${tmp}:/tmp":cached \
           --volume="${opt}:/opt":cached \
           --volume="${data}:${data}":cached \
           --volume="${share}:/share:ro" \
           --volume="/etc/group:/etc/group:ro" \
           --volume="/etc/passwd:/etc/passwd:ro" \
           --volume="/etc/shadow:/etc/shadow:ro" \
           --volume=/var/run/docker.sock:/var/run/docker.sock \
           --env-file "${home}/.ssh/vpn.cfg" \
           --detach \
           lizhi.lu/work-dev:latest

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

function tvm-linux-server() {
    # Assumes a ".docker" (this project) and a "workspace" folder exist in $HOME.
    # cd ~/
    # ln -s your/original/.docker/path .docker
    # ln -s your/original/workspace/path workspace
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
