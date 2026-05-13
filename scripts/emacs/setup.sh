#!/bin/bash
set -e

DOCKER_REPO="https://github.com/lulzsec2012/docker.git"
DOCKERFILE="emacs.Dockerfile"
IMAGE_NAME="lulzsec2012/emacs:latest"
LOCAL_TAG="emacs:local"
BASHRC="$HOME/.bashrc"
MARKER_BEGIN="# >>> docker-emacs setup"
MARKER_END="# <<< docker-emacs setup"

# ============================================================

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Error: docker not found. Install Docker first."
        exit 1
    fi
}

option_pull() {
    echo ">> Pulling $IMAGE_NAME from Docker Hub..."
    docker pull "$IMAGE_NAME"
    echo ">> Done. Image: $IMAGE_NAME"
}

option_build() {
    local BUILD_DIR
    BUILD_DIR=$(mktemp -d)
    echo ">> Cloning docker repo..."
    git clone --depth 1 "$DOCKER_REPO" "$BUILD_DIR"
    echo ">> Building from $DOCKERFILE..."
    docker build -f "$BUILD_DIR/$DOCKERFILE" -t "$LOCAL_TAG" "$BUILD_DIR"
    rm -rf "$BUILD_DIR"
    echo ">> Done. Image: $LOCAL_TAG"
}

inject_bashrc_docker() {
    local TAG="$1"

    sed -i '' "/^$MARKER_BEGIN/,/^$MARKER_END/d" "$BASHRC" 2>/dev/null || true

    cat >> "$BASHRC" <<'BASHRC_EOF'

# >>> docker-emacs setup
# Docker-based emacs daemon — only activates when the image is available.
# Falls back to native emacs on machines where Docker image isn't present.
if docker image inspect lulzsec2012/emacs:latest >/dev/null 2>&1; then
    _emacs_docker_run() {
        docker run -d --rm \
            --network=host \
            -v "$HOME:$HOME" \
            -e HOME -e TERM \
            --user "$(id -u):$(id -g)" \
            --name emacs-daemon \
            lulzsec2012/emacs:latest \
            sh -c "emacs --daemon=lulizhi && sleep infinity" 2>&1 || \
            echo "emacs-D failed. Check: docker rm -f emacs-daemon"
    }
    alias emacs-D='_emacs_docker_run'
    alias emacs-C='docker exec -it emacs-daemon emacsclient -s lulizhi -nw'
    alias emacs-daemon-stop='docker stop emacs-daemon >/dev/null 2>&1'
fi
# <<< docker-emacs setup
BASHRC_EOF

    echo ">> Aliases added to $BASHRC"
    echo "   Run:  source $BASHRC"
    echo ""
    echo "   Commands:"
    echo "     emacs-D              Start emacs daemon in Docker container"
    echo "     emacs-C              Connect terminal to emacs daemon"
    echo "     emacs-daemon-stop    Stop the daemon container"
}

# ============================================================

echo "==================================="
echo " Docker Emacs 环境安装"
echo "==================================="
echo ""

check_docker

echo "选择安装方式:"
echo "  1) 从 Docker Hub 下载（推荐，~200MB）"
echo "  2) 本地自动编译（不需 Docker Hub）"
echo "  3) 仅注入 bashrc alias（镜像已存在时使用）"
echo "  0) 退出"
echo ""
read -p "请输入 [1/2/3/0]: " choice

case "$choice" in
    1)
        option_pull
        inject_bashrc_docker "$IMAGE_NAME"
        ;;
    2)
        option_build
        inject_bashrc_docker "$LOCAL_TAG"
        ;;
    3)
        inject_bashrc_docker "$IMAGE_NAME"
        ;;
    0)
        echo "退出."
        exit 0
        ;;
    *)
        echo "无效选项."
        exit 1
        ;;
esac

echo ""
echo "===================================="
echo " 安装完成！"
echo "===================================="
echo ""
echo "使用方式:"
echo "  第一步:   source ~/.bashrc"
echo "  第二步:   emacs-D"
echo "           （启动 emacs daemon 容器，后台常驻）"
echo "  第三步:   emacs-C"
echo "           （连上 emacs，就像本地程序一样使用）"
echo ""
echo "  daemon 停止: emacs-daemon-stop"
echo ""
echo "注意: 99-dev.sh 中的原生 emacs-D/emacs-C 不变，"
echo "      本脚本的 Docker 版本只在 Docker 镜像存在时自动生效。"
echo "      两者互不冲突，各自兼容。"
