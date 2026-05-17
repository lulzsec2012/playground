# Pesudo — 安全的 sudo 替代

通过微信 OTP 授权执行 sudo，防止大语言模型 agent 看到 sudo 密码明文。
设计文档: [`DESIGN.md`](DESIGN.md)

---

## 目录结构

```
scripts/pesudo/
├── DESIGN.md                        # 架构设计与安全分析（927行）
├── PLAN.md                          # 实施计划（8 Phase）
├── README.md                        # ← 本文件
├── SKILL.md                         # OpenCode skill（引导 agent 使用 pesudo）
├── pesudo.sh                        # 统一管理入口（300行）
├── register.sh                      # sudo → pesudo 别名安装
│
├── client/
│   ├── pesudo                       # ★ 主命令：sudo 替代（130行）
│   ├── pesudo-lib.sh                #   公共库：服务器发现 / 解密 / HTTP（330行）
│   ├── pesudo-register              # ★ 集中注册脚本（280行）
│   ├── pesudo.conf.TEMPLATE         #   配置模板
│   └── install.sh                   #   客户端安装器
│
├── server/
│   ├── server.py                    # ★ FastAPI 授权服务器（350行）
│   ├── store.py                     #   AES-256-GCM 加密凭据库（90行）
│   ├── crypto.py                    #   动态凭据协议（120行）
│   ├── hermes_sender.py             #   Hermes / iLink Bot 微信桥（180行）
│   ├── deploy.sh                    #   SSH/rsync 远程部署
│   ├── pesudo-server.service        #   systemd 用户服务单元
│   ├── requirements.txt             #   依赖：fastapi, cryptography, python-dotenv
│   └── .env.TEMPLATE                #   环境变量模板
│
├── lib/
│   └── lib-format.sh                #   彩色日志输出（复用 mixapi 风格）
│
└── tests/
    ├── conftest.py                  #   pytest fixtures
    ├── test_server.py               #   15 用例：register / request / verify / rate limit / audit
    ├── test_crypto.py               #   6 用例：加解密 / 密文互异 / 篡改检测 / 过期
    ├── test_phase_4.sh              #   集成测试：服务器发现 / decrypt / expect
    ├── test_phase_5.sh              #   集成测试：注册流程 / 多机 / 批量
    ├── test_phase_6.sh              #   集成测试：Hermes 降级 / 消息格式化
    └── test_phase_7.sh              #   集成测试：部署 / 别名 / 入口命令
```

---

## 架构

```
┌──────────────────────────────────┐      Tailscale HTTPS     ┌─────────────────────────────────────┐
│  客户端机器 A (tailnet 内)         │ ◄──────────────────────► │  授权服务器 (阿里云 ECS)              │
│                                  │                          │                                     │
│  ┌─────────────────┐             │    /v1/register           │  ┌──────────────────────────────┐   │
│  │ pesudo          │             │    /v1/auth/request       │  │ server.py :8643              │   │
│  │  ↓ decrypt      │◄────────────┤    /v1/auth/verify        │  │  ├── CredentialStore         │   │
│  │  ↓ expect sudo  │             │    /v1/machines           │  │  │   (AES-256-GCM)           │   │
│  └─────────────────┘             │                          │  │  ├── OneTimeCredential       │   │
│                                  │                          │  │  │   (随机 nonce + key)      │   │
│  ┌─────────────────┐             │                          │  │  ├── RateLimiter            │   │
│  │ pesudo-register │────SSH─────►│                          │  │  └── AuditLogger            │   │
│  │  (SSH 验证密码)  │             │                          │  └──────────────────────────────┘   │
│  └─────────────────┘             │                          │                                     │
│                                  │                          │  ┌──────────────────────────────┐   │
│  ~/.pesudo/                      │                          │  │ hermes_sender.py             │   │
│  ├── config                      │                          │  │  ├── iLink Bot API (微信)    │   │
│  └── credentials.json            │                          │  │  └── OpenAI compat API 备选  │   │
│                                  │                          │  └───────────────┬──────────────┘   │
│  /usr/local/bin/                 │                          │                  ↕                  │
│  ├── pesudo                      │                          │            用户微信                  │
│  └── pesudo-register             │                          └─────────────────────────────────────┘
└──────────────────────────────────┘
```

