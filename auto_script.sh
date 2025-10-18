#!/bin/bash
source ./scripts/utils.sh

set -e  # 如果任何命令失败，则终止脚本

# 1.生成 SSH 密钥对
setup_ssh_keys

# 2.克隆 luluman docker 仓库
if [ ! -d ./docker ] ; then
    clone_with_retry git@github.com:luluman/docker.git
    check_success "Failed to clone the repository 'docker'"
else
    echo "Directory ~/.docker already exists."
fi

# 3.检查并进入 docker/home-work 目录
if [ -d ./docker/home-work ]; then
    pushd ./docker/home-work

    # 克隆 emacs.d 仓库
    if [ ! -d .emacs.d ]; then
        clone_with_retry git@github.com:lulzsec2012/emacs.d.git .emacs.d
        check_success "Failed to clone the repository 'emacs.d'"
    else
        echo "Directory .emacs.d already exists."
    fi

    # 检查 .bashrc 是否存在并编辑
    if [ -f .bashrc ]; then
        sed -i '$ a alias emacs-D="emacs --daemon=lizhi.lu"' .bashrc
        sed -i '$ a alias emacs-C="emacsclient -s lizhi.lu -c"' .bashrc
        sed -i '$ a alias sshhome="ssh lzlu@4544a6914s.wicp.vip -p 21509"' .bashrc
        sed -i "\$ a export PATH=\"\$HOME/.local/bin:\$PATH\"" .bashrc
        sed -i '$ a rm .emacs.d/elpa/symon-20170224.833/symon.elc -f' .bashrc
        sed -i '$ a #-i https://pypi.tuna.tsinghua.edu.cn/simple' .bashrc
    else
        echo "File ~/docker/home-work/.bashrc does not exist."
    fi

    # 配置git用户信息，alias
    config_git

    # 配置pip国内源
    config_pip

    # 新增.profile文件
    add_profile

    # 复制主机.ssh目录
    cp ~/.ssh/* .ssh/

    popd

    # 拷贝授权Keys
    if [ -d ./data ]; then
        if [ -f data/.authinfo ]; then
            cp data/.authinfo docker/home-work/ -f
        fi
        if [ -f data/vpn.cfg ]; then
            cp data/vpn.cfg  docker/home-work/.ssh/ -f
        fi
        if [ -f data/clash_config.yaml ]; then
            mkdir -p docker/opt
            cp data/clash_config.yaml docker/opt/ -f
        fi

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
fi

LINE="source ${PWD}/run.sh"
if ! grep -Fxq "$LINE" ~/.bashrc; then
    echo "$LINE" >> ~/.bashrc
fi

echo "Script executed successfully."

# 在当前环境中执行
# exec bash --rcfile <(cat ~/.bashrc; echo "source ~/.docker/run.sh")
