# 文件服务器（File Server）

基于阿里云 ECS + Tailscale + Filebrowser + Nginx 的分布式文件管理工具。
内网走 Tailscale HTTP API，公网走 SSH，仅暴露 SSH 端口到公网。

---

## 目录结构

```
scripts/fileserver/
├── .gitignore                        # 忽略 fileserver.conf
├── server/                          # 服务端（在 ECS 上部署）
│   ├── deploy-server.sh             # 一键部署脚本（Filebrowser + Nginx site）
│   ├── deploy-tailscale.sh          # Tailscale 原生节点部署脚本
│   ├── fs-monitor.sh                # 服务端健康监控脚本
│   ├── fs-share-helper.sh           # 分享管理脚本（通过 SSH 调用）
│   ├── fs-share-cleanup.sh          # 清理过期分享 + 临时用户（crontab 每 5min）
│   ├── create-temp-user.sh          # 创建临时 Filebrowser 用户
│   ├── filebrowser-site.conf.template  # Nginx 站点配置模板
│
├── client/                          # 客户端（在开发机上使用）
│   ├── fileserver.conf.TEMPLATE     # 配置模板（复制后修改）
│   ├── fileserver.conf              # 本地配置（已 gitignore）
│   ├── fs-up                        # 上传文件/目录
│   ├── fs-dl                        # 下载文件/目录
│   ├── fs-ls                        # 列出文件
│   ├── fs-share                     # 创建/列表/删除分享链接
│   ├── fs-rm                        # 删除文件或目录
│   ├── fs-mv                        # 移动/重命名
│   ├── fs-cp                        # 复制
│   ├── fs-df                        # 磁盘用量查看
│   ├── fs-health                    # 连接健康检查
│   ├── fs-config                    # 配置查看/编辑
│   ├── fs-temp-user                 # 创建临时用户（Tailscale SSH）
│   ├── fs-lib.sh                    # 公共函数库
│   └── install-path.sh              # 注入 PATH 到 shell 配置
│
└── README.md                        # ← 本文件
```

---

## 架构

```
                    ┌──────────────────┐
                    │   开发机 (客户端)  │
                    │                  │
                    │  fs-up / fs-dl   │
                    │  fs-ls / fs-share│
                    │         │        │
                    │   自动检测模式    │
                    │   ┌────┴────┐   │
                    │   ▼         ▼   │
                    │ Tailscale   SSH │
                    └───┼─────────┼───┘
                        │         │
           Tailscale  ──┤         │
           加密隧道      │         │ SSH 加密
                        │         │
              ┌─────────▼─────────▼──┐
              │    阿里云 ECS 服务器   │
              │                      │
              │  Nginx :8080         │
              │    └→ Filebrowser    │
              │                      │
              │  SSH daemon :22      │
              │    ├→ rsync/scp      │
              │    └→ fs-share-helper│
              │                      │
              │  存储: /data/files/   │
              └──────────────────────┘
```

### 两种工作模式

| 场景 | 模式 | 通道 | 条件 |
|------|------|------|------|
| 在 Tailscale 内网 | Tailscale 模式 | HTTP API（Tailscale 加密） | 本地已连 Tailscale |
| 在公网 / 无 Tailscale | SSH 模式 | SSH + rsync | 服务器 SSH 端口可达 + SSH key |

脚本自动检测当前环境，用户无感切换。

---

## 前置条件

- **阿里云 ECS**：一台有公网 IP 的 Linux 服务器（Ubuntu 22.04+）
- **SSH 密钥**：本地能通过 SSH key 登录 ECS（`ssh lzlu@<host>`）
- **Tailscale**（可选）：ECS 和开发机上都安装了 Tailscale，用于内网高速传输
- **本地环境**：macOS / Linux，有 `bash`、`curl`、`rsync`

---

## 快速开始

### 第一步：在 ECS 上安装 Nginx

```bash
ssh lzlu@<ecs-ip>
cd /path/to/playground/scripts/nginx/
bash install-nginx.sh
```

### 第二步：在 ECS 上部署文件服务

```bash
cd /path/to/playground/scripts/fileserver/server/
bash deploy-server.sh

# 输出示例:
# ✅ Filebrowser 已启动 (127.0.0.1:8081)
# 🔑 初始密码: aB3xK9mNpQ2wR7yZ
```

