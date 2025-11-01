#!/bin/bash

# 重试执行命令
clone_with_retry() {
    local repo_url="$1"
    local target_dir="${2:-$(basename "$repo_url" .git)}"
    local ssh_url="$repo_url"
    local https_url="$repo_url"
    
    # URL转换逻辑
    if [[ "$repo_url" == https://github.com/* ]]; then
        ssh_url="git@github.com:${repo_url#https://github.com/}"
    elif [[ "$repo_url" == git@github.com:* ]]; then
        https_url="https://github.com/${repo_url#git@github.com:}"
    elif [[ "$repo_url" != git@* && "$repo_url" != https://* ]]; then
        ssh_url="git@github.com:${repo_url}"
        https_url="https://github.com/${repo_url}"
    fi
    
    for i in {1..3}; do
        # SSH尝试
        rm -rf "$target_dir" && echo "第 $((2*i-1)) 次(SSH): $ssh_url"
        git clone --recursive "$ssh_url" "$target_dir" && { echo "成功!"; return 0; }
        
        # HTTPS尝试  
        rm -rf "$target_dir" && echo "第 $((2*i)) 次(HTTPS): $https_url"
        git clone --recursive "$https_url" "$target_dir" && { echo "成功!"; return 0; }
        
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
	name = lulizhi
	email = lulizhi@macrobt.com
EOT
}

add_ssh_keys_from_config() {
    local cfg="${1:?错误: 必须指定配置文件路径}"
    local auth_keys="${2:-$HOME/.ssh/authorized_keys}"
    
    [ -f "$cfg" ] || { echo "错误: 配置文件 $cfg 不存在" >&2; return 1; }
    
    mkdir -p "$(dirname "$auth_keys")"
    [ -f "$auth_keys" ] || touch "$auth_keys"
    chmod 600 "$auth_keys"
    
    # 合并文件并去重
    local original_count added_count final_count
    original_count=$(grep -c '^[^#]' "$auth_keys" 2>/dev/null || echo 0)
    
    # 合并并去重，保留注释和空行
    cat "$auth_keys" "$cfg" | awk '!/^#/ && NF >= 2 {print $1 " " $2 " " $3}' | sort | uniq > "${auth_keys}.tmp"
    
    # 计算添加的密钥数量
    final_count=$(grep -c '^[^#]' "${auth_keys}.tmp" 2>/dev/null)
    added_count=$((final_count - original_count))
    
    # 替换原文件
    mv "${auth_keys}.tmp" "$auth_keys"
    
    echo "添加了 $added_count 个新密钥，现有 $final_count 个唯一密钥"
}
