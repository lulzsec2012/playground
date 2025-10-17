#!/bin/bash

# 定义变量
BASE_IMAGE="mattlu/work-dev:latest"
ALEX_IMAGE="${BASE_IMAGE//mattlu/lizhi.lu}"
DOCKER_DRAG_REPO="https://github.com/NotGlop/docker-drag.git"

echo "目标基础镜像: $BASE_IMAGE"
echo "目标构建镜像: $ALEX_IMAGE"

# 检查并下载基础镜像
if ! docker images -q "$BASE_IMAGE" > /dev/null 2>&1; then
    echo "本地基础镜像不存在，尝试下载..."
    
    # 先尝试 docker pull
    echo "尝试使用 docker pull..."
    if docker pull "$BASE_IMAGE"; then
        echo "docker pull 成功！"
    else
        echo "docker pull 失败，尝试使用 docker-drag..."
        
        # 确保 docker-drag 可用
        if [ ! -d "docker-drag" ]; then
            echo "下载 docker-drag 工具..."
            if ! git clone "$DOCKER_DRAG_REPO"; then
                echo "错误: 无法下载 docker-drag 工具！"
                exit 1
            fi
        fi
        
        # 使用 docker-drag 下载
        if python3 docker-drag/docker_pull.py "$BASE_IMAGE"; then
            echo "docker-drag 下载成功，导入镜像..."
            docker load -i "${BASE_IMAGE}.tar"
        else
            echo "错误: docker-drag 下载失败！"
            exit 1
        fi
    fi
else
    echo "本地基础镜像已存在，跳过下载"
fi

# 更精确的检查镜像是否存在
if docker inspect --type=image "$ALEX_IMAGE" >/dev/null 2>&1; then
    echo "发现已存在的目标镜像，正在删除..."
    
    # 尝试强制删除（会解除关联的容器）
    if ! docker rmi -f "$ALEX_IMAGE" 2>/dev/null; then
        echo "警告: 无法删除现有镜像，可能正在被使用"
        
        # 获取使用该镜像的容器ID
        used_by=$(docker ps -a --filter "ancestor=$ALEX_IMAGE" --format '{{.ID}}')
        if [ -n "$used_by" ]; then
            echo "镜像被以下容器使用: $used_by"
        fi
    fi
else
    echo "目标镜像不存在，无需删除"
fi

# 构建最终镜像
echo "构建镜像: $ALEX_IMAGE ..."
if ! docker build -t "$ALEX_IMAGE" -f work.Dockerfile .; then
    echo "错误: 镜像构建失败！"
    exit 1
fi

echo "镜像构建成功: $ALEX_IMAGE"
exit 0