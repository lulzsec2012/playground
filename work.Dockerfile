ARG UBUNTU_VERSION=20.04
ARG UBUNTU_NAME=focal
ARG DEBIAN_FRONTEND="noninteractive"

# ********************************************************************************
#
# satge 0
# ********************************************************************************

FROM mattlu/work-dev AS builder0
ARG UBUNTU_NAME
ARG DEBIAN_FRONTEND

RUN apt-get update && \
    apt-get install -y software-properties-common gpg-agent && \
    apt-add-repository ppa:ubuntu-toolchain-r/test && \
    apt-get update && \
    apt-get install -y \
    vim \
    guake \
    # perf
    linux-tools-generic \
    linux-tools-common \
    linux-cloud-tools-generic \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# setup SSH server
RUN sed -i /etc/ssh/sshd_config \
    -e 's/#PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/#RSAAuthentication.*/RSAAuthentication yes/'  \
    -e 's/#PasswordAuthentication.*/PasswordAuthentication yes/'

# 安装sudo工具
RUN apt-get update && apt-get install -y sudo

# # 将用户xxx添加到sudo组
# RUN usermod -aG sudo lizhi.lu

# 允许sudo组成员执行sudo命令，注意在echo中是`>`
RUN echo 'lizhi.lu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

CMD "start.sh"

WORKDIR /workspace