### 组件职责

| 组件 | 部署位置 | 职责 |
|------|----------|------|
| `server.py` | 授权服务器（阿里云 ECS） | FastAPI 应用，处理注册/授权/验证/审计/频率限制 |
| `store.py` | 同 server | AES-256-GCM 加密存储机器凭据（Fernet 密钥加密敏感数据） |
| `crypto.py` | 同 server + 客户端 | 动态凭据协议：每次验证返回不同加密密码（随机 nonce + session_key） |
| `hermes_sender.py` | 同 server | OTP 通过 WeChat 发送给用户（优先 iLink Bot API，备选 Hermes OpenAI API） |
| `pesudo` | 客户端机器 | sudo 替代命令：decrypt + expect + sudo -S |
| `pesudo-register` | 任意客户端 | 集中注册：SSH 验证管理员身份 → 验证目标机器 sudo 密码 → 注册 |
| `pesudo-lib.sh` | 客户端 | 公共库：Tailscale 自动发现、AES-GCM 解密、HTTP 封装 |

---

## 用户设计

| "用户" | 角色 | 说明 |
|--------|------|------|
| **管理员** | 操作员 | 拥有所有机器的所有权，通过 SSH 密码验证身份 |
| **大模型 agent** | 受限执行者 | 可执行 `pesudo` 命令，但无法看到密码，需等待 OTP 确认 |
| **已注册机器** | 被管理节点 | 每个节点有 machine_id + 加密凭据，通过 `pesudo-register` 加入系统 |

### 信任模型

| 信任等级 | 实体 | 说明 |
|----------|------|------|
| ✅ **完全信任** | 用户本人 | 拥有机器所有权，SSH 密码验证管理员身份 |
| ✅ **信任** | Tailscale 网络 | WireGuard 加密，tailnet ACL 控制 |
| ✅ **信任** | 授权服务器节点 | 运行在阿里云 ECS，tailnet 内可达 |
| ⚠️ **部分信任** | 已注册机器 | 可发起授权请求，但每次需人类 OTP 确认 |
| ❌ **不可信** | 大模型 agent 进程 | 可读取终端输出、环境变量、磁盘文件 |
| ❌ **不可信** | 外部网络 | 但 Tailscale 已提供传输层加密 |

---

## 协议流程

### 集中式注册协议

注册是集中式的。从任意 tailnet 节点为其他节点注册，管理员身份通过阿里云 ECS SSH 密码验证。

```
注册者机器                        授权服务器                    目标机器
    │                                │                            │
    │  1. SSH user@ecs-host          │                            │
    │     验证管理员身份              │                            │
    │                                │                            │
    │  2. read -s "sudo密码"         │                            │
    │     (键盘输入，不回显)          │                            │
    │                                │                            │
    │  3. SSH user@target-host       │                            │
    │     echo $password | sudo -S   │                            │
    │     (验证密码正确性)            │                            │
    │                                │                            │
    │  4. POST /v1/register ────────►│                            │
    │     machine_id                 │                            │
    │     hostname                   │                            │
    │     tailscale_ip               │                            │
    │     encrypted_pass (AES)       │                            │
    │                                │                            │
    │  ◄──── 201 Created ────────────│                            │
    │                                │                            │
    │  5. 可选: SCP ~/.pesudo/config │                            │
    │     到目标机器                 │                            │
```

### 授权协议

