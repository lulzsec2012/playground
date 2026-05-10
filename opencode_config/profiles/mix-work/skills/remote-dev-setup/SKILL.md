---
name: remote-dev-setup
description: Set up a Docker-based development environment on a remote server. Triggers when a prompt contains a user@host pattern AND dev/setup intent, e.g. "在 user@ip 服务器上配置开发环境", "给 user@ip 配置开发环境", "setup dev environment on user@host", "configure remote dev on user@host", "provision dev server for user@host". Do NOT trigger for general Docker questions, SSH key management, or playground development questions.
---

# Remote Dev Environment Setup

Setup a Docker-based development container on a remote server.

## Anti-Stuck Rules (Critical for Opencode)

Every command in this skill MUST follow these rules to avoid "stuck" behavior:

1. **SSH timeout**: always add `-o ConnectTimeout=10`
2. **Docker timeout**: wrap with `timeout 120` for run/pull
3. **Flush output**: pipe through `2>&1 | cat` to prevent buffering
4. **No chained background cmds**: separate SSH calls for container start vs verify
5. **Done marker**: append `&& echo "DONE"` on critical commands

## Two port concepts:
- `SSH_PORT` — the SSH port to reach the server itself (default 22)
- `DEV_PORT` — the port the dev container's SSH will listen on (default 2222)

## Workflow

### Step 1: Parse user@host

Extract `user`, `host`, `SSH_PORT`, `DEV_PORT` from the user's message.

**Crucial: always use explicit `-p $SSH_PORT` in every SSH command.** The local machine's `~/.ssh/config` may have a `Host` entry that overrides the port (e.g., mapping `10.10.18.210` to port 2222). Without explicit `-p`, the SSH config would route to the wrong destination. `-p 22` overrides any SSH config port mapping and ensures we connect to the actual server.

**Patterns:**
- `user@host` → SSH_PORT=22, DEV_PORT=2222
- `user@host:2223` → SSH_PORT=2223, DEV_PORT=2222 (user@host:SSH_PORT)
- `user@host:2223/3333` → SSH_PORT=2223, DEV_PORT=3333 (user@host:SSH_PORT/DEV_PORT)
- `user@host//3333` → SSH_PORT=22, DEV_PORT=3333

Examples:
- "在 root@192.168.1.100 服务器上配置开发环境" → root@192.168.1.100:22, DEV_PORT=2222
- "给 lulizhi@10.10.18.210 配置开发环境" → lulizhi@10.10.18.210:22, DEV_PORT=2222
- "给 lulizhi@10.10.18.210:2223 配置开发环境" → lulizhi@10.10.18.210:2223, DEV_PORT=2222
- "在 root@10.0.0.5//3333 上配置" → root@10.0.0.5:22, DEV_PORT=3333
- "setup dev on user@host:2222/2223" → user@host:2222, DEV_PORT=2223

```bash
# Parsing logic (pseudocode)
# user@host[:SSH_PORT][//DEV_PORT]
USER="user_part"
HOST="host_part"
SSH_PORT="${ssh_port:-22}"
DEV_PORT="${dev_port:-2222}"
```

If the prompt doesn't contain a valid user@host, ask the user to provide it.

### Step 2: SSH Key Setup

⚠️ **Always use explicit `-p $SSH_PORT` in every SSH command.** The local `~/.ssh/config` may have a `Host` entry that overrides the port. Without explicit `-p`, SSH config can route to the wrong destination (e.g., a container instead of the host).

Check if passwordless SSH already works:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $SSH_PORT $USER@$HOST "echo OK"
```

If it returns "OK", skip to Step 3.

If it fails, run `ssh-copy-id`:

```bash
ssh-copy-id -o StrictHostKeyChecking=no -p $SSH_PORT $USER@$HOST
```

⚠️ This will prompt for a password. Inform the user they need to enter the password. The bash tool will timeout on interactive prompts, so you may need to ask the user to run this command manually and come back.

After SSH is set up, verify:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 -p $SSH_PORT $USER@$HOST "echo SSH_OK"
```

### Step 3: Check Remote Environment

```bash
ssh -p $SSH_PORT $USER@$HOST "bash -s" << 'REMOTE_CHECKS'
echo "=== OS ==="
cat /etc/os-release 2>/dev/null | head -3
echo "=== Docker ==="
docker --version 2>&1 || echo "DOCKER_NOT_FOUND"
echo "=== NVIDIA ==="
nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 || echo "NVIDIA_NOT_FOUND"
echo "=== Arch ==="
uname -m
echo "=== Disk ==="
df -h / 2>&1 | tail -1
REMOTE_CHECKS
```

