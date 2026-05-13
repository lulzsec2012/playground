# AGENTS.md

## 仓库目的

构建个人开发环境 Docker 镜像，通过 GitHub Actions 自动推送到 DockerHub。不是传统应用仓库——全是基础设施。

## 镜像矩阵

| Dockerfile | 基础镜像 | 用途 | 推送到 DockerHub |
|---|---|---|---|---|
| `work.Dockerfile` | Ubuntu 22.04 | 主开发环境 (Emacs + dev tools) | `lulzsec2012/work-dev` |
| `work-cuda.Dockerfile` | nvidia/cuda:13.2.1-devel-ubuntu24.04 | GPU 开发环境 (含网络工具) | `lulzsec2012/work-cuda-dev` |
| `explore.Dockerfile` | Ubuntu 22.04 | 旧版探索环境 (Emacs 29) | `lulzsec2012/explore-dev` |
| `derp.Dockerfile` | golang:alpine → alpine | Tailscale DERP 中继 | `lulzsec2012/derp` |
| `exit-node.Dockerfile` | tailscale/tailscale:stable | Tailscale 出口节点 | `lulzsec2012/exit-node` |
| `socks-node.Dockerfile` | tailscale/tailscale:stable | Tailscale SOCKS5 代理 | `lulzsec2012/socks-node` |
| `wireguard.Dockerfile` | alpine:latest | WireGuard VPN 节点 | `lulzsec2012/wireguard` |
| `test.Dockerfile` | Ubuntu 22.04 | 轻量测试环境 (tailscale + clash) | `lulzsec2012/test` |

## 构建命令

本地构建单个镜像（以 work-dev 为例）：

```bash
docker build . --file work.Dockerfile --tag work-dev
```

注意：`explore.Dockerfile` 是旧版且独立的，不与其他 Dockerfile 共享 builder 阶段的 `/usr/local`（其余镜像从 `builder0` 的 builder1 阶段复制构建产物）。

## CI/CD (GitHub Actions)

- 每个 workflow 在 `paths` 匹配其 Dockerfile 或关联脚本时触发
- `work-image.yml` 使用 `ubuntu-22.04` runner（其他均为 `ubuntu-latest`）
- `work-cuda-image.yml` 使用 `DOCKER_BUILDKIT=0` 禁用 BuildKit
- 所有 workflow 在 actions/checkout@v1 上构建（注意 v1 而非 v4）
- Docker secrets 使用 `secrets.DOCKERHUB_USERNAME` 和 `secrets.DOCKERHUB_PASSWORD`
- `work-image.yml`、`work-cuda-image.yml` 通过 `pr-mpt/actions-commit-hash@v2` 获取短 commit hash 作为标签
- 标签策略：`latest` + `基础版本` + `基础版本-短commit`

## 公共构建工具链（builder0 阶段）

除 `derp.Dockerfile`、`exit-node.Dockerfile`、`socks-node.Dockerfile`、`wireguard.Dockerfile`、`test.Dockerfile` 外，其他 Dockerfile 共享 builder0 构建阶段：

- **Emacs**: 从源码构建，`aeadaf7748` commit（work 系列），含 `--with-native-compilation` `--with-tree-sitter`
- **Node.js 22.19.0** (work 系列): LSP 服务器、claude-code、codex 等全局安装
- **CMake 4.1.0** (work 系列)
- **GDB 16.3**: 从源码构建，带 `--with-python=/usr/bin/python3`
- **llvm/clang-21 工具链**: `clangd`、`clang-format`、`clang-tidy`、`lldb` 等
- **其他工具**: ripgrep、fd-find、jq、shfmt、git-lfs、rust-analyzer、mosh-server

## apt-get 配置

`99-apt-get-settings` 文件全局禁用升级和推荐安装：
```
APT::Get::Upgrade "false";
APT::Install-Recommends "false";
```

## 启动脚本 (scripts/start.sh)

容器入口点，按顺序：
1. 生成 SSH host keys
2. 启动 sshd（前台但后台执行）
3. 开放 `/etc/hosts` 写入权限 (`chmod 666`)
4. 启动 clash（从 `/clash_config/` 加载配置）
5. 启动 tailscaled
6. 通过 `tailscale up` 认证
7. 等待 tailscaled 退出

环境变量（尾端网络）：
- `TAILSCALE_AUTH_KEY` - 认证密钥
- `TAILSCALE_HOSTNAME` - 节点主机名
- `TAILSCALE_SERVER` - 可选的自定义登录服务器
- `TAILSCALE_STATE_ARG` - tailscaled 状态参数

## Tailscale 节点类型

- **DERP 中继** (`derp.Dockerfile`): 用 `--tun=userspace-networking` 运行，自签名证书
- **出口节点** (`exit-node.Dockerfile`): `--advertise-exit-node`，路由 `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`
- **SOCKS5 代理** (`socks-node.Dockerfile`): `--socks5-server=0.0.0.0:1055`，用户态网络
- **WireGuard** (`wireguard.Dockerfile`): 纯 WireGuard 隧道，使用 `wg-quick up wg0`

## 架构约束

- **work-cuda.Dockerfile: 基于 `nvidia/cuda:13.2.1-devel-ubuntu24.04`，clang-18 + clang-format/clang-tidy/lldb/clangd 为 clang-21**（旧版 clang 做编译器，新版做工具），含网络维护工具（vim, zstd, net-tools, traceroute, mtr, dnsutils, tcpdump, iftop, nload, nethogs, nmap, iperf3, vnstat, wireshark, autossh, fzf）
- **explore.Dockerfile 完全独立**: 使用不同的 tree-sitter version、Emacs 29 branch、更老的工具版本
- **derp.Dockerfile 使用 `golang:alpine`**: 编译 tailscale 组件为二进制后用 alpine 运行
- **work系列 builder0 构建 Emacs 后不清除 `/opt/emacs`**（work.Dockerfile），而 work-cuda 执行 `rm -r /opt/emacs` 节省空间

## 运行时端口

- clash: SOCKS5/HTTP 代理端口按 clash config 配置
- SSH: 22
- DERP: 443 (TLS), 80 (HTTP STUN)
- SOCKS5 代理: 1055
- tailscaled: 标准 Tailscale 端口

## Home 目录样式

- `home-work/` 和 `home-explore/` 通过 run.sh 中的 volume 挂载到容器内用户家目录
- `.bashrc` 配置：24-bit color、vterm/EAT 集成、CUDA 路径、ulimit 65535
- `.gitconfig`：http/https 代理走 `socks5h://127.0.0.1:7891`（clash 默认）

## Bazel 相关辅助

`scripts/legalize_compile_commands.sh` 用于 Bazel 项目生成 `compile_commands.json` 的清理脚本。仅当仓库处于 Bazel root（有 WORKSPACE 文件）时可用。
