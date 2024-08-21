ARG UBUNTU_VERSION=20.04
ARG UBUNTU_NAME=focal
ARG DEBIAN_FRONTEND="noninteractive"

# ********************************************************************************
#
# satge 0
# ********************************************************************************

FROM harbor.houmo.ai/toolchain/dev:v0.9.0-ubuntu20.04-py38-x84.64 AS builder0
ARG UBUNTU_NAME
ARG DEBIAN_FRONTEND

# updata apt source to tuna source
RUN echo "deb http://mirrors.aliyun.com/ubuntu/ focal main restricted universe multiverse" > /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ focal-security main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ focal-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ focal-proposed main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ focal-backports main restricted universe multiverse" >> /etc/apt/sources.list

# Update pip source to tuna
RUN mkdir -p ~/.pip/ && \
    echo "[global]" > ~/.pip/pip.conf && \
    echo "index-url = https://pypi.tuna.tsinghua.edu.cn/simple" >> ~/.pip/pip.conf && \
    echo "[install]" >> ~/.pip/pip.conf && \
    echo "trusted-host = https://pypi.tuna.tsinghua.edu.cn" >> ~/.pip/pip.conf

# configure timezone
RUN echo Asia/Shanghai > /etc/timezone

RUN apt-get update && \
    apt-get install -y software-properties-common gpg-agent && \
    apt-add-repository ppa:ubuntu-toolchain-r/test && \
    apt-get update && \
    apt-get install -y \
    vim \
    guake \
    apt-utils \
    texinfo \
    libgccjit-10-dev \
    shellcheck \
    # perf
    linux-tools-generic \
    linux-tools-common \
    linux-cloud-tools-generic \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# dependency of Emacs
RUN apt-get update && \
    apt-get install -y software-properties-common gpg-agent && \
    apt-add-repository ppa:ubuntu-toolchain-r/test && \
    apt-get update && rm -rf /usr/local/man && \
    apt-get install -y  \
    libmpc3 \
    libmpfr6 \
    libgmp10 \
    coreutils \
    libjpeg-turbo8 \
    libtiff5 \
    libxpm4 \
    libjansson-dev \
    libgnutls28-dev \
    libgnutlsxx28 \
    libncurses5 \
    libxml2 \
    libxt6 \
    libjansson4 \
    libx11-xcb1 \
    binutils \
    libc6-dev \
    librsvg2-2 \
    libgccjit-13-dev \
    # libgccjit-11 needs gcc-12 ?
    gcc-13 g++-13 \
    libsqlite3-dev \
    # for vterm
    libtool \
    libtool-bin \
    # libenchant for jinx
    libglib2.0-dev \
    # for monkeytype
    fortune \
    fortunes \
    build-essential \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# https://www.masteringemacs.org/article/speed-up-emacs-libjansson-native-elisp-compilation
# https://gitlab.com/koral/emacs-nativecomp-dockerfile/-/blob/master/Dockerfile

RUN apt-get update \
    && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    # other package needed
    wget \
    unzip

# install tree-sitter
# https://www.reddit.com/r/emacs/comments/z25iyx/comment/ixll68j/?utm_source=share&utm_medium=web2x&context=3
ENV CFLAGS="-O3 -Wall -Wextra"
RUN git clone --depth 1 --branch v0.22.6 https://github.com/tree-sitter/tree-sitter.git /opt/tree-sitter && \
    cd /opt/tree-sitter && \
    make -j4 && \
    make install

RUN ldconfig
ENV CFLAGS="-O2"
RUN git clone --depth 1 --branch emacs-29 https://github.com/emacs-mirror/emacs /opt/emacs && \
    cd /opt/emacs && \
    ./autogen.sh && \
    ./configure --build="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
    --with-modules \
    --with-native-compilation \
    --with-tree-sitter \
    --with-json \
    --with-sqlite3 \
    --with-gif=ifavailable \
    --with-jpeg=ifavailable \
    --with-tiff=ifavailable \
    # no need GUI and silent the `--with-x-toolkit=lucid` warning.
    --without-x --without-x-toolkit-scroll-bars \
    --without-native-compilation \
    --prefix=/usr/local && \
    make -j && \
    make install-strip


# ============================================================
# tree-sitter-language
# https://github.com/orzechowskid/emacs-docker/blob/main/src/build-ts-modules.sh
# https://github.com/emacs-mirror/emacs/tree/master/admin/notes/tree-sitter
# https://emacs-china.org/t/treesit-master/22862/69
RUN apt-get update && \
    apt-get install -y g++ && \
    git clone https://github.com/casouri/tree-sitter-module /opt/tree-sitter-module && \
    cd /opt/tree-sitter-module && \
    # bugfix: https://github.com/tree-sitter/tree-sitter-cpp/issues/271
    sed -i '/case "${lang}" in/a\    "cpp")\n        branch="v0.22.0"\n        ;;' build.sh && \
    ./batch.sh && \
    mv ./dist/* /usr/local/lib/ && \
    cd /opt/

# ============================================================
# Install GDB
# https://www.linuxfromscratch.org/blfs/view/svn/general/gdb.html
RUN apt-get update && \
    apt-get install -y python3-dev libmpfr-dev libgmp-dev libreadline-dev && \
    wget https://ftp.gnu.org/gnu/gdb/gdb-14.2.tar.gz && \
    tar -xf gdb-14.2.tar.gz && \
    cd gdb-14.2 && \
    ./configure --with-python=yes --prefix=/usr/local --with-system-readline && \
    make -j30 && make install

# ===========================================================
# install fuz (fuzzy match scoring/matching functions for Emacs)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    apt-get update && apt-get install -y clang llvm && \
    git clone https://github.com/rustify-emacs/fuz.el fuz

# ================================================================================
# some others
RUN apt-get update && ldconfig && \
    apt-get install -y   \
    build-essential \
    apt-transport-https \
    ca-certificates \
    valgrind \
    openssh-client \
    sudo \
    # gdb \
    libmpfr-dev libgmp-dev libreadline-dev \
    # tectonic
    libfreetype6-dev \
    libssl-dev \
    libfontconfig1-dev \
    # dev needed
    parallel \
    rsync \
    graphviz \
    # for BM
    bison \
    flex \
    bsdmainutils \
    # for mosh-server
    libprotobuf-dev \
    libutempter-dev \
    # ping network
    iputils-ping \
    netcat \
    # SQL
    sqlite3 postgresql-client \
    # smb
    smbclient \
    # python3
    python3-dev \
    python3-venv \
    python3-pip \
    virtualenv \
    tzdata \
    # tablegen
    libncurses5-dev \
    libncurses5 \
    # riscv-isa-sim
    device-tree-compiler libboost-regex-dev \
    # tools
    ninja-build \
    curl wget \
    unzip \
    ccache \
    git-lfs \
    patchelf \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN \
    # fix emacs bug
    find /usr/local/lib/emacs/ -name native-lisp | xargs -I{} ln -s {} /usr/


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

# 允许sudo组成员执行sudo命令
RUN echo 'lizhi.lu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# CMD "start.sh"

WORKDIR /workspace
