#!/bin/bash

# Define variables
BASE_IMAGE="mattlu/work-dev:latest"
ALEX_IMAGE="${BASE_IMAGE//mattlu/lizhi.lu}"

echo "BASE_IMAGE: $BASE_IMAGE"
# echo "ALEX_IMAGE: $ALEX_IMAGE"

rm -rf docker-drag && git clone https://github.com/NotGlop/docker-drag.git

# Check if the local image exists
if docker images -q "$BASE_IMAGE" > /dev/null 2>&1; then
    echo "Local image exists, checking version..."

    # Get local image ID
    local_version=$(docker inspect --format='{{.Id}}' "$BASE_IMAGE")

    # Get remote image ID
    remote_version=$(docker inspect --format='{{.Id}}' "$BASE_IMAGE" --all 2>/dev/null)

    # Check if local version matches remote version
    if [ "$local_version" == "$remote_version" ]; then
        echo "Local image version matches remote version, skipping download."
        exit 0
    fi
else
    echo "Local image does not exist, preparing to download..."
fi

# Try to download the image using docker pull
if docker pull "$BASE_IMAGE"; then
    echo "docker pull succeeded!"
else
    echo "docker pull failed, trying to download with docker-drag..."

    # Use docker-drag to download the image
    if python3 docker-drag/docker_pull.py "$BASE_IMAGE"; then
        echo "docker-drag download succeeded, importing image..."
        docker load -i "${BASE_IMAGE}.tar"
    else
        echo "docker-drag download failed!"
        exit 1
    fi
fi

# echo "构建镜像: $ALEX_IMAGE ..."
# docker build -t $ALEX_IMAGE -f work.Dockerfile .
# exit 0
