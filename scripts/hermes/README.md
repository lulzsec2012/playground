# Hermes Agent — 阿里云部署

## 目录结构

```
playground/scripts/hermes/
├── install_hermes.sh    # 安装/重装 Hermes Agent
├── setup_channels.sh    # 配置聊天通道（微信/飞书）
└── README.md            # 本文件
```

## 快速开始

### 1. 安装 Hermes

```bash
bash ~/playground/scripts/hermes/install_hermes.sh
```

脚本会自动完成：
- 安装 uv 包管理器
- 配置 pip/npm/uv 镜像源（清华源）
- 克隆 NousResearch/hermes-agent 仓库
- 创建 Python 3.11 venv 并安装依赖
- 配置环境变量 PATH

### 2. 配置聊天通道

```bash
bash ~/playground/scripts/hermes/setup_channels.sh
```

按引导提示扫码登录微信 / 飞书。

## 网关管理（systemd 用户服务）

网关已安装为 systemd 用户服务，**退出 SSH 后不会中断**。

| 命令 | 说明 |
|---|---|
| `systemctl --user status hermes-gateway` | 查看运行状态 |
| `systemctl --user start hermes-gateway` | 启动网关 |
| `systemctl --user stop hermes-gateway` | 停止网关 |
| `systemctl --user restart hermes-gateway` | 重启网关 |
| `journalctl --user -u hermes-gateway -f` | 查看实时日志 |

## 配置信息

### 模型配置 (`~/.hermes/config.yaml`)

- **Provider**: custom (兼容 DeepSeek API)
- **Base URL**: `https://api.deepseek.com/v1`
- **默认模型**: `deepseek-v4-flash`
- **备选模型**: `deepseek-v4-pro`

### 环境变量 (`~/.hermes/.env`)

- `OPENAI_API_KEY` — DeepSeek API 密钥（兼容 OpenAI SDK）
- `WEIXIN_ALLOW_ALL_USERS=true` — 允许所有微信用户发送消息

### 安装路径

- Hermes 主目录: `/opt/hermes/hermes-agent/`
- Python 虚拟环境: `/opt/hermes/hermes-agent/venv/`
- 二进制路径: `/opt/hermes/hermes-agent/venv/bin/hermes`
- 用户配置: `~/.hermes/` → 指向 `/opt/hermes/hermes-agent/`

## 常用命令

```bash
# 查看 hermes 版本
hermes --version

# CLI 对话（仅命令行测试用，实际走微信）
hermes chat

# 重装后重新登录微信
hermes gateway setup

# 重启网关服务
systemctl --user restart hermes-gateway
```

## 注意事项

1. **SSH 退出后服务不中断** — 已配置 `loginctl enable-linger`，systemd 用户服务在用户注销后继续运行
2. **微信登录** — 首次配置需扫码，后续重启网关不需要重新扫码
3. **系统重启** — 服务器重启后网关会自动拉起（systemd enabled）
4. **重装升级** — `install_hermes.sh` 支持断点续装，已完成的步骤自动跳过
5. **国内网络** — 已配置清华 PyPI 镜像和 npmmirror.com，无需代理
