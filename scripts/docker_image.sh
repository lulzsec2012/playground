#!/bin/bash

# 定义变量
BASE_IMAGE="mattlu/work-dev:latest"
ALEX_IMAGE="${BASE_IMAGE//mattlu/lizhi.lu}"
DOCKER_DRAG_REPO="https://github.com/NotGlop/docker-drag.git"

# 函数：拉取镜像
pull_image() {
    local image="$1"
    
    if docker images -q "$image" > /dev/null 2>&1; then
        echo "本地基础镜像已存在，跳过下载"
        return 0
    fi

    echo "本地基础镜像不存在，尝试下载..."
    
    # 先尝试 docker pull
    echo "尝试使用 docker pull..."
    if docker pull "$image"; then
        echo "docker pull 成功！"
        return 0
    fi

    echo "docker pull 失败，尝试使用 docker-drag..."
    
    # 确保 docker-drag 可用
    if [ ! -d "docker-drag" ]; then
        echo "下载 docker-drag 工具..."
        if ! git clone "$DOCKER_DRAG_REPO"; then
            echo "错误: 无法下载 docker-drag 工具！"
            return 1
        fi
    fi
    
    # 使用 docker-drag 下载
    if python3 docker-drag/docker_pull.py "$image"; then
        echo "docker-drag 下载成功，导入镜像..."
        docker load -i "${image}.tar"
        return 0
    fi

    echo "错误: docker-drag 下载失败！"
    return 1
}

# 函数：构建镜像
build_image() {
    local image="$1"
    
    # 检查并删除已存在的镜像
    if docker inspect --type=image "$image" >/dev/null 2>&1; then
        echo "发现已存在的目标镜像，正在删除..."
        if ! docker rmi -f "$image" 2>/dev/null; then
            echo "警告: 无法删除现有镜像，可能正在被使用"
            used_by=$(docker ps -a --filter "ancestor=$image" --format '{{.ID}}')
            if [ -n "$used_by" ]; then
                echo "镜像被以下容器使用: $used_by"
            fi
            return 1
        fi
    else
        echo "目标镜像不存在，无需删除"
    fi

    # 构建镜像
    echo "构建镜像: $image ..."
    if docker build -t "$image" -f work.Dockerfile .; then
        echo "镜像构建成功: $image"
        return 0
    fi

    echo "错误: 镜像构建失败！"
    return 1
}

# 主流程
echo "目标基础镜像: $BASE_IMAGE"
echo "目标构建镜像: $ALEX_IMAGE"

# 拉取基础镜像
if ! pull_image "$BASE_IMAGE"; then
    exit 1
fi

# 构建目标镜像
if ! build_image "$ALEX_IMAGE"; then
    exit 1
fi

exit 0