**If Docker is missing** — check sudo access:

```bash
ssh -p $SSH_PORT -t $USER@$HOST "echo 'checking sudo' && sudo -n echo 'sudo OK'" 2>&1 | grep "sudo OK"
```

If sudo works without password, install Docker:

```bash
ssh -p $SSH_PORT $USER@$HOST "curl -fsSL https://get.docker.com | sudo sh" 2>&1
```

If sudo requires password, ask the user to install Docker manually.

**If NVIDIA GPU detected but nvidia-container-toolkit missing**:

```bash
ssh -p $SSH_PORT $USER@$HOST "sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit && sudo systemctl restart docker" 2>&1
```

### Step 4: Resolve DEV_PORT Conflicts

Before deploying the playground, check if `$DEV_PORT` is already in use on the remote server:

```bash
# Check what process/container is using DEV_PORT
ssh -p $SSH_PORT $USER@$HOST "docker ps --filter publish=$DEV_PORT --format '{{.Names}} {{.Ports}}'" 2>&1 | grep -v "^$"
```

**If a container is found using `$DEV_PORT`:**

⚠️ This container may be an active workspace. Show the user what container is using the port and ask for confirmation before stopping it:

```bash
CONFLICTING_CONTAINER=$(ssh -p $SSH_PORT $USER@$HOST "docker ps --filter publish=$DEV_PORT --format '{{.Names}}' | head -1")
echo "⚠️ Port $DEV_PORT is in use by container: $CONFLICTING_CONTAINER"
```

Ask the user:
- "Port $DEV_PORT is used by $CONFLICTING_CONTAINER. Stop it and replace with a new one?"
- If yes, stop and remove it:
  ```bash
  ssh -p $SSH_PORT $USER@$HOST "docker container rm -f $CONFLICTING_CONTAINER"
  # Clean up orphaned instance config
  INSTANCE_NAME=$(echo "$CONFLICTING_CONTAINER" | sed 's/.*-work-server-//')
  [ -n "$INSTANCE_NAME" ] && ssh -p $SSH_PORT $USER@$HOST "rm -rf /tmp/.docker-instances/$INSTANCE_NAME 2>/dev/null; true"
  echo "✅ Port $DEV_PORT freed"
  ```
- If no, ask the user to choose a different DEV_PORT and restart from Step 1.

If the port is used by a non-Docker process (e.g., another SSH server), report it and ask the user to choose a different DEV_PORT.

### Step 5: Deploy Playground

Playground is deployed to `~/workspace/playground` on the remote server. The `data/` directory inside it contains per-server configuration files (SSH keys, VPN config) and is required for container startup.

**Step 5a: Check remote first**

```bash
ssh -p $SSH_PORT $USER@$HOST "ls ~/workspace/playground/run.sh" 2>&1
```

If it returns the file path, the playground already exists on the remote. Skip to Step 5d (verify data/).

**Step 5b: Deploy from local (preferred)**

If remote doesn't have playground, check the local machine (Mac):

```bash
ls ~/workspace/playground/run.sh 2>/dev/null && echo "LOCAL_EXISTS"
```

If local exists, tar and scp the ENTIRE playground (including `data/`) to the remote server:

```bash
tar czf /tmp/playground-deploy.tar.gz --no-xattrs \
  -C ~/workspace/playground --exclude=.git --exclude=docker .
scp -P $SSH_PORT /tmp/playground-deploy.tar.gz $USER@$HOST:/tmp/
ssh -p $SSH_PORT $USER@$HOST "mkdir -p ~/workspace && tar xzf /tmp/playground-deploy.tar.gz -C ~/workspace/playground && rm /tmp/playground-deploy.tar.gz"
rm /tmp/playground-deploy.tar.gz
```

**Step 5c: Fallback — clone from GitHub**

If local playground doesn't exist, try cloning on the remote:

```bash
ssh -p $SSH_PORT $USER@$HOST "mkdir -p ~/workspace && git clone https://github.com/lulzsec2012/playground.git ~/workspace/playground"
```

If that fails (GFW), clone locally then scp:

