#!/bin/bash


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

function config_pip_mirror() {
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

function gitconfig() {
  # 检查 .gitconfig 是否存在并编辑
  if [ -f .gitconfig ]; then
    cat <<EOT >> .gitconfig
[alias]
	br = branch
	ci = commit
	co = checkout
	st = status
[user]
	name = lizhi lu
	email = lizhi.lu@houmo.ai
EOT
  else
    echo "File ~/docker/home-work/.gitconfig does not exist."
  fi
}

function delete_containers_with_prefix() {
  local PREFIX=$1

  # 获取具有特定前缀的容器ID列表
  CONTAINERS=$(docker ps -a --filter "name=${PREFIX}" --format "{{.ID}}")

  if [ -z "$CONTAINERS" ]; then
    echo "No containers found with prefix '${PREFIX}'"
  else
    echo "Found containers with prefix '${PREFIX}':"
    echo "$CONTAINERS"

    # 删除找到的容器
    docker rm -f $CONTAINERS
    if [ $? -eq 0 ]; then
      echo "Successfully deleted containers with prefix '${PREFIX}'"
    else
      echo "Failed to delete some containers"
    fi
  fi
}

set -e  # 如果任何命令失败，则终止脚本

# 函数：检查命令是否成功
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# 1.生成 SSH 密钥对
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    echo ~/.ssh/id_ed25519.pub
    exit 1
else
    echo "SSH key already exists."
fi

# 2.克隆 luluman docker 仓库
if [ ! -d ./docker ] && [ ! -d ~/.docker ]; then
    git clone git@github.com:luluman/docker.git
    check_success "Failed to clone the repository 'docker'"
else
    echo "Directory ~/.docker or ./docker already exists."
fi

# 3.检查并进入 docker/home-work 目录
if [ -d ./docker/home-work ]; then
    pushd ./docker/home-work

    # 克隆 emacs.d 仓库
    if [ ! -d .emacs.d ]; then
        git clone git@github.com:lulzsec2012/emacs.d.git --recursive
        check_success "Failed to clone the repository 'emacs.d'"
        mv emacs.d .emacs.d
    else
        echo "Directory .emacs.d already exists."
    fi

    # 检查 .bashrc 是否存在并编辑
    if [ -f .bashrc ]; then
        sed -i '$ a alias emacs-D="emacs --daemon=lizhi.lu"' .bashrc
        sed -i '$ a alias emacs-C="emacsclient -s lizhi.lu -c"' .bashrc
        sed -i '$ a alias sshhome="ssh lzlu@4544a6914s.wicp.vip -p 21509"' .bashrc
        sed -i '$ a export PATH="$HOME/.local/bin:$PATH"' .bashrc
        sed -i '$ a rm .emacs.d/elpa/symon-20170224.833/symon.elc -f' .bashrc
        sed -i '$ a #-i https://pypi.tuna.tsinghua.edu.cn/simple' .bashrc
    else
        echo "File ~/docker/home-work/.bashrc does not exist."
    fi

    # 配置git用户信息，alias
    gitconfig

    # 配置pip国内源
    config_pip_mirror

    # 新增.profile文件
    add_profile

    # 复制主机.ssh目录
    cp ~/.ssh/* .ssh/

    popd

    # 构建新docker镜像，修改启动脚本
    if [ -f ./docker.sh ]; then
      ./docker.sh
    fi

    # 重命名docker目录
    rm ~/.docker -rf && mv ./docker ~/.docker
else
    echo "Directory ~/docker/home-work does not exist."
fi

# 4.修改并重新加载 .bashrc
if [ ! -f ~/.bashrc ]; then
    echo "File ~/.bashrc does not exist. Creating a new one."
    cp ~/.docker/home-work/.bashrc ~/.bashrc

    sed -i '$ a source ~/.docker/run.sh' ~/.bashrc
fi

echo "Script executed successfully."

# 在当前环境中执行
# exec bash --rcfile <(cat ~/.bashrc; echo "source ~/.docker/run.sh")

# 5.检查并删除具有特定前缀的 Docker 容器
# 设置容器名字前缀
delete_containers_with_prefix ${USER}
