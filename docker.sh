#!/bin/bash

base_name="mattlu"
base_name2="man.lu"
alex_name="lizhi.lu"

base_image="mattlu/work-dev:latest"
alex_image="${base_image//$base_name/$alex_name}"

echo "BASE_IMAGE: $base_image"
echo "ALEX_IMAGE: $alex_image"

# 检查 BASE_IMAGE 镜像是否存在
if [  -n "$(docker images -q $base_image)" ]; then
  echo "Docker 镜像 $base_image 已存在。拉取最新镜像..."
  docker pull $base_image
else
  echo "Docker 镜像 $base_image 不存在，正在拉取..."
  docker pull $base_image
  if [ $? -ne 0 ]; then
    echo "无法拉取 Docker 镜像 $base_image."
    exit 1
  fi
fi

# 检查 ALEX_IMAGE 镜像是否存在
if [ ! -n "$(docker images -q $alex_image)" ]; then
  echo "Docker 镜像 $alex_image 不存在。构建该镜像..."
  docker build -t $alex_image -f work.Dockerfile .
else
  echo "Docker 镜像 $alex_image 已存在."
fi

run_script="./docker/run.sh"
if [ -f "$run_script" ]; then
  echo "更新运行脚本中的用户名..."
  sed -i "s/$base_name/$alex_name/g" "$run_script"
  sed -i "s/$base_name2/$alex_name/g" "$run_script"
  if [ $? -eq 0 ]; then
    echo "运行脚本更新成功."
  else
    echo "更新运行脚本失败."
    exit 1
  fi
else
  echo "运行脚本 $run_script 不存在."
  exit 1
fi
