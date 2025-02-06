#!/bin/bash

# 重试执行命令
execute_with_retry() {
    local command="$*" max_attempts=5 attempt=1

    until (( attempt > max_attempts )); do
        echo "第 $attempt 次尝试执行命令: $command"
        eval "$command" && { echo "Success!"; return 0; } || echo "Failure!"
        ((attempt++))
        sleep 2
    done

    return 1
}

# 检查命令执行结果
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# 生成 SSH 密钥对
setup_ssh_keys() {
    if [ ! -f ~/.ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
        echo "SSH key generated at ~/.ssh/id_ed25519.pub"
    else
        echo "SSH key already exists."
    fi
}

function add_profile() {
    if [ ! -f .profile ]; then
        # 写入配置文件
        cat > .profile <<EOL
# ~/.profile: executed by Bourne-compatible login shells.

if [ "$BASH" ]; then
  if [ -f ~/.bashrc ]; then
    . ~/.bashrc
  fi
fi

mesg n 2> /dev/null || true
EOL
    fi
}

function config_pip() {
    mkdir -p ./.pip

    # 写入配置文件
    cat > ./.pip/pip.conf <<EOL
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/

[install]
trusted-host = mirrors.aliyun.com
EOL
    echo "Pip配置已更新为阿里云镜像源。"
}

function config_git() {
    cat > .gitconfig <<EOT
[http]
	# proxy = socks5h://127.0.0.1:7891
[https]
	# proxy = socks5h://127.0.0.1:7891
[alias]
	br = branch
	ci = commit
	co = checkout
	st = status
[user]
	name = lizhi lu
	email = lizhi.lu@houmo.ai
EOT
}

function delete_containers_with_prefix() {
    local PREFIX=$1

    # 获取具有特定前缀的容器ID列表
    container_name=$(docker ps -a --filter "name=${PREFIX}" --format "{{.ID}}")

    if [ -z "$container_name" ]; then
        echo "No containers found with prefix '${PREFIX}'"
    else
        echo "Found containers with prefix '${PREFIX}':"
        echo "$container_name"

        # 删除找到的容器
        docker stop "$container_name" >/dev/null || { echo "Failed to stop container"; exit 1; }
        docker rm -f "$container_name" >/dev/null || { echo "Failed to remove container"; exit 1; }
    fi
}
