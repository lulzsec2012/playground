#!/usr/bin/env bash
#
# MIXAPI - AI 大模型网关 Docker 部署脚本
#
# 先检查本地二进制，有则跳过下载；再检查 Docker 镜像，有则跳过编译。
# 二进制预下载到 /tmp/mixapi-bin/，Dockerfile 用 COPY 避免网络依赖。
# 持久化数据目录: ~/.mixapi_data/（数据库 + 日志）
#
# Usage: ./setup.sh
# Version: v2.5.1cl

set -euo pipefail

# 加载公共库
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lib-format.sh"

# ==== Constants ====
readonly MIXAPI_DATA="${HOME}/.mixapi_data"
readonly IMAGE_NAME="mixapi:latest"
readonly CONTAINER_NAME="mixapi"
readonly BUILD_DIR="/tmp/mixapi-build"
readonly BIN_SRC="/tmp/mixapi-bin/mixapi"
readonly BIN_URL="https://github.com/aiprodcoder/MIXAPI/releases/download/v2.5.1cl/mixapi-v2.5.1cl-linux-amd64"
readonly PROXY="http://100.81.13.45:7890"

# ==== Functions ====

# Description: Ensure the MIXAPI binary exists locally; download if missing
# Output: writes to stdout/stderr, creates file at BIN_SRC
# Returns: 0 on success, exits 1 on download failure
check_binary() {
  if [ -f "$BIN_SRC" ]; then
    return 0
  fi
  info "本地二进制不存在，通过代理下载..."
  mkdir -p "$(dirname "$BIN_SRC")"
  curl -sL --proxy "$PROXY" --max-time 300 \
    -o "$BIN_SRC" \
    "$BIN_URL" || {
    rm -f "$BIN_SRC"
    die "下载失败，请手动下载或检查代理"
  }
}

# Description: Create the persistent data working directory
setup_workdir() {
  mkdir -p "$MIXAPI_DATA"
}

# Description: Check for an existing Docker image; build if absent
# Side effects: creates BUILD_DIR, writes Dockerfile, runs docker build
ensure_image() {
  if docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -q "^${IMAGE_NAME}$"; then
    ok "镜像 ${IMAGE_NAME} 已存在，跳过编译"
    return 0
  fi

  info "未找到镜像 ${IMAGE_NAME}，开始编译..."
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cp "$BIN_SRC" "$BUILD_DIR/mixapi"

  cat > "${BUILD_DIR}/Dockerfile" << 'EOF'
FROM alpine:latest
COPY mixapi /app/mixapi
RUN chmod +x /app/mixapi
EXPOSE 3000
WORKDIR /data
CMD ["/app/mixapi"]
EOF

  docker build -t "$IMAGE_NAME" "$BUILD_DIR"
  ok "镜像 ${IMAGE_NAME} 编译完成"
}

# Description: Stop and remove any existing container with the target name
stop_old_container() {
  if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
  fi
}

# Description: Start the MIXAPI container
start_container() {
  info "启动容器..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart always \
    -p 3000:3000 \
    -v "${MIXAPI_DATA}:/data" \
    -e TZ=Asia/Shanghai \
    "$IMAGE_NAME"
}

# Description: Verify the container started and print connection info
verify_deployment() {
  sleep 3
  if docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo "============================================"
    echo "✅ MIXAPI 部署成功！"
    echo "   访问地址: http://${server_ip}:3000"
    echo "   工作目录: ${MIXAPI_DATA}"
    echo "============================================"
  else
    die "容器启动失败，请检查 docker logs ${CONTAINER_NAME}"
  fi
}

# ==== Main ====
main() {
  check_binary
  ok "二进制就绪: $(ls -lh "$BIN_SRC" | awk '{print $5}')"
  setup_workdir
  ok "工作目录: ${MIXAPI_DATA}"
  ensure_image
  stop_old_container
  start_container
  verify_deployment
}
main "$@"
