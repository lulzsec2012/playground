# Playground

Containerized development environments for AI/compiler work.

## Quick Links

| 目录 | 用途 |
|:-----|:------|
| `scripts/docker/` | Docker 工作容器管理 |
| `scripts/proxy/` | 代理服务（免费节点 + Mullvad）|
| `scripts/opencode/` | OpenCode 配置 + LLM Router |
| `scripts/langfuse/` | LLM Token 消耗统计 |
| `scripts/tailscale/` | Tailscale 节点部署 |
| `scripts/gitea/` | Gitea 代码托管 |
| `scripts/mixapi/` | MixAPI LLM 代理 |
| `scripts/obsidian/` | Obsidian 笔记同步 |
| `scripts/fileserver/` | 文件服务器 |
| `scripts/data/` | 敏感配置（gitignored）|

---

## 目录结构

```
scripts/
├── data/                      # 敏感配置 (gitignored)
│   ├── vpn.cfg                # Tailscale/Mullvad 账号
│   ├── env.cfg                # API Keys
│   └── ssh_keys.cfg           # SSH 公钥
│
├── docker/                    # Docker 容器管理
│   ├── work-server.sh         # 多实例容器管理 (source me)
│   ├── home-config/           # 容器 HOME 配置模板
│   └── setup-docker-mirror.sh # Docker 镜像加速器
│
├── proxy/                     # 代理服务
│   ├── bin/proxy-deploy       # 一键部署（免费节点 + Mullvad + Dashboard）
│   ├── config/                # 路由规则配置
│   └── lib/                   # 转换脚本
│
├── opencode/                  # OpenCode 配置 (git submodule)
│   ├── scripts/llm-router.py  # LLM Router（自动选择最优后端）
│   ├── scripts/llm-router-mcp.py  # MCP 包装器（随 opencode 启动）
│   ├── single/                # 单实例配置
│   └── multi/                 # 多 profile 配置
│
├── langfuse/                  # Token 消耗统计
│   ├── langfuse-lite.py       # 轻量统计服务（Python，无依赖）
│   ├── deploy.sh              # 部署脚本
│   └── docker-compose.yml     # 完整版 Langfuse
│
├── tailscale/                 # Tailscale 部署
│   └── deploy-tailscale.sh    # 基础/出口/子网路由器
│
├── gitea/                     # Gitea 代码托管
│   ├── deploy.sh
│   └── docker-compose.yml
│
├── mixapi/                    # MixAPI LLM 代理
│   ├── setup.sh               # Docker 部署
│   └── lib/                   # 管理脚本
│
├── obsidian/                  # Obsidian 笔记
│   ├── parts/deploy-couchdb.sh # LiveSync 服务端
│   └── parts/install.sh       # CLI 安装
│
├── fileserver/                # 文件服务器
│   ├── server/                # 服务端（ECS）
│   └── client/                # 客户端（CLI 工具）
│
├── tools/                     # 辅助工具
├── emacs/                     # Emacs 安装
├── hermes/                    # Hermes 工具箱
├── pesudo/                    # sudo 审计
├── iptv/                      # IPTV 工具
└── nginx/                     # Nginx 配置
```

---

## 端口占用

### Host 端口

| 端口 | 服务 | 容器 | 说明 |
|:----:|:-----|:-----|:------|
| 222 | SSH | gitea | Gitea SSH |
| 2221 | SSH | ubuntu-lite | 轻量容器 |
| 2222 | SSH | work-server-default | 默认工作容器 |
| 2225 | SSH | work-server-dev | 开发容器 |
| 1081 | — | ubuntu-lite | 备用 |
| 9090 | — | ubuntu-lite | 备用 |
| **3020** | **Web** | **gitea** | **Gitea Web UI** |
| 3000 | Web | (保留) | MixAPI / 旧版 |

### 容器内端口（work-server 内部使用）

| 端口 | 服务 | 启动方式 | 说明 |
|:----:|:------|:--------|:------|
| **1080** | **Proxy** | `proxy-deploy` | SOCKS5+HTTP 代理 |
| **9091** | **Dashboard** | `proxy-deploy` | Clash Dashboard |
| **8000** | **LLM Router** | 随 opencode 启动 | 自动路由到最优后端 |
| **8001** | **vLLM** | `vllm_deploy` | gemma4-26b-fp8 |
| **8002** | **vLLM** | `vllm_deploy` | qwen3.6-27b |
| **8003** | **vLLM** | `vllm_deploy` | qwen3-coder-next-fp8 |
| **3010** | **Langfuse Lite** | `scripts/langfuse/langfuse-lite.py` | Token 统计 |

> **端口冲突规则**: 新服务选端口时，先在 README 确认是否已被占用。
> 自定义端口优先使用 `30xx` 段（工具类）或 `80xx` 段（开发类）。

---

## 常用命令速查

```bash
# ── Docker 容器管理 ──
source scripts/docker/work-server.sh
work-server-ls                    # 列出所有实例
work-server default               # 启动默认容器 (2222)
work-server-exec default          # 直接进入容器

# ── 代理 ──
proxy-deploy                      # 完整部署（免费节点 + Mullvad + Dashboard）
proxy-deploy --status             # 查看状态
proxy-deploy --stop               # 停止

# ── OpenCode ──
opencode-D                         # 启动（自动启动 LLM Router）
opencode-C                         # 连接

# ── Token 统计 ──
python3 scripts/langfuse/langfuse-lite.py --daemon   # 启动
python3 scripts/langfuse/langfuse-lite.py --query    # 查询
python3 scripts/langfuse/langfuse-lite.py --query-detail

# ── Gitea ──
bash scripts/gitea/deploy.sh up    # 启动（:3020）
bash scripts/gitea/deploy.sh logs  # 日志

# ── Tailscale ──
bash scripts/tailscale/deploy-tailscale.sh basic -n my-node

# ── Obsidian LiveSync ──
bash scripts/obsidian/parts/deploy-couchdb.sh --host 62.234.69.194

# ── 文件服务器 ──
fs-up /path/to/file /remote/dir   # 上传
fs-dl /remote/file ./             # 下载
```

---

## 数据安全

| 路径 | 内容 | gitignore |
|:-----|:-----|:---------:|
| `scripts/data/` | VPN 账号、API Keys、SSH 公钥 | ✅ |
| `scripts/proxy/data/` | 代理配置、Mullvad WireGuard 私钥 | ✅ |
| `scripts/proxy/config.yaml` | 免费代理节点 | ✅ |
| `scripts/docker/data/` | 旧版敏感配置 | ✅ |

---

## Image

`lulzsec2012/work-cuda-dev:cuda13.2-ubuntu24.04`

Built from `lulzsec2012/docker` repo via GitHub Actions.