```
客户端 pesudo                   授权服务器 (8643)              用户微信
    │                                │                            │
    │  1. POST /v1/auth/request ────►│                            │
    │     { machine_id, command }    │                            │
    │                                │  2. 生成 6 位 OTP          │
    │                                │     写入哈希 → store       │
    │                                │    记录审计日志            │
    │                                │                            │
    │  ◄── { request_id } ──────────│  3. 发送 OTP ─────────────►│
    │                                │     (iLink Bot / Hermes)   │
    │                                │                            │
    │  4. read -s "OTP"              │                            │
    │     (键盘输入，不回显)          │                            │
    │                                │                            │
    │  5. POST /v1/auth/verify ─────►│                            │
    │     { request_id, otp }        │                            │
    │                                │  6. 验证 OTP 哈希          │
    │                                │  7. 从 store 取加密凭据    │
    │                                │  8. 构建动态凭据            │
    │                                │     (随机 nonce + key)     │
    │                                │                            │
    │  ◄── { credential } ──────────│                            │
    │       ciphertext               │                            │
    │       session_key              │                            │
    │       expires_at               │                            │
    │                                │                            │
    │  9. AES-GCM 解密               │                            │
    │     python3 -c "..."           │                            │
    │                                │                            │
    │  10. expect sudo -S command    │                            │
    │      (密码在进程内存，用完即弃)  │                            │
```

### 动态凭据协议

每次 `verify` 请求返回的凭据都是唯一的——即使同一个密码被授权两次，加密结果也不相同。

```
┌──── 凭据请求 ──────────────────────────────────────────┐
│                                                         │
│  server.py:                                              │
│    1. session_key = Fernet.generate_key()   (32B 随机)   │
│    2. nonce = os.urandom(12)                 (12B 随机)   │
│    3. ciphertext = AES-GCM(                   GCM 密文   │
│         key=session_key,                                │
│         nonce=nonce,                                    │
│         data=sudo_password,                             │
│         aad=request_id)                    绑定 request │
│    4. 返回 { ciphertext, session_key, expires_at }      │
│                                                         │
│  客户端:                                                 │
│    1. python3 -c "解密..."                               │
│    2. password = AES-GCM(                                │
│         key=session_key,                                 │
│         nonce=ciphertext[:12],                           │
│         data=ciphertext[12:],                            │
│         aad=request_id)                    验证绑定      │
│    3. expect <<EOF                                       │
│       spawn sudo -S {command}                            │
│       expect "password:"                                 │
│       send "{password}\r"                                │
│       expect eof                                         │
│       EOF                                                │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 安全设计

### 密钥生命周期

| 密钥 | 位置 | 用途 | 生命周期 |
|------|------|------|----------|
| `PESUDO_MASTER_KEY` | 服务器 .env | 加密凭据库（Fernet） | 部署时生成，不可变 |
| `session_key` | 内存 | 单次动态凭据（AES-GCM） | 每次 verify 重新生成 |
| sudo 密码 | 内存 | expect sudo -S 输入 | 命令执行后释放 |

### 防护措施

| 攻击面 | 防护 |
|--------|------|
| 密码明文存储 | 凭据库 AES-256-GCM 加密，master key 不在磁盘 |
| 密码传输泄露 | Tailscale WireGuard 加密通道 + 凭据每次不同 |
| 重放攻击 | OTP 单次使用、request_id 绑定、凭据过期 (30s) |
| OTP 暴力破解 | 频率限制 (3/min)、OTP 6位数字 (10^6 空间)、自动过期 (180s) |
| 凭据复用 | 每次 verify 返回不同密文（随机 nonce + session_key） |
| 中间人攻击 | Tailscale mTLS + request_id AAD 绑定 |
| 审计追溯 | 所有操作记录 timestamp + machine_id + 结果 |

---

## API 参考

### `GET /v1/health`

健康检查。

```json
// 200 OK
{ "status": "ok", "machines": 3 }
```

### `POST /v1/register`

注册一台机器到授权服务器。

```json
// Body
{ "machine_id": "dev-box-2", "hostname": "dev-box-2",
  "user": "ubuntu", "tailscale_ip": "100.x.x.x",
  "encrypted_pass": "<AES-GCM base64>" }

