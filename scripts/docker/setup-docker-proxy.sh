#!/usr/bin/env bash
# setup-docker-proxy.sh — 配置 Docker daemon HTTP 代理（需要 sudo）
# 用法: sudo ./setup-docker-proxy.sh [proxy_host]
#       如果不传 proxy_host，会自动用 proxy-find.sh 查找代理
#
# 需搭配 scripts/proxy/proxy-find.sh 使用

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_CONF="/etc/docker/daemon.json"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo ">>> $*"; }
ok()   { echo "✅ $*"; }

# 检查 sudo
if [ "$(id -u)" -ne 0 ]; then
  die "需要 root 权限，请用 sudo 运行: sudo $0 [proxy_host]"
fi

# 获取代理地址
if [ $# -ge 1 ]; then
  PROXY_HOST="$1"
else
  info "未指定代理地址，尝试扫描 tailnet 中的 HTTP 代理..."
  if [ -f "$SCRIPT_DIR/../proxy/proxy-find.sh" ]; then
    # 复用脚本时指定只扫代理端口
    PROXY_HOST=$(bash "$SCRIPT_DIR/../proxy/proxy-find.sh" 2>/dev/null | grep 'HTTP proxy' | head -1 | awk '{print $NF}')
  fi
  if [ -z "$PROXY_HOST" ]; then
    die "未找到可用代理。请指定代理地址: sudo $0 <ip>:<port>"
  fi
fi

# 去掉协议前缀
PROXY_HOST="${PROXY_HOST#http://}"
PROXY_HOST="${PROXY_HOST#https://}"

info "使用代理: http://$PROXY_HOST"

# ===== 1. 读取现有 daemon.json =====
CURRENT=$(cat "$DOCKER_CONF" 2>/dev/null || echo "{}")

# ===== 2. 注入代理配置 =====
cat > "$DOCKER_CONF" <<DAEMONEOF
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.nju.edu.cn"],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
DAEMONEOF

# ===== 3. 配置 Docker systemd HTTP 代理 =====
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://$PROXY_HOST"
Environment="HTTPS_PROXY=http://$PROXY_HOST"
Environment="NO_PROXY=localhost,127.0.0.1,::1,100.100.100.100,100.x.x.x"
EOF

# ===== 4. 重载 systemd + Docker =====
systemctl daemon-reload
systemctl restart docker

sleep 2
if systemctl is-active docker &>/dev/null; then
  ok "Docker 代理配置完成！"
  echo ""
  info "Docker daemon 现在可以通过代理拉取镜像了。"
  info "运行 setup.sh 即可部署 MIXAPI。"
else
  die "Docker 重启失败，请检查 systemctl status docker"
fi
