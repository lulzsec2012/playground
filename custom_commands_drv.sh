#! /bin/bash

# 0. 必要变量
# IMAGE_NAME="harbor.houmo.ai/toolchain/hmcc:v0.1.9-ubuntu20.04-py38-x86.64"
IMAGE_NAME="mattlu/work-dev:latest"
CONTAINER_NAME="$(whoami)-work-server"
RUN_IN_DOCKER() {  docker exec -it $CONTAINER_NAME bash -c "$@"; }

VOLUME_BUILDS="${HOME}/builds" # 这个路径放编译结果
VOLUME_COMMON="/develop01" # 公共文件路径，有isim, hdpl等，必须挂载

# 4. 拷贝驱动文件
LATEST_DRV=$(find /usr/local -type d -name 'houmo_drv*' -print0 | xargs -0 ls -td | head -n 1)
if [[ "$LATEST_DRV" != *houmo_drv* ]]; then
   echo -e "\e[31mcannot find driver in /usr/local\e[0m"
else
   echo -e "\e[31musing latest driver ${LATEST_DRV}\e[0m"
   docker cp $LATEST_DRV $CONTAINER_NAME:/usr/local/houmo-sdk
   docker exec -u 0:0 -it $CONTAINER_NAME bash -c "apt-get update && apt-get install bc"
   docker exec -u 0:0 -it $CONTAINER_NAME bash -c "ln -s /usr/local/houmo-sdk/tools/* /usr/local/bin"
fi


# 7. [非必要]config pretty-printer of gdb and lldb
RUN_IN_DOCKER "mkdir -p ~/.config/gdb/"
RUN_IN_DOCKER "echo -e \"set auto-load local-gdbinit on\nadd-auto-load-safe-path /\" >> ~/.config/gdb/gdbinit"
RUN_IN_DOCKER "echo \"settings set target.load-cwd-lldbinit true\" >> ~/.lldbinit"

# # 9. [非必要]在bashrc里写一些方便的命令，用不上可忽略
# #    如果代码在NFS上，需要用ln-builds创建软链接，避免直接在代码路径上生成编译文件
# RUN_IN_DOCKER "echo 'alias push-dev=\"git push origin HEAD:refs/for/develop\"' >> ~/.bashrc"
# RUN_IN_DOCKER "echo 'alias rebase-dev=\"git checkout develop && git pull && git checkout - && git rebase develop\"' >> ~/.bashrc"
# RUN_IN_DOCKER "echo 'ln-builds() {   current_dir=\$(basename \"\$PWD\");   if [ -z \$1 ]; then builds_parent_dir=\"${VOLUME_BUILDS}/\${current_dir}/builds\"; else builds_parent_dir=\"${VOLUME_BUILDS}/\${1}/builds\"; fi; mkdir -p \$builds_parent_dir; if [ -L \"builds\" ]; then rm -f builds ; fi; ln -sf \$builds_parent_dir builds; }' >> ~/.bashrc"
# RUN_IN_DOCKER "echo 'env-hmcc() {    eval \`python3 build.py --env -b debugo3 --onnx-dir=${VOLUME_BUILDS}/onnx_dir \$@ \`; }' >> ~/.bashrc"
# RUN_IN_DOCKER "echo 'env-hmcc-pre() { eval \`python3 build.py --env --onnx-dir=${VOLUME_BUILDS}/onnx_dir --pre-built-llvm=${VOLUME_COMMON}/toolchain/component_develop/illvm_external/ubuntu_20.04 \$@ \`; }' >> ~/.bashrc"