```bash
cd /tmp
git clone https://github.com/lulzsec2012/playground.git playground-fallback 2>&1 || \
  git clone git@github.com:lulzsec2012/playground.git playground-fallback
tar czf playground-deploy.tar.gz --no-xattrs \
  -C playground-fallback --exclude=.git --exclude=docker .
scp -P $SSH_PORT playground-deploy.tar.gz $USER@$HOST:/tmp/
ssh -p $SSH_PORT $USER@$HOST "mkdir -p ~/workspace && tar xzf /tmp/playground-deploy.tar.gz -C ~/workspace/playground && rm /tmp/playground-deploy.tar.gz"
rm -rf /tmp/playground-fallback /tmp/playground-deploy.tar.gz
```

**Step 5d: Verify data/ directory**

The `data/` directory is essential. It must contain at least `vpn.cfg` and `ssh_keys.cfg` for the container to start correctly:

```bash
DATA_FILES=$(ssh -p $SSH_PORT $USER@$HOST "ls ~/workspace/playground/data/vpn.cfg ~/workspace/playground/data/ssh_keys.cfg 2>&1")
echo "$DATA_FILES"
```

Expected output (both files exist):
```
/home/$USER/workspace/playground/data/vpn.cfg
/home/$USER/workspace/playground/data/ssh_keys.cfg
```

**If any required files are missing**, report the error and STOP. The container cannot start without these files because:
- `vpn.cfg` — provides environment variables (clash subscription, tailscale auth key)
- `ssh_keys.cfg` — provides SSH authorized_keys for container access

The user must create these files in `data/` before continuing.

Also verify that the playground structure is complete:

```bash
ssh -p $SSH_PORT $USER@$HOST "ls ~/workspace/playground/run.sh ~/workspace/playground/auto_script.sh ~/workspace/playground/home-config/bashrc/10-prompt.sh"
```

### Step 6: Configure and Start Container

First, determine the host's LAN IP for the container's prompt display:

```bash
SERVER_IP=$(ssh -p $SSH_PORT $USER@$HOST "hostname -I 2>/dev/null | awk '{print \$1}'")
```

Set `HOST_IP` for the container's prompt. This also needs to persist across SSH sessions:

```bash
ssh -p $SSH_PORT $USER@$HOST "echo \"export HOST_IP=$SERVER_IP\" >> ~/.bashrc"
```

Create the `run.sh` instance entry for the custom port. On the remote server, update the `INSTANCES` dict in `run.sh` to use `$DEV_PORT`:

```bash
ssh -p $SSH_PORT $USER@$HOST "cd ~/workspace/playground && sed -i \"s|default.*=.*\"[0-9]*:.*\"|default=\\\"$DEV_PORT:lulzsec2012/work-cuda-dev:cuda12.4-ubuntu22.04\\\"|\" run.sh"
```

Set up and start the container:

```bash
ssh -p $SSH_PORT $USER@$HOST "cd ~/workspace/playground && source run.sh && work-server default" 2>&1
```

Wait for the container to initialize (10-30 seconds for first pull and key generation):

```bash
sleep 10
ssh -p $SSH_PORT $USER@$HOST "docker ps --filter name=work-server --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'"
```

Expected output:
```
NAME                         PORTS                                       STATUS
$USER-work-server-default    0.0.0.0:$DEV_PORT->22/tcp                   Up X seconds
```

### Step 7: Verify SSH Access

Test SSH to the container via `DEV_PORT`:

```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $DEV_PORT $USER@$HOST "whoami; hostname; nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | head -2"
```

Expected: `whoami` = `$USER` (same as host user), CUDA GPUs detected.

**Troubleshooting: Permission denied on first SSH**

If SSH fails with "Permission denied (publickey)", manually add the host user's key:

```bash
HOST_KEY=$(ssh -p $SSH_PORT $USER@$HOST "cat ~/.ssh/id_ed25519.pub || cat ~/.ssh/id_rsa.pub")
if [ -n "$HOST_KEY" ]; then
    CONTAINER_NAME=$(ssh -p $SSH_PORT $USER@$HOST "docker ps --filter name=work-server --format '{{.Names}}' | head -1")
    ssh -p $SSH_PORT $USER@$HOST "docker exec -i \$CONTAINER_NAME bash -c 'echo \"$HOST_KEY\" >> /home/\$(whoami)/.ssh/authorized_keys'"
fi
```

Then retry the SSH test.

### Step 8: Add Local Aliases

Add convenient SSH aliases to `~/.zshrc`.

**Check if an alias for this target already exists:**

