# Playground

Containerized development environments for AI/compiler work.

## Quick Links

| 目录 | 用途 |
|:-----|:------|
| `scripts/docker/` | Docker 工作容器管理 |
| `scripts/proxy/` | 代理服务（免费节点 + Mullvad）|
| `scripts/opencode/` | OpenCode 配置 + LLM Router |
| `scripts/langfuse/` | LLM Token 消耗统计 |
| `scripts/headscale/` | Headscale 自建控制面（替代 Tailscale 云）|
| `scripts/gitea/` | Gitea 代码托管 |
| `scripts/newapi/` | new-api LLM 网关（替代 MixAPI）|
| `scripts/obsidian/` | Obsidian 笔记同步 |
| `scripts/fileserver/` | 文件服务器 |
| `scripts/homeassistant/` | 智能家居中枢 (Home Assistant) |
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
├── headscale/                 # Headscale 自建控制面
│   ├── install-headscale.sh   # 控制服务器部署（含内置 DERP+STUN）
│   ├── join-client.sh         # 客户端加入脚本
│   ├── deploy-node-container.sh # 容器化节点部署（原 tailscale/ 合并）
│   ├── templates/             # 配置模板（含容器 entrypoint）
│   ├── extra/                 # DERP 参考脚本
│   └── register.sh            # hs-* 命令注册
│
├── gitea/                     # Gitea 代码托管
│   ├── deploy.sh
│   └── docker-compose.yml
│
├── newapi/                    # new-api LLM 网关（替代 MixAPI）
│   ├── deploy-newapi.sh       # Docker 部署
│   └── register.sh            # 管理命令注册
│
├── obsidian/                  # Obsidian 笔记
│   ├── parts/deploy-couchdb.sh # LiveSync 服务端
│   └── parts/install.sh       # CLI 安装
│
├── fileserver/                # 文件服务器
│   ├── server/                # 服务端（ECS）
│   └── client/                # 客户端（CLI 工具）
├── homeassistant/             # 智能家居中枢 (Home Assistant)
│
├── vllm/                      # vLLM 模型部署（deploy/bench/ops）
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
| **8123** | **Web** | **homeassistant** | **Home Assistant UI** |
| 3000 | Web | (保留) | MixAPI / 旧版 |

### 云服务器端口（腾讯云 <tencent-ip>）

| 端口 | 协议 | 服务 | 说明 |
|:----:|:-----|:-----|:------|
| 8443 | TCP | headscale 控制面 + DERP | 自建控制面（替代 Tailscale 云）|
| 3478 | UDP | headscale STUN | NAT 打洞辅助 |
| 443 | TCP | 旧 derper（已停用） | 端口空闲 |

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

# ── Headscale（自建控制面，替代 Tailscale 云）──
bash scripts/headscale/register.sh      # 注册 hs-* 命令
hs-nodes                                # 节点列表（控制面在腾讯云）
hs-keys                                 # 预授权密钥列表
hs-ping <company-ip>                      # tailnet 内 ping
bash scripts/headscale/deploy-node-container.sh basic -n my-node  # 容器化节点

# ── Obsidian LiveSync ──
bash scripts/obsidian/sync/deploy-couchdb.sh --host <tencent-ip>

# ── 文件服务器 ──
fs-up /path/to/file /remote/dir   # 上传
fs-dl /remote/file ./             # 下载

# ── Home Assistant ──
bash scripts/homeassistant/deploy.sh           # 部署/更新
bash scripts/homeassistant/deploy.sh --status  # 查看状态
bash scripts/homeassistant/deploy.sh --logs    # 查看日志
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