脚本会自动完成：下载 Filebrowser → 创建系统用户 → 注册 systemd 服务 → 配置 Nginx 站点 → 安装分享管理脚本。

### 第三步：配置本地开发机

```bash
cd /path/to/playground/scripts/fileserver/client/

# 生成配置
cp fileserver.conf.TEMPLATE fileserver.conf
# 编辑 fileserver.conf，填入:
#   - FS_USER / FS_PASS        (Filebrowser 登录凭据)
#   - FS_SSH_HOST / FS_SSH_PORT / FS_SSH_USER  (SSH 连接信息)

# 注入 PATH（只需执行一次）
bash install-path.sh

# 重新加载 shell 配置
source ~/.zshrc   # 或 source ~/.bashrc
```

### 第四步：开始使用

```bash
# 上传文件
fs-up ./model.pt /experiments/exp-001/

# 上传整个目录
fs-up ./logs/

# 列出文件
fs-ls /experiments/

# 下载文件
fs-dl /experiments/exp-001/model.pt ./

# 下载整个目录
fs-dl /experiments/

# 公开分享（生成公网链接）
fs-share /experiments/model.pt

# 密码分享
fs-share -p /experiments/report.pdf
```

---

## 命令参考

### fs-up — 上传

```bash
fs-up <本地路径> [远程目录]

# 参数:
#   src       本地文件或目录（必填）
#   dst_dir   远程目标目录（可选，默认 /）
```

**示例**：
```bash
fs-up ./checkpoints/model.pt /experiments/exp-001/
fs-up ./logs/
```

### fs-dl — 下载

```bash
fs-dl <远程路径> [本地目录]

# 参数:
#   src       远程文件或目录（必填）
#   dst_dir   本地目标目录（可选，默认 .）
```

**示例**：
```bash
fs-dl /experiments/exp-001/model.pt ./
fs-dl /experiments/              # 目录递归下载（双模式支持）
```

### fs-ls — 列表

```bash
fs-ls [远程目录]

# 参数:
#   path      远程目录路径（可选，默认 /）
```

**示例**：
```bash
fs-ls
fs-ls /experiments/
```

**输出格式**：
```
  权限    大小      修改日期           名称
  drw-   4KB     2026-05-14       experiments/
  -rw-   2GB     2026-05-13       dataset.zip
  —— 总计: 2 项, 2.0GB ——
```

### fs-share — 分享

```bash
fs-share [-p] <远程路径>
fs-share --list
fs-share --delete <share-id>

# 参数:
#   -p        启用密码保护（可选）
#   --list    列出所有活跃分享
#   --delete  删除指定分享
#   path      远程文件或目录（必填）
```

**示例**：
```bash
# 公开分享
fs-share /experiments/model.pt
# 输出: http://47.xxx.xxx.xxx:8080/s/aB3xK9mN

# 密码分享
fs-share -p /experiments/report.pdf
# 输出:
#   http://47.xxx.xxx.xxx:8080/s/xYz7pQ2w
#   Password: kR8mNp3Q

# 查看活跃分享
fs-share --list

# 删除分享
fs-share --delete s1234567890
```

> 分享链接通过 `/s/{share-id}` 直连 Nginx，不经过 Filebrowser，下载速度更快。

### fs-rm — 删除

```bash
fs-rm [-r] <远程路径>

# 参数:
#   -r        递归删除目录及其内容（可选）
#   path      远程文件或目录（必填）
```

**示例**：
```bash
fs-rm /experiments/old-model.pt
fs-rm -r /experiments/archive/         # 递归删除目录
```

> 注意：双模式均支持递归删除。Tailscale 模式下目录非空会自动回退到 SSH 删除。

### fs-mv — 移动/重命名

```bash
fs-mv <远程源路径> <远程目标路径>

# 参数:
#   src      远程源文件或目录（必填）
#   dst      远程目标路径（必填）
```

**示例**：
```bash
fs-mv /experiments/model.pt /experiments/archive/model.pt
fs-mv /experiments/old-name/ /experiments/new-name/   # 重命名目录
```

> 双模式支持。Tailscale 模式使用 Filebrowser rename API，失败自动 SSH 回退。

### fs-cp — 复制