```bash
# Check if any existing alias already points to the same target
TARGET="ssh -p $DEV_PORT $USER@$HOST"
EXISTING_ALIAS=$(grep -E "^alias ssh-.*='$TARGET'" ~/.zshrc 2>/dev/null | head -1)
if [ -n "$EXISTING_ALIAS" ]; then
    ALIAS_NAME=$(echo "$EXISTING_ALIAS" | sed "s/^alias ssh-//" | sed "s/=.*//")
    echo "✅ Alias ssh-${ALIAS_NAME} already points to this target, no change needed"
    # Skip alias generation, but continue to Tailscale alias
    SSH_NAME="$ALIAS_NAME"
else
    # Generate new alias name
    generate_alias_name
fi
```

If no existing alias matches, generate a new name from IP segments:

```bash
generate_alias_name() {
    if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IP="$HOST"
    else
        IP=$(ssh -p $SSH_PORT $USER@$HOST "hostname -I 2>/dev/null | awk '{print \$1}'" || echo "$HOST")
    fi

    OCTET4=$(echo "$IP" | cut -d. -f4)
    OCTET3=$(echo "$IP" | cut -d. -f3)
    OCTET2=$(echo "$IP" | cut -d. -f2)
    OCTET1=$(echo "$IP" | cut -d. -f1)

    EXISTING=$(grep "^alias ssh-" ~/.zshrc 2>/dev/null)

    SSH_NAME=""
    for suf in "$OCTET4" "${OCTET3}-${OCTET4}" "${OCTET2}-${OCTET3}-${OCTET4}" "${OCTET1}-${OCTET2}-${OCTET3}-${OCTET4}"; do
        if ! echo "$EXISTING" | grep -q "alias ssh-${suf}="; then
            SSH_NAME="$suf"
            break
        fi
    done
    if [ -z "$SSH_NAME" ]; then
        SSH_NAME="${OCTET1}-${OCTET2}-${OCTET3}-${OCTET4}"
    fi

    # Add alias
    cat >> ~/.zshrc << EOF

# --- $USER@$HOST:$DEV_PORT ---
alias ssh-${SSH_NAME}='ssh -p $DEV_PORT $USER@$HOST'
EOF
    echo "✅ Added alias ssh-${SSH_NAME} -> ssh -p $DEV_PORT $USER@$HOST"
fi
```

**Optionally add Tailscale alias:**

```bash
TS_IP=$(ssh -p $SSH_PORT $USER@$HOST "tailscale ip -4 2>/dev/null" || echo "")
if [ -n "$TS_IP" ] && ! grep -q "alias ssh-${SSH_NAME}-ts=" ~/.zshrc 2>/dev/null; then
    cat >> ~/.zshrc << EOF
alias ssh-${SSH_NAME}-ts='ssh $USER@$TS_IP'
EOF
    echo "✅ Added alias ssh-${SSH_NAME}-ts"
fi
```

After adding aliases, remind the user:

```
🔔 请执行 source ~/.zshrc 或新开终端窗口
```

### Step 9: Report Summary

```
✅ 开发环境配置完成

服务器:  $USER@$HOST (SSH port $SSH_PORT)
开发容器: $USER@$HOST:$DEV_PORT
本地别名: ssh-${SSH_NAME}

管理命令:
  ssh-${SSH_NAME}                           # 进入开发容器
  ssh -p $SSH_PORT $USER@$HOST "cd ~/workspace/playground && source run.sh && work-server-ls"   # 查看容器
  ssh -p $SSH_PORT $USER@$HOST "cd ~/workspace/playground && source run.sh && work-server-stop default" # 停止
  ssh -p $SSH_PORT $USER@$HOST "cd ~/workspace/playground && source run.sh && work-server default"       # 启动

如需修改 HOST_IP（提示符显示）:
  ssh -p $SSH_PORT $USER@$HOST "echo 'export HOST_IP=你的IP' >> ~/.bashrc"
```

## Error Handling

| 问题 | 处理方法 |
|------|----------|
| SSH 连接失败 | 检查网络/端口，让用户手动排查 |
| Docker 未安装且无法自动安装 | 让用户手动安装后重试 |
| DEV_PORT 被非 Docker 进程占用 | 报告并让用户换个端口 |
| 容器启动失败 | 打印 `docker run` 错误，检查 NVIDIA 驱动 |
| SSH 到 DEV_PORT 失败 | 检查容器状态，添加公钥到 authorized_keys |
| Git clone 失败（GFW） | 降到下一条优先级路径 |
