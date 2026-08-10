# Project Knowledge

## Server Access

| Name | SSH Command |
|------|-------------|
| Dev container | `ssh <user>@<dev-container-ip>` (or `ssh <user>@<dev-host-ip> -p 2222`) |
| Host | `ssh <user>@<tailscale-host-ip>` (or `ssh <user>@<dev-host-ip>`) |
| ECS | `ssh <user>@<aliyun-ip>` |

> 实际 IP/用户名见 `scripts/data/hosts.cfg`（gitignored，本机已配置）。

## Project Structure

All projects/tools live under `scripts/` as independent subdirectories.
There is NOT a `projects/`, `tools/`, or `apps/` directory — it's always `scripts/<name>/`.

```
scripts/
├── data/            # Sensitive configs (gitignored)
├── docker/          # Docker work-server & container lifecycle
├── emacs/           # Emacs macOS install script
├── fileserver/      # File server (client + server + deploy)
├── gitea/           # Gitea code hosting
├── headscale/       # Self-hosted headscale control plane (replaces tailscale/)
├── hermes/          # Hermes toolkit
├── homeassistant/   # Home Assistant hub
├── iptv/            # IPTV tools
├── langfuse/        # LLM token consumption analytics
├── nginx/           # Nginx config
├── newapi/          # new-api LLM gateway (replaces mixapi/)
├── obsidian/        # Obsidian notes & LiveSync
├── opencode/        # OpenCode config & LLM Router
├── pesudo/          # Sudo replacement with audit
├── proxy/           # Proxy tools (deploy, fetch, health)
├── tools/           # Utility scripts
└── vllm/            # vLLM model deployment
```

New additions go into `scripts/<name>/` with its own README, scripts, and optionally a `register.sh`.

### vLLM 环境隔离注意事项

`scripts/vllm/` 使用 `/workspace/vllm_deploy/.venv/` 独立 Python 环境，**不能复用 `flagos/.venv`**（其 manta/microbt 自定义 PyTorch 后端 hook CUDA，会干扰 vLLM 的 NVML 设备检测）。详见 [`scripts/vllm/AGENTS.md`](file:///workspace/playground/scripts/vllm/AGENTS.md)。

## Docker-in-Docker

The dev container runs Docker via host socket at `/var/run/docker.sock`.
Docker binds paths from the host filesystem, NOT the container filesystem.
Use `/tmp/` for paths that the host Docker daemon must access
(host maps `/home/lulizhi/.docker/tmp/` to container's `/tmp/`).

## Key Config Files

- `scripts/data/ssh_keys.cfg` — public keys → authorized_keys for containers
- `scripts/data/vpn.cfg` — env vars (CLASH_SUBSCRIPTION_URL, TAILSCALE_AUTH_KEY, MULLVAD_ACCOUNT)
- `scripts/docker/home-config/bashrc/*.sh` — combined into .bashrc in order
- `scripts/docker/work-server.sh` — INSTANCES array defines port/image per instance

## Common Operations

### Launch a new instance
```bash
source /workspace/playground/scripts/docker/work-server.sh
work-server test-v1      # port 2223
IP=$(docker inspect $USER-work-server-test-v1 --format "{{.NetworkSettings.IPAddress}}")
ssh $IP                  # or ssh localhost -p 2223
```

### Create a test copy
```bash
rm -rf /tmp/playground-refactor
cd /workspace && git clone playground playground-refactor
# work in /tmp/playground-refactor, replace /workspace/playground when ready
```

## Script Registration

Each `scripts/*/` directory may contain a `register.sh` that registers tools
(PATH/alias/source) into the shell environment. The convention is:

```bash
bash scripts/install.sh              # 全量注册
bash scripts/pesudo/register.sh      # 单目录注册
bash scripts/register.sh --print     # 预览注册内容
```

- Each `register.sh` is **standalone** (detects rc, no shared library)
- Registration files are written to `~/.config/playground/registrations.d/*.sh`
- Your rc file sources the entire directory (one line, idempotent)
- `install.sh` orchestrates all `register.sh` in one pass

This replaces the old `set_alias.sh` / `install-path.sh` convention.

## Users & Groups

- Host/container UID: 6032, GID: 5005 (GroupIP)
- New containers need user created: `useradd -u 6032 -g 5005 -G sudo lulizhi`
- New users have locked accounts (`!` in shadow) — must `passwd -d lulizhi` after creation

## Development Rules

### 1. 新增脚本必须更新 README

`scripts/` 下每新增一个子目录或脚本，必须在 `README.md` 中同步更新：
- 目录结构树中新增条目
- 端口占用表中登记使用的端口
- 常用命令速查中增加用法示例

### 2. 端口占用必须先查 README

新增任何服务前，先去 `README.md` 的**端口占用**章节确认目标端口是否已被使用。
规则：
- Host 端口冲突 → 修改映射端口或停用旧服务
- 容器内端口冲突 → 改用 `30xx`（工具类）或 `80xx`（开发类）段中空闲端口
- 新的端口必须登记到 README 的端口表中