```bash
fs-cp <远程源路径> <远程目标路径>

# 参数:
#   src      远程源文件或目录（必填）
#   dst      远程目标路径（必填）
```

**示例**：
```bash
fs-cp /experiments/model.pt /experiments/backup/model.pt
fs-cp /experiments/ /experiments/backup/   # 目录递归复制
```

> 双模式支持。Tailscale 模式下 Filebrowser 无原生复制 API，自动 SSH 回退。

### fs-df — 磁盘用量

```bash
fs-df
```

**示例**：
```bash
fs-df
# 输出:
#   分区使用:
#   Filesystem      Size  Used Avail Use% Mounted on
#   /dev/vda3        40G   16G   22G  42% /
#
#   文件总大小:
#   24K	/data/files
```

> 通过 SSH 查看服务器分区使用和文件总大小。

### fs-temp-user — 临时用户

在 Tailscale 网络中创建自动过期的 Filebrowser 用户（用于临时分享访问权限）。

```bash
fs-temp-user [ttl]

# 参数:
#   ttl      有效期（可选，默认 1h）
#            格式: 30m, 2h, 8h, 24h
```

**要求**：本机已接入 Tailscale，能通过 SSH 访问 `fileserver` 节点。

**示例**：
```bash
# 创建 30 分钟有效的临时用户
FS_HOST=fileserver FS_SSH_USER=lzlu bash fs-temp-user 30m

# 输出:
#   URL:      http://fileserver:8080/login
#   Username: fs-1778785017
#   Password: 418a22fa4008b4e44c9033d7
#   Expires:  30m
```

> 凭据通过 Tailscale SSH 加密传输，不会泄漏公网 IP。
> 临时用户有只读权限（可下载、可分享，不可增删改）。
> 到期后由 crontab（每 5 分钟）自动清理。

---

## 数据安全

| 措施 | 说明 |
|------|------|
| **凭据文件外移** | 密码等敏感文件存储在 `/data/etc/`（Filebrowser document root 之外），Web UI 不可见 |
| **临时用户** | `fs-temp-user` 生成可过期密码，到期自动清理 |
| **登录预填** | Filebrowser 登录页自动填 `admin` 用户名，减少输入 |

---

## 安全说明

| 项目 | 说明 |
|------|------|
| **公网暴露** | 管理操作仅需 SSH 端口（22）；分享下载需开放 Nginx 8080 的 `/s/` 路径到公网 |
| **传输加密** | 内网走 Tailscale 加密隧道；公网走 SSH 加密 |
| **认证方式** | HTTP API 模式使用 Filebrowser session token；SSH 模式使用 SSH key |
| **分享保护** | 密码分享基于 Nginx `auth_basic`，独立于 Filebrowser |
| **配置安全** | `fileserver.conf` 已 gitignored，不会误提交 |
| **凭据存储** | 初始密码写入服务器本地文件，不留终端日志 |

---

## 常见问题

### SSH 连接失败

```bash
ssh -v lzlu@<host> -p <port>
```

检查：
- SSH key 是否已添加到 ECS 的 `~/.ssh/authorized_keys`
- ECS 安全组是否允许对应端口的入站流量
- 是否配置了正确的 `FS_SSH_HOST` / `FS_SSH_PORT`

### Tailscale 模式不可用

```bash
tailscale status          # 检查 Tailscale 是否运行
curl http://fileserver:8080/api/health  # 检查可达性
```

如果 Tailscale 不可用，脚本会自动降级到 SSH 模式，前提是 `fileserver.conf` 中已配置 SSH 信息。

### 文件上传/下载很慢

- Tailscale 模式：检查 Tailscale 连接质量（`tailscale ping fileserver`）
- SSH 模式：大文件默认走 rsync，支持断点续传；如果网络差可以加 `--partial` 参数

### 如何删除分享？

使用 `fs-share --delete <share-id>` 命令删除，或 `fs-share --list` 查看所有活跃分享：

```bash
fs-share --list
fs-share --delete s1234567890
```

也可以通过 SSH 直接操作：

```bash
ssh lzlu@<host> sudo /usr/local/bin/fs-share-helper delete <share-id>
```

---

## 相关文档

- `client/fileserver.conf.TEMPLATE` — 客户端配置模板
- `server/deploy-server.sh` — 服务端部署脚本
