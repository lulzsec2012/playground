#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# run-lite-ubuntu.sh — 部署 Ubuntu 24.04 精简版容器
#
# 用法:
#   bash scripts/docker/run-lite-ubuntu.sh
#
# 功能:
#   - 基于 ubuntu:24.04 构建最小 SSH 镜像
#   - 暴露端口 2221 → 22（容器内 SSH）
#   - 暴露端口 1080 → 1080（SOCKS5 代理）
#   - 暴露端口 9090 → 9090（sing-box Clash Dashboard）
#   - 挂载 $HOME/workspace → /workspace
#   - 挂载宿主 docker.sock, 容器内可直接使用 docker 命令
#   - 自动创建与宿主机同 UID 的用户, 免密 sudo
#   - 导入宿主机 SSH 公钥实现免密登录
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 配置 ----
IMAGE_NAME="ubuntu-lite:24.04"
CONTAINER_NAME="ubuntu-lite"
HOST_PORT=2221
WORKSPACE_DIR="$HOME/workspace"
SSH_AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys"

# ---- 检查 Docker ----
if ! command -v docker &>/dev/null; then
    echo "❌ 未找到 docker 命令"
    exit 1
fi

# ---- 1. 构建镜像 ----
if ! docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qFx "${IMAGE_NAME}"; then
    echo "🔨 构建镜像 ${IMAGE_NAME} ..."
    docker build -t "${IMAGE_NAME}" - <<-'DOCKERFILE'
    FROM ubuntu:24.04

    ENV DEBIAN_FRONTEND=noninteractive

    # SSH 配置 / 编译工具 / 脚本语言
    RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        sudo \
        ca-certificates \
        curl \
        git \
        python3 \
        python3-yaml \
        build-essential \
        && rm -rf /var/lib/apt/lists/*

    # SSH 配置: 允许 root 密码登录（方便首次配置）
    RUN mkdir -p /var/run/sshd && \
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
        sed -i 's/^#PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config && \
        sed -i 's/^#ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config && \
        sed -i 's/^#UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

    EXPOSE 22
    CMD ["/usr/sbin/sshd", "-D"]
DOCKERFILE
    echo "✅ 镜像构建完成"
else
    echo "ℹ️  镜像 ${IMAGE_NAME} 已存在, 跳过构建"
fi

# ---- 2. 清理旧容器 ----
if docker inspect "${CONTAINER_NAME}" &>/dev/null; then
    echo "👋 移除旧容器 ${CONTAINER_NAME} ..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

# ---- 3. 启动容器 ----
echo "🚀 启动容器 ${CONTAINER_NAME} (端口 ${HOST_PORT})..."

docker run -d --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${HOST_PORT}:22" \
    -p "1080:1080" \
    -p "9090:9090" \
    -v "${WORKSPACE_DIR}:/workspace" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    --security-opt seccomp=unconfined \
    ${DOCKER_API_VERSION:+-e DOCKER_API_VERSION="${DOCKER_API_VERSION}"} \
    -t "${IMAGE_NAME}"

# 检测宿主机 Docker API 版本，容器内 CLI 版本可能过新，需对齐
DOCKER_API_VERSION="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "")"

echo "  等待 SSH 启动..."
sleep 2

# ---- 4. 创建用户 ----
HOST_USER="$(whoami)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

echo "👤 创建用户 ${HOST_USER} (UID=${HOST_UID}, GID=${HOST_GID})..."

docker exec "${CONTAINER_NAME}" bash -c "
    set -e
    getent group ${HOST_GID} >/dev/null 2>&1 || groupadd -g ${HOST_GID} ${HOST_USER}
    id -u ${HOST_USER} >/dev/null 2>&1 || useradd -m -u ${HOST_UID} -g ${HOST_GID} -G sudo -s /bin/bash ${HOST_USER}
    passwd -d ${HOST_USER} >/dev/null 2>&1
    echo '${HOST_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${HOST_USER}
"

# ---- 5. 导入 SSH 公钥 ----
if [ -f "${SSH_AUTHORIZED_KEYS}" ]; then
    echo "🔑 导入 SSH 公钥..."
    docker exec "${CONTAINER_NAME}" bash -c "
        mkdir -p /home/${HOST_USER}/.ssh
        chmod 700 /home/${HOST_USER}/.ssh
    "
    docker cp "${SSH_AUTHORIZED_KEYS}" "${CONTAINER_NAME}:/home/${HOST_USER}/.ssh/authorized_keys"
    docker exec "${CONTAINER_NAME}" bash -c "
        chmod 600 /home/${HOST_USER}/.ssh/authorized_keys
        chown -R ${HOST_UID}:${HOST_GID} /home/${HOST_USER}
    "
fi

# ---- 6. 安装 docker CLI（利用宿主机 docker.sock 调用 Docker） ----
echo "🐳 安装 docker CLI..."
SOCKET_GID=$(docker exec "${CONTAINER_NAME}" stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "")
docker exec "${CONTAINER_NAME}" bash -c "
    apt-get update -qq && apt-get install -y -qq --no-install-recommends docker.io >/dev/null 2>&1
    if [ -n '${SOCKET_GID}' ]; then
        groupadd -g ${SOCKET_GID} docker-host 2>/dev/null || true
        usermod -aG ${SOCKET_GID} ${HOST_USER}
    fi
" || echo "  ⚠️ docker CLI 安装失败（可后续手动安装）"

# 配置 SSH 环境变量，使非交互命令（ssh host "cmd"）也能使用 Docker
if [ -n "${DOCKER_API_VERSION}" ]; then
    docker exec "${CONTAINER_NAME}" bash -c "
        echo 'DOCKER_API_VERSION=${DOCKER_API_VERSION}' >> ~${HOST_USER}/.ssh/environment
        chmod 644 ~${HOST_USER}/.ssh/environment
        grep -q '^PermitUserEnvironment' /etc/ssh/sshd_config || echo 'PermitUserEnvironment yes' >> /etc/ssh/sshd_config
    " >/dev/null 2>&1
fi

# ---- 7. 关闭密码登录（仅允许密钥认证） ----
docker exec "${CONTAINER_NAME}" bash -c "
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^UsePAM.*/UsePAM no/' /etc/ssh/sshd_config
" >/dev/null 2>&1
docker exec "${CONTAINER_NAME}" service ssh restart >/dev/null 2>&1 || true

# ---- 8. 输出信息 ----
BRIDGE_IP=$(docker inspect "${CONTAINER_NAME}" --format '{{.NetworkSettings.IPAddress}}' 2>/dev/null || echo "unknown")
echo ""
echo "============================================"
echo " ✅ 容器已启动"
echo "============================================"
echo "  容器名:     ${CONTAINER_NAME}"
echo "  镜像:       ${IMAGE_NAME}"
echo "  Bridge IP:  ${BRIDGE_IP}"
echo "  端口映射:   ${HOST_PORT} → 22"
echo "  挂载卷:     ${WORKSPACE_DIR} → /workspace"
echo "  Docker:     docker.sock 已挂载, CLI 已安装"
echo "  用户:       ${HOST_USER} (UID=${HOST_UID})"
echo ""
echo "  SSH 连接方式:"
echo "    ssh -p ${HOST_PORT} ${HOST_USER}@localhost"
echo "    ssh -p ${HOST_PORT} ${HOST_USER}@<host-ip>"
echo ""
echo "  容器内使用 Docker:"
echo "    docker ps"
echo "    docker run --rm hello-world"
echo ""
echo "  进入容器:"
echo "    docker exec -it ${CONTAINER_NAME} bash"
echo "============================================"
