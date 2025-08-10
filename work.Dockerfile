# 单阶段优化版（保留完整开发环境）
FROM mattlu/work-dev

# 设置非交互式前端（避免apt安装时提示）
ARG DEBIAN_FRONTEND="noninteractive"

# 1. 合并所有apt-get操作为一个RUN指令
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common \
        gpg-agent \
        vim \
        guake \
        shellcheck \
        linux-tools-generic \
        linux-tools-common \
        linux-cloud-tools-generic \
        sudo && \
    apt-add-repository ppa:ubuntu-toolchain-r/test && \
    apt-get update && \
    # 清理缓存
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 2. 优化pip安装（先安装，后清理缓存）
RUN pip install \
        numpy \
        onnx \
        pybind11 \
        pytest \
        graphviz \
        jinja2 \
        matplotlib \
        torch \
        black \
        psutil \
        tushare \
        pylint \
        tabulate \
        openpyxl \
        cmake-format \
        loguru \
        transformers && \
    pip cache purge

# 3. SSH服务配置优化
RUN sed -i /etc/ssh/sshd_config \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    -e 's/^#\?Port.*/Port 22/' 

# 4. 用户权限设置
RUN echo 'lizhi.lu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN echo 'lulizhi ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# 5. 设置工作目录和启动命令
WORKDIR /workspace
CMD ["start.sh"]