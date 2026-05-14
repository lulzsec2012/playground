#!/usr/bin/env bash
# ============================================================
# setup-docker-mirror.sh — Docker 镜像加速器配置脚本
# 适用于中国大陆服务器加速 Docker Hub 拉取
# ============================================================
set -euo pipefail

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; NC="\033[0m"
info()  { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()   { printf "${RED}[✗]${NC} %s\n" "$*"; }

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

配置 Docker 镜像加速器以加速中国大陆的 Docker Hub 拉取。

选项:
  -m <mirrors>   自定义镜像加速器地址（逗号分隔）
  -y, --yes      自动确认，不询问
  -h             帮助

示例:
  $(basename "$0")
  $(basename "$0") -m "https://docker.xuanyuan.me,https://docker.1ms.run"
EOF
    exit 1
}

# ====== 镜像加速器地址（2026年5月实测有效） ======
MIRRORS=(
    "https://docker.xuanyuan.me"       # ★ 强烈推荐，高速稳定
    "https://docker.1ms.run"           # ★ 速度优秀，10MB/s+
    "https://docker.m.daocloud.io"     # DaoCloud 企业级
    "https://docker.nju.edu.cn"        # 南京大学镜像
    "https://mirror.baidubce.com"      # 百度云镜像
)

AUTO_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) IFS="," read -ra MIRRORS <<< "$2"; shift 2 ;;
        -y|--yes) AUTO_YES=true; shift ;;
        -h|--help) usage ;;
        *) err "未知选项: $1"; usage ;;
    esac
done

command -v docker &>/dev/null || { err "Docker 未安装"; exit 1; }

echo "=============================="
echo "  Docker 镜像加速器配置"
echo "=============================="
echo ""
echo " 镜像加速器地址:"
for m in "${MIRRORS[@]}"; do echo "   - $m"; done
echo ""

# ====== 检查 sudo 权限（lzlu 无密码，提前告知） ======
if ! sudo -n true 2>/dev/null; then
    warn "当前用户无法免密码执行 sudo"
    echo ""
    echo "请手动执行以下命令："
    echo ""
    echo "  sudo tee /etc/docker/daemon.json <<EOF"
    echo "  {"
    echo "    \"registry-mirrors\": ["
    for i in "${!MIRRORS[@]}"; do
        sep=","; [ $i -eq $((${#MIRRORS[@]}-1)) ] && sep=""
        echo "      \"${MIRRORS[$i]}\"$sep"
    done
    echo "    ],"
    echo "    \"exec-opts\": [\"native.cgroupdriver=systemd\"],"
    echo "    \"log-driver\": \"json-file\","
    echo "    \"log-opts\": { \"max-size\": \"100m\", \"max-file\": \"3\" },"
    echo "    \"storage-driver\": \"overlay2\""
    echo "  }"
    echo "  EOF"
    echo ""
    echo "  sudo systemctl daemon-reload && sudo systemctl restart docker"
    echo ""
    exit 0
fi

# ====== 有 sudo 权限，自动配置 ======
DAEMON_JSON="/etc/docker/daemon.json"
MIRRORS_JSON=""
for m in "${MIRRORS[@]}"; do
    [ -n "$MIRRORS_JSON" ] && MIRRORS_JSON+=", "
    MIRRORS_JSON+="\"$m\""
done

CONFIG=$(cat <<EOF
{
  "registry-mirrors": [${MIRRORS_JSON}],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
)

echo " 写入配置..."
echo "$CONFIG" | sudo tee "$DAEMON_JSON" > /dev/null
info "已写入 $DAEMON_JSON"
sudo systemctl daemon-reload
sudo systemctl restart docker
info "Docker 服务已重启"

echo ""
echo " 验证配置..."
sleep 2
docker info 2>/dev/null | grep -A5 "Registry Mirrors" || true
echo ""
info "配置完成！运行以下命令验证:"
echo "    docker pull tailscale/tailscale:stable"
