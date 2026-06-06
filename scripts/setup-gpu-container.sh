#!/usr/bin/env bash
# setup-gpu-container.sh — NVIDIA GPU 容器安装 + 诊断脚本
# 用法: sudo bash setup-gpu-container.sh
#        bash setup-gpu-container.sh check   只检测不安装
#        bash setup-gpu-container.sh fix     强制重新安装 + 重建容器
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "${CYAN}$1${NC}"; }
header() { echo ""; info "══════════════════════════════════════"; info "  $1"; info "══════════════════════════════════════"; }

check_nvidia_driver() {
  header "检测 NVIDIA 驱动"
  if command -v nvidia-smi &>/dev/null; then
    local driver cuda
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    cuda=$(nvidia-smi | grep -oP "CUDA Version: \K[0-9.]+" | head -1)
    ok "NVIDIA 驱动版本: ${driver:-未知}"
    ok "CUDA 版本: ${cuda:-未知}"
    nvidia-smi --query-gpu=name,index --format=csv,noheader 2>/dev/null | while IFS=, read -r name idx; do
      ok "GPU ${idx}: ${name}"
    done
  else
    err "nvidia-smi 不存在 — 宿主机没有 NVIDIA 驱动！"
    exit 1
  fi
}

check_toolkit() {
  header "检测 nvidia-container-toolkit"
  if dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"; then
    ok "nvidia-container-toolkit 已安装"
  else
    err "nvidia-container-toolkit 未安装"
    return 1
  fi
  if command -v nvidia-ctk &>/dev/null; then
    ok "nvidia-ctk 可用"
  else
    err "nvidia-ctk 命令不存在"
    return 1
  fi
}

check_docker_runtime() {
  header "检测 Docker NVIDIA Runtime"
  local runtimes
  runtimes=$(docker info 2>/dev/null | grep "Runtimes:" || true)
  if echo "$runtimes" | grep -q "nvidia"; then
    ok "Docker NVIDIA Runtime 已注册"
    ok "Runtimes: $(echo "$runtimes" | sed 's/.*Runtimes: //')"
  else
    err "Docker 没有 nvidia runtime → 容器无法使用 GPU"
    err "当前 Runtimes: $runtimes"
    return 1
  fi
}

check_container() {
  header "检测 2225 开发容器 GPU"
  local name="${USER:-lulizhi}-work-server-dev"
  if ! docker inspect "$name" &>/dev/null; then
    err "容器 $name 不存在"
    return 1
  fi

  local runtime device_req
  runtime=$(docker inspect "$name" --format '{{.HostConfig.Runtime}}' 2>/dev/null)
  device_req=$(docker inspect "$name" --format '{{json .HostConfig.DeviceRequests}}' 2>/dev/null)

  if [ "$device_req" != "null" ] && [ "$device_req" != "" ]; then
    ok "容器已配置 GPU 设备请求"
  else
    err "容器未配置 GPU (DeviceRequests=null)"
    warn "旧容器是在安装 toolkit 之前创建的，需要重建"
  fi

  if docker exec "$name" nvidia-smi &>/dev/null; then
    ok "容器内 GPU 可用:"
    docker exec "$name" nvidia-smi --query-gpu=name --format=csv,noheader | head -1
  else
    err "容器内无法访问 GPU"
  fi
}

install_toolkit() {
  header "安装 nvidia-container-toolkit"

  if [ "$EUID" -ne 0 ]; then
    err "安装需要 root 权限，请用 sudo 执行: sudo bash $0 install"
    exit 1
  fi

  echo "  添加 NVIDIA 软件源..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
  curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  echo "  更新包索引..."
  apt-get update -qq

  echo "  安装 nvidia-container-toolkit..."
  apt-get install -y -qq nvidia-container-toolkit
  ok "nvidia-container-toolkit 安装完成"
}

configure_docker() {
  header "配置 Docker NVIDIA Runtime"
  if [ "$EUID" -ne 0 ]; then
    err "需要 root 权限，请用 sudo 执行"
    exit 1
  fi

  nvidia-ctk runtime configure --runtime=docker
  ok "Docker 运行时配置已更新"

  echo "  重启 Docker..."
  systemctl restart docker
  ok "Docker 已重启"
}

recreate_container() {
  header "重建 2225 开发容器（启用 GPU）"
  local name="${USER:-lulizhi}-work-server-dev"

  echo "  停止并删除旧容器..."
  docker container rm -f "$name" 2>/dev/null || true

  echo "  重新启动容器（含 --gpus all）..."
  cd "$HOME/workspace"
  if [ -f "scripts/docker/work-server.sh" ]; then
    bash -c ". scripts/docker/work-server.sh && work-server dev -f"
  else
    err "找不到 scripts/docker/work-server.sh，请确认路径"
    exit 1
  fi
}

summary() {
  header "检测总结"
  if command -v nvidia-smi &>/dev/null; then
    ok "NVIDIA 驱动: 正常"
  else
    err "NVIDIA 驱动: 缺失"
  fi
  if dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"; then
    ok "nvidia-container-toolkit: 已安装"
  else
    err "nvidia-container-toolkit: 未安装"
  fi
  if docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
    ok "Docker nvidia runtime: 已注册"
  else
    err "Docker nvidia runtime: 未注册"
  fi
  if docker exec "${USER:-lulizhi}-work-server-dev" nvidia-smi &>/dev/null; then
    ok "容器 GPU: 可用"
  else
    err "容器 GPU: 不可用"
  fi
}

# ====== 主流程 ======
case "${1:-all}" in
  check|检测)
    check_nvidia_driver
    check_toolkit || true
    check_docker_runtime || true
    check_container || true
    ;;
  install|安装)
    check_nvidia_driver
    install_toolkit
    configure_docker
    ok "安装完成！现在运行以下命令重建容器:"
    echo "  sudo bash $0 recreate"
    ;;
  recreate|重建)
    check_docker_runtime
    recreate_container
    check_container
    ;;
  fix|修复)
    check_nvidia_driver
    install_toolkit
    configure_docker
    recreate_container
    check_container
    summary
    ;;
  *)
    header "NVIDIA GPU 容器工具"
    echo "用法: sudo bash $0 <命令>"
    echo ""
    echo "命令:"
    echo "  check                  只检测，不安装"
    echo "  install                安装 nvidia-container-toolkit + 配置 Docker"
    echo "  recreate               重建容器（启用 GPU）"
    echo "  fix                    安装 + 配置 + 重建（一键修复）"
    echo ""
    echo "示例:"
    echo "  sudo bash $0 fix       # 一键修复所有问题"
    echo "  bash $0 check          # 只检测当前状态"
    ;;
esac