// 201 Created
{ "status": "ok", "machine_id": "dev-box-2" }
```

### `GET /v1/machines`

列出所有已注册机器。

```json
// 200 OK
{ "machines": [
  { "machine_id": "dev-box-2", "hostname": "dev-box-2",
    "user": "ubuntu", "tailscale_ip": "100.x.x.x",
    "allowed": true, "last_used": 1747334400 }
] }
```

### `POST /v1/auth/request`

发起一次授权请求。服务器生成 OTP 并通过微信发送。

```json
// Body
{ "machine_id": "dev-box-2", "command": "apt install nginx" }

// 200 OK
{ "request_id": "e692d059db6f503e44f9131e9a55ad7c" }
```

### `POST /v1/auth/verify`

验证 OTP 并获取动态凭据。凭据使用随机 session_key 和非对称 nonce 加密，每次不同。

```json
// Body
{ "machine_id": "dev-box-2", "request_id": "e692d059...", "otp": "483921" }

// 200 OK
{ "credential": {
    "ciphertext": "base64...", "session_key": "base64...",
    "expires_at": 1747334580 }
}

// 403 Forbidden (OTP 错误/过期)
{ "error": "OTP mismatch" }
```

---

## 配置参考

### 授权服务器 (`/opt/pesudo/.env`)

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PESUDO_MASTER_KEY` | (必填) | Fernet 对称加密密钥，部署时生成 |
| `PESUDO_PORT` | `8643` | 服务监听端口 |
| `PESUDO_STORE` | `store.json` | 加密凭据库路径 |
| `PESUDO_LOG` | `audit.log` | 审计日志路径 |
| `PESUDO_DEV` | 空 | 设为 `1` 启用开发模式（OTP 输出到 stderr） |
| `HERMES_URL` | `http://localhost:8642/v1` | Hermes OpenAI 兼容 API 地址 |
| `OTP_LENGTH` | `6` | OTP 数字长度 |
| `OTP_EXPIRE_SECONDS` | `180` | OTP 过期时间 |
| `RATE_LIMIT_PER_MINUTE` | `3` | 每机器每分钟最大请求数 |
| `ALIYUN_SSH_USER` | (可选) | 阿里云 ECS SSH 用户名（管理员验证用） |

### 客户端 (`~/.pesudo/config`)

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DISCOVERY_MODE` | `auto` | 服务器发现模式 (`auto` / `manual`) |
| `SERVER_URL` | (自动) | 手动指定时使用，如 `http://auth-server:8643` |

### 注册参数 (`pesudo-register`)

| 选项 | 说明 |
|------|------|
| `user@host` | 注册远程机器（SSH 验证 + 密码验证） |
| 无参数 | 注册本机（仅本地密码验证） |
| `--batch file.txt` | 批量注册（每行一个 `user@host`） |
| `--ssh-port, -p <port>` | 指定 SSH 端口（默认 22） |
| `--no-sshd` | 跳过远程 SSH 配置步骤 |

---

## 部署

### 前置条件

- **授权服务器**: Python 3.10+ · Tailscale 安装 · 阿里云 ECS
- **客户端机器**: `expect` · `curl` · `python3` · Tailscale 安装
- **微信通知**: Hermes Agent 运行在授权服务器上，或 iLink Bot 账号可用

### 授权服务器部署

