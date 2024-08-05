#!/bin/bash

IMAGE_NAME="lizhi.lu/tvm-dev:latest"
CONTAINER_NAME="$(whoami).tvm"
RUN_IN_DOCKER() { docker exec -it $CONTAINER_NAME bash -c "$@"; }


# 定义 tvm-linux-server 函数来启动 Docker 容器
function tvm-linux-server() {
  # 设定必要的目录路径
  local home=$(realpath ~/.docker_tvm/home-work)
  local workspace=$(realpath ~/workspace)
  local tmp=$(realpath ~/.docker_tvm/tmp)
  local data=$(realpath /develop01)

  docker run \
      --privileged \
      --log-driver=none \
      --hostname=D$(hostname) \
      --detach-keys "ctrl-^,ctrl-@" \
      --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
      --volume="${home}:/home/${USER}":delegated \
      --volume="${workspace}:/workspace":cached \
      --volume="${tmp}:/tmp":cached \
      --volume="${data}:${data}":cached \
      --env-file ${home}/.ssh/vpn.cfg \
      -w /workspace -p 2222:22 \
      --name $CONTAINER_NAME -itd -u $(id -u):$(id -g) $IMAGE_NAME >/dev/null
}

# 处理脚本参数
if [ $# -gt 0 ]; then
    if [ "$1" == "restart" ]; then
        echo "Restarting container"
        docker stop $CONTAINER_NAME >/dev/null || { echo "Failed to stop container"; exit 1; }
        docker rm $CONTAINER_NAME >/dev/null || { echo "Failed to remove container"; exit 1; }
    else
        echo "Unknown argument"; exit 1
    fi
else
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Container exists"
        echo -e "\e[32mEnter the container using:\e[0m"
        echo "-> docker exec -it ${CONTAINER_NAME} bash"
        exit 0
    else
        echo "Preparing container named \"$CONTAINER_NAME\" with image $IMAGE_NAME"
        echo "Creating a new container"
    fi
fi

# 启动容器
echo "Starting the container..."
#docker pull $IMAGE_NAME >/dev/null || { echo "Failed to pull image"; exit 1; }
tvm-linux-server || { echo "Failed to start container"; exit 1; }

CONTAINER_STATUS=$(docker ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Status}}")
echo "CONTAINER_STATUS:,${CONTAINER_STATUS}"
# 为当前用户添加sudo权限
docker exec -u 0:0 -it $CONTAINER_NAME bash -c "groupadd -g $(id -g) $(whoami) && useradd -m -u $(id -u) -g $(whoami) $(whoami) && usermod -a -G sudo $(whoami) && echo \"$(whoami)   ALL=(ALL) NOPASSWD: ALL\" >> /etc/sudoers"

# 复制SSH密钥并设置git用户信息
docker cp ~/.ssh $CONTAINER_NAME:/home/$(whoami)/ &&\
RUN_IN_DOCKER "chmod 400 /home/$(whoami)/.ssh/*" &&\
RUN_IN_DOCKER "chmod 600 /home/$(whoami)/.ssh/known_hosts" &&\
RUN_IN_DOCKER "git config --global user.name $(whoami)" &&\
RUN_IN_DOCKER "git config --global user.email $(whoami)@houmo.ai" &&\
RUN_IN_DOCKER "git config --global alias.br branch" &&\
RUN_IN_DOCKER "git config --global alias.st status" &&\
RUN_IN_DOCKER "git config --global alias.ci commit" &&\
RUN_IN_DOCKER "git config --global alias.co checkout" &&\
RUN_IN_DOCKER "pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple"

echo -e "\e[31mUser name and email in git set to $(whoami) (@houmo.ai)\e[0m"

# 配置gdb和lldb的pretty-printer
RUN_IN_DOCKER "mkdir -p /home/$(whoami)/.config/gdb/"
RUN_IN_DOCKER "echo -e \"set auto-load local-gdbinit on\nadd-auto-load-safe-path /\" >> /home/$(whoami)/.config/gdb/gdbinit"
RUN_IN_DOCKER "echo \"settings set target.load-cwd-lldbinit true\" >> /home/$(whoami)/.lldbinit"

# 执行自定义命令
if [ -f custom_commands.sh ]; then
    echo "Executing custom commands"
    source custom_commands.sh || { echo "Failed to execute custom commands"; exit 1; }
fi

# 创建别名和命令
RUN_IN_DOCKER "echo 'alias push-dev=\"git push origin HEAD:refs/for/develop\"' >> /home/$(whoami)/.bashrc"
RUN_IN_DOCKER "echo 'alias rebase-dev=\"git checkout develop && git pull && git checkout - && git rebase develop\"' >> /home/$(whoami)/.bashrc"
RUN_IN_DOCKER "echo 'ln-builds() { current_dir=\$(basename \"\$PWD\"); if [ -z \$1 ]; then builds_parent_dir=\"${VOLUME_WORKSPACE}/\${current_dir}/builds\"; else builds_parent_dir=\"${VOLUME_WORKSPACE}/\${1}/builds\"; fi; mkdir -p \$builds_parent_dir; if [ -L \"builds\" ]; then rm -f builds ; fi; ln -sf \$builds_parent_dir builds; }' >> ~/.bashrc"
RUN_IN_DOCKER "echo 'env-clang() { eval \`python3 build.py --env --onnx-dir=${VOLUME_WORKSPACE}/onnx_dir \$@ \`; }' >> ~/.bashrc"
RUN_IN_DOCKER "echo 'env-gcc-pre() { eval \`python3 build.py --cc gcc --env --onnx-dir=${VOLUME_WORKSPACE}/onnx_dir --pre-built-llvm=${VOLUME_COMMON}/toolchain/component/illvm_external/ubuntu_20.04 \$@ \`; }' >> ~/.bashrc"

# 显示进入容器的命令
echo -e "\e[32mEnter the container using:\e[0m"
echo "-> docker exec -it ${CONTAINER_NAME} bash"

# 定义 tvm-linux-server-exec 函数
function tvm-linux-server-exec() {
    docker exec -ti --user ${UID} \
        --detach-keys "ctrl-^,ctrl-@" \
        ${CONTAINER_NAME} /bin/bash
}