```bash
# 一键部署到 tailnet 中的节点
cd scripts/pesudo
bash server/deploy.sh auth-server

# 或手动部署
# 1. 同步源码
rsync -az --delete server/ auth-server:/opt/pesudo/
# 2. SSH 登录后安装依赖
ssh auth-server "cd /opt/pesudo && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
# 3. 复制配置
ssh auth-server "cp /opt/pesudo/.env.TEMPLATE /opt/pesudo/.env \
  && sed -i 's|^PESUDO_MASTER_KEY=.*|PESUDO_MASTER_KEY='$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")'|' /opt/pesudo/.env"
# 4. 安装 systemd 服务
scp server/pesudo-server.service auth-server:~/.config/systemd/user/
ssh auth-server "systemctl --user daemon-reload && systemctl --user enable --now pesudo-server"
# 5. 验证
curl -sf http://auth-server:8643/v1/health
```

### 客户端安装

```bash
# Step 1: 安装客户端脚本（复制到 ~/.local/bin/ + 配置 PATH）
bash client/install.sh
source ~/.zshrc

# Step 2: 注册本机 — 注册成功后可选安装 sudo 别名
pesudo-register

# 或注册远程机器
pesudo-register user@host -p 2222

# 验证
pesudo whoami      # 应提示微信授权
```

### 网络连通性

```bash
# 验证 tailnet 内授权服务器可达
ping auth-server              # MagicDNS 解析
curl -sf http://auth-server:8643/v1/health

# 如果 Tailscale 路由不通（如 macOS 特定网络），使用 SSH 隧道
pesudo.sh tunnel user@ecs-host
pesudo.sh status localhost:8643
```

---

## 测试

```bash
# 全部测试
bash pesudo.sh test all

# 按阶段
bash pesudo.sh test 4    # 客户端核心（服务器发现 / 解密 / expect）
bash pesudo.sh test 5    # 注册流程（集中注册 / 多机 / 批量）
bash pesudo.sh test 6    # Hermes 集成（降级 / 消息格式化 / OTP 错误）
bash pesudo.sh test 7    # 部署脚本（dry-run / 别名 / 入口命令）

# Python 单元测试
python3 -m pytest tests/ -v --tb=short
```

测试架构：Python pytest 覆盖协议逻辑（21 用例），bash 测试覆盖集成流程（4 文件）。Hermes 不可用时自动降级为日志，不影响测试。

---

## 开发

### 快速启动开发服务器

```bash
cd scripts/pesudo
export PESUDO_MASTER_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export PESUDO_DEV=1
python3 -m server.server --dev --port 8643
```

开发模式下：
- OTP 输出到服务端 stderr（而不是走微信）
- 凭据库固定到 `/tmp/pesudo_store.json`
- 审计日志固定到 `/tmp/pesudo_audit.log`
- Hermes 连接失败不阻断流程

### 关键文件

| 文件 | 行数 | 核心逻辑 |
|------|------|----------|
| `server/store.py` | 90 行 | `CredentialStore` — AES-256-GCM 加密的 key-value 存储 |
| `server/crypto.py` | 120 行 | `OneTimeCredential` — 动态凭据构建/验证/AAD 绑定 |
| `server/server.py` | 350 行 | FastAPI 路由、OTP 生成/验证、速率限制、审计 |
| `server/hermes_sender.py` | 180 行 | iLink Bot API 封装、会话管理、降级策略 |
| `client/pesudo-lib.sh` | 330 行 | `discover_server` / `decrypt_credential` / `http_post_json` |
| `client/pesudo` | 130 行 | 主命令流：请求 → OTP → 验证 → 解密 → expect |
| `client/pesudo-register` | 280 行 | SSH 身份验证 / 密码验证 / API 注册 |

### 添加新 OTP 通道

继承 `BaseSender` 接口模式：

```python
# server/hermes_sender.py
class HermesSender:
    def send_message(self, to_user, content):
        """发送微信消息。失败时返回 False，不抛异常。"""
    def send_otp(self, machine_id, otp, command):
        """发送 OTP 授权码。"""
    def notify_register(self, machine_id, hostname):
        """新机器注册通知。"""
    def notify_alert(self, machine_id, message):
        """安全告警。"""
```

