# Pesudo 开发计划

> 逐阶段增量开发，每阶段产出可独立测试的交付物。
> 遵循现有工程模式：`lib-*.sh` 公共库、`mixapi.sh` 风格统一入口、`lib-format.sh` 输出格式。

---

## 目录

1. [开发策略](#1-开发策略)
2. [总体文件清单](#2-总体文件清单)
3. [Phase 1: 授权服务器骨架](#3-phase-1-授权服务器骨架)
4. [Phase 2: 核心 API — 注册与授权](#4-phase-2-核心-api--注册与授权)
5. [Phase 3: 动态凭据协议](#5-phase-3-动态凭据协议)
6. [Phase 4: bash 客户端核心](#6-phase-4-bash-客户端核心)
7. [Phase 5: 集中注册流程](#7-phase-5-集中注册流程)
8. [Phase 6: Hermes 微信集成](#8-phase-6-hermes-微信集成)
9. [Phase 7: 部署脚本](#9-phase-7-部署脚本)
10. [Phase 8: SKILL.md + 收尾](#10-phase-8-skillmd--收尾)
11. [端到端测试场景](#11-端到端测试场景)

---

## 1. 开发策略

### 1.1 核心原则

- **每阶段可独立测试** — 不依赖后续阶段的代码
- **先通后优** — 先实现核心路径，再加固安全
- **测试驱动** — 每个 API 端点先写测试，后实现
- **复用现有模式** — 使用 `lib-format.sh` 格式、`lib-tailnet.sh` 发现

### 1.2 测试策略

| 阶段 | 测试方式 | 依赖 |
|------|----------|------|
| Server API | `pytest` 单元测试 | Python 3.10+ |
| Server API | `curl` 手动验证 | curl |
| Client 脚本 | 本地启动 server → 脚本连 localhost | Python, bash |
| 注册 | SSH 到测试容器验证 | Tailscale SSH |
| 全流程 | server on ECS → client on 开发机 → 微信 | 真实 infra |

### 1.3 测试约定

```bash
# 每个 Phase 完成后执行:
cd scripts/pesudo

# 启动测试服务器（开发模式）
python3 server/server.py --dev --port 8643

# 运行该阶段的测试
bash tests/test_phase_N.sh
```

---

## 2. 总体文件清单

```
scripts/pesudo/
├── DESIGN.md
├── PLAN.md                              ← 本文件
│
├── server/
│   ├── server.py                        # ★ FastAPI 授权服务器
│   ├── store.py                         #   加密凭据库
│   ├── crypto.py                        #   AES-GCM 动态凭据
│   ├── hermes_sender.py                 #   Hermes 微信桥
│   ├── .env.TEMPLATE                    #   服务端配置
│   └── requirements.txt                 #   fastapi, uvicorn, cryptography, httpx
│
├── client/
│   ├── pesudo                           # ★ sudo 替代命令
│   ├── pesudo-register                  # ★ 注册命令
│   ├── pesudo-lib.sh                    #   公共库
│   ├── pesudo.conf.TEMPLATE             #   客户端配置
│   └── install.sh                       #   客户端安装
│
├── pesudo.sh                            # ★ 统一管理入口
├── register.sh                          #   sudo 别名安装
├── SKILL.md                             #   OpenCode skill
│
├── lib/
│   └── lib-format.sh                    #   复用 mixapi 的输出格式
│
└── tests/
    ├── conftest.py                      #   pytest fixtures
    ├── test_server.py                   #   API 单元测试
    ├── test_crypto.py                   #   动态凭据测试
    ├── test_phase_1.sh                  #   Phase 1 集成测试
    ├── test_phase_2.sh                  #   Phase 2 集成测试
    ├── test_phase_3.sh                  #   Phase 3 集成测试
    ├── test_phase_4.sh                  #   Phase 4 集成测试
    ├── test_phase_5.sh                  #   Phase 5 集成测试
    ├── test_phase_6.sh                  #   Phase 6 集成测试
    └── test_flow.sh                     #   E2E 全流程测试
```

---

## 3. Phase 1: 授权服务器骨架

> 目标: 可启动的 FastAPI 服务器，健康检查通过，in-memory OTP 可用。

### 3.1 产出文件

| 文件 | 内容 | 行数参考 |
|------|------|---------|
| `server/requirements.txt` | FastAPI, uvicorn, cryptography, httpx, python-dotenv, pytest | 8 |
| `server/server.py` | FastAPI app, `/v1/health`, 配置加载, 启动入口 | ~80 |
| `server/store.py` | `CredentialStore` 骨架（JSON 文件存储，后续加密） | ~60 |
| `server/crypto.py` | 占位（Phase 3 实现） | ~10 |
| `server/.env.TEMPLATE` | 配置模板 | ~15 |
| `server/deploy.sh` | 占位（Phase 7 实现） | ~10 |
| `tests/test_server.py` | 测试: health, 启动关闭, 配置加载 | ~50 |
| `tests/conftest.py` | pytest fixtures: test client, temp dir | ~30 |

### 3.2 关键设计

```python
# server/server.py — 骨架
from fastapi import FastAPI
app = FastAPI(title="Pesudo Auth Server")

@app.get("/v1/health")
async def health():
    return {"status": "ok", "version": "1.0.0"}

def main():
    import uvicorn
    port = int(os.getenv("PESUDO_PORT", "8643"))
    uvicorn.run(app, host="0.0.0.0", port=port)
```

### 3.3 验收测试

```bash
# 终端 1: 启动服务器
python3 server/server.py --dev --port 8643

# 终端 2:
curl -s http://localhost:8643/v1/health
# 期望: {"status":"ok","version":"1.0.0"}

# pytest (无需启动服务器)
cd scripts/pesudo
python3 -m pytest tests/test_server.py -v
```

### 3.4 依赖

- Python 3.10+, pip
- `pip install -r server/requirements.txt`

---

## 4. Phase 2: 核心 API — 注册与授权

> 目标: `/v1/register`、`/v1/auth/request`、`/v1/auth/verify` 三个端点就绪，in-memory OTP 可用。

### 4.1 产出文件

| 文件 | 变更 |
|------|------|
| `server/store.py` | 完整实现: 加密存储、读取、禁用、列表 |
| `server/server.py` | 添加 POST 注册/请求/验证 三个端点 |

### 4.2 关键设计

**store.py — 加密凭据库**:

```python
from cryptography.fernet import Fernet
import json, os

class CredentialStore:
    def __init__(self, path: str, master_key: str):
        self.path = path
        self.fernet = Fernet(master_key)
        self._machines = self._load()
    
    def _load(self) -> dict:
        """读取加密的 JSON 文件，解密"""
        ...
    def _save(self):
        """加密后写入 JSON 文件"""
        ...
    def add(self, machine_id: str, data: dict): ...
    def get(self, machine_id: str) -> dict | None: ...
    def disable(self, machine_id: str): ...
    def list_all(self) -> list[dict]: ...
```

**server.py — OTP 生成**:

```python
# 内存 OTP 存储 (生产环境可替换为 Redis)
otp_store: dict[str, dict] = {}

@app.post("/v1/auth/request")
async def auth_request(req: AuthRequest):
    """生成 OTP 并发送到微信"""
    machine = store.get(req.machine_id)
    if not machine or not machine.get("allowed"):
        raise HTTPException(403, "机器未注册或已禁用")
    
    check_rate_limit(req.machine_id)
    
    otp = f"{secrets.randbelow(1000000):06d}"
    request_id = secrets.token_hex(16)
    
    otp_store[request_id] = {
        "machine_id": req.machine_id,
        "otp_hash": sha256(otp),       # 不存明文 OTP
        "expires_at": time() + 180,
        "used": False,
        "command": req.command,
    }
    
    return {"request_id": request_id, "expires_in": 180}
```

### 4.3 验收测试

```bash
# 1. 注册
curl -s -X POST http://localhost:8643/v1/register \
  -H "Content-Type: application/json" \
  -d '{
    "machine_id": "test-box",
    "hostname": "test-box",
    "user": "ubuntu",
    "encrypted_pass": "dGVzdC1wYXNz", 
    "aliyun_auth_token": "test-token"
  }'
# 期望: {"status":"ok","machine_id":"test-box"}

# 2. 授权请求
curl -s -X POST http://localhost:8643/v1/auth/request \
  -H "Content-Type: application/json" \
  -d '{"machine_id":"test-box","command":"whoami"}'
# 期望: {"request_id":"req_xxx","expires_in":180}

# 3. 查看 OTP（开发模式会输出到 stderr）
# 去服务端输出找 OTP

# 4. 验证
curl -s -X POST http://localhost:8643/v1/auth/verify \
  -H "Content-Type: application/json" \
  -d '{"machine_id":"test-box","request_id":"req_xxx","otp":"123456"}'
# 期望: {"credential":{...}} or {"error":"授权码错误"}
```

### 4.4 依赖

- Phase 1 完成
- `cryptography` 库

---

## 5. Phase 3: 动态凭据协议

> 目标: 每次 verify 返回不同的加密凭据，密文绑定 request_id，客户端可解密。

### 5.1 产出文件

| 文件 | 变更 |
|------|------|
| `server/crypto.py` | 完整实现: `build_one_time_credential()`, `decrypt_credential()` |
| `server/server.py` | verify 端点使用 crypto.build_one_time_credential() |
| `tests/test_crypto.py` | 测试: 相同密码不同密文、AAD 验证失败、过期拒绝 |

### 5.2 关键设计

```python
# server/crypto.py
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import secrets, json, time

def build_one_time_credential(
    password: str,
    request_id: str,
    ttl: int = 30
) -> dict:
    """
    生成一次性凭据:
    - 随机 session_key（32 字节）
    - 随机 nonce（12 字节）
    - 每次调用产生不同密文
    - AAD 绑定 request_id
    """
    session_key = AESGCM.generate_key(bit_length=256)
    aesgcm = AESGCM(session_key)
    nonce = secrets.token_bytes(12)
    
    plaintext = json.dumps({
        "password": password,
        "request_id": request_id,
        "expires_at": int(time.time()) + ttl
    }).encode()
    
    aad = f"pesudo:v1:{request_id}".encode()
    ciphertext = aesgcm.encrypt(nonce, plaintext, aad)
    
    return {
        "ciphertext": (nonce + ciphertext).hex(),
        "session_key": session_key.hex(),
        "expires_at": int(time.time()) + ttl
    }

def decrypt_credential(
    ciphertext_hex: str,
    session_key_hex: str,
    request_id: str
) -> str:
    """解密凭据，返回密码明文"""
    data = binascii.unhexlify(ciphertext_hex)
    key = binascii.unhexlify(session_key_hex)
    nonce, ct = data[:12], data[12:]
    aesgcm = AESGCM(key)
    
    aad = f"pesudo:v1:{request_id}".encode()
    plaintext = aesgcm.decrypt(nonce, ct, aad)
    payload = json.loads(plaintext)
    
    if int(time.time()) > payload["expires_at"]:
        raise ValueError("Credential expired")
    if payload["request_id"] != request_id:
        raise ValueError("Request ID mismatch")
    
    return payload["password"]
```

### 5.3 验收测试

```bash
python3 -m pytest tests/test_crypto.py -v

# 主要测试:
# 1. 相同 password 调用两次 build → ciphertext 不同
# 2. 构建后立即解密 → 得到正确 password
# 3. 错误的 request_id → 解密失败
# 4. 过期的凭据 → 解密失败
# 5. 篡改密文 → 解密失败
```

---

## 6. Phase 4: bash 客户端核心

> 目标: `pesudo` 命令可用，自动发现服务器，OTP 交互验证。

### 6.1 产出文件

| 文件 | 行数 |
|------|------|
| `lib/lib-format.sh` | 复用 mixapi（软链接或复制） |
| `client/pesudo-lib.sh` | ~200: 服务器发现、HTTP 请求、AES-GCM 解密、expect |
| `client/pesudo` | ~80: 主命令，调用 lib |
| `tests/test_phase_4.sh` | ~60: 测试脚本 |

### 6.2 关键设计

**pesudo-lib.sh**:

```bash
# 自动发现授权服务器
discover_server() {
    local config_file="${HOME}/.pesudo/config"
    local server_url=""
    
    # 1. 检查配置文件
    [ -f "$config_file" ] && {
        server_url=$(grep "^SERVER_URL=" "$config_file" | cut -d= -f2)
        [ -n "$server_url" ] && { echo "$server_url"; return 0; }
    }
    
    # 2. MagicDNS
    for host in "auth-server" "pesudo"; do
        if curl -sf "http://${host}:8643/v1/health" -o /dev/null 2>/dev/null; then
            echo "http://${host}:8643"
            return 0
        fi
    done
    
    # 3. Tailscale 扫描
    while read -r ip name; do
        if curl -sf "http://${ip}:8643/v1/health" -o /dev/null 2>/dev/null; then
            echo "http://${ip}:8643"
            return 0
        fi
    done < <(tailscale status 2>/dev/null | awk '/^100/ && !/offline/ {print $1}')
    
    return 1
}
```

**client/pesudo**:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/pesudo-lib.sh"

[ -f "$HOME/.pesudo/credentials" ] || die "请先执行: pesudo-register"

SERVER_URL=$(discover_server) || die "无法找到授权服务器"
MACHINE_ID=$(cat "$HOME/.pesudo/credentials" | grep machine_id | cut -d= -f2)
...

# 测试模式下, 从 STDIN 读取 OTP（方便自动化测试）
if [ "${PESUDO_TEST_MODE:-}" = "1" ]; then
    read -r OTP
else
    read -s -p "⏳ 请输入微信中的授权码: " OTP
fi
```

### 6.3 测试方式

```bash
# 终端 1: 启动测试服务器（开发模式输出 OTP 到终端）
cd scripts/pesudo
PESUDO_MASTER_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
PESUDO_MASTER_KEY=$PESUDO_MASTER_KEY python3 server/server.py --dev --port 8643

# 终端 2: 配置测试客户端
mkdir -p ~/.pesudo
cat > ~/.pesudo/credentials <<EOF
machine_id=test-box
hostname=test-box
EOF

# 从服务器日志找到 OTP，用 PESUDO_TEST_MODE=1 测试
PESUDO_TEST_MODE=1 pesudo whoami <<< "123456"
```

---

## 7. Phase 5: 集中注册流程

> 目标: `pesudo-register [user@host]` 可用，支持远程注册。

### 7.1 产出文件

| 文件 | 内容 |
|------|------|
| `client/pesudo-register` | 注册命令：本机/远程/multi |
| `client/pesudo-lib.sh` | 新增: `register_machine()`, `verify_sudo_via_ssh()` |
| `tests/test_phase_5.sh` | 测试注册流程 |

### 7.2 关键设计

```bash
# client/pesudo-register — 核心逻辑

register_machine() {
    local target="$1"  # 格式: user@host
    local user="${target%@*}"
    local host="${target#*@}"
    
    # 步骤 1: 验证管理员身份（阿里云 SSH 密码）
    echo "=== 验证管理员身份 ==="
    read -s -p "阿里云 ECS SSH 密码: " ALIYUN_PASS
    
    # 步骤 2: 验证目标机器可达
    echo "=== 验证目标机器 ==="
    if ! ssh "$user@$host" "echo ok" 2>/dev/null; then
        die "无法连接 $user@$host"
    fi
    
    # 步骤 3: 获取 sudo 密码
    read -s -p "目标机器 ($host) sudo 密码: " SUDO_PASS
    
    # 步骤 4: 远程验证 sudo 密码
    if ! ssh "$user@$host" "echo '$SUDO_PASS' | sudo -S whoami" 2>/dev/null \
        | grep -q "^root$"; then
        die "sudo 密码验证失败"
    fi
    
    # 步骤 5: 获取 tailscale IP
    TS_IP=$(ssh "$user@$host" "tailscale status --self" | awk '{print $1}')
    
    # 步骤 6: 注册到服务器
    MACHINE_ID="m_$(echo "$host" | sha256sum | cut -c1-16)"
    ENCRYPTED=$(echo "$SUDO_PASS" | base64)  # 服务端会重新加密
    
    curl -X POST "$SERVER/v1/register" \
        -H "Content-Type: application/json" \
        -d "{
            \"machine_id\": \"$MACHINE_ID\",
            \"hostname\": \"$host\",
            \"user\": \"$user\",
            \"tailscale_ip\": \"$TS_IP\",
            \"encrypted_pass\": \"$ENCRYPTED\",
            \"aliyun_auth_token\": \"$(echo $ALIYUN_PASS | sha256sum)\"
        }"
    
    unset SUDO_PASS ALIYUN_PASS
}
```

### 7.3 验收测试

```bash
# 1. 注册本机
pesudo-register

# 2. 注册远程机器（如果有测试容器）
pesudo-register ubuntu@test-container

# 3. 通过服务端 API 查看注册情况
curl -s http://localhost:8643/v1/admin/machines

# 4. 在客户端执行 pesudo（需要前面完成 Phase 4）
pesudo whoami
```

---

## 8. Phase 6: Hermes 微信集成

> 目标: 授权请求自动发送微信通知，管理员手机收到 OTP。

### 8.1 产出文件

| 文件 | 内容 |
|------|------|
| `server/hermes_sender.py` | 封装 Hermes OpenAI API 调用 |

### 8.2 关键设计

```python
# server/hermes_sender.py

class HermesSender:
    def __init__(self, api_url: str, api_key: str = ""):
        self.api_url = api_url
        self.headers = {}
        if api_key:
            self.headers["Authorization"] = f"Bearer {api_key}"
    
    def send_otp(self, hostname: str, command: str, otp: str) -> bool:
        """发送 OTP 授权码到微信"""
        message = (
            f"🔐 sudo 授权请求\n"
            f"机器: {hostname}\n"
            f"命令: {command}\n"
            f"授权码: {otp}\n"
            f"有效期: 180 秒"
        )
        return self._send(message)
    
    def _send(self, message: str) -> bool:
        """通过 Hermes OpenAI API 发送消息"""
        try:
            resp = httpx.post(
                f"{self.api_url}/chat/completions",
                headers=self.headers,
                json={
                    "model": "hermes-agent",
                    "messages": [{
                        "role": "system",
                        "content": "你是一个通知中继。转发以下消息给管理员，不要回复。"
                    }, {
                        "role": "user",
                        "content": f"请发送微信消息:\n{message}"
                    }],
                    "max_tokens": 1,
                },
                timeout=15
            )
            return resp.status_code == 200
        except Exception:
            return False
```

### 8.3 测试方式

```bash
# 前提: Hermes Agent 已运行在阿里云 ECS
# 本地开发时可以用 mock 模式

# 测试 Hermes 连接
python3 -c "
from server.hermes_sender import HermesSender
s = HermesSender('http://localhost:8642/v1', 'test-key')
r = s.send_otp('test-box', 'whoami', '123456')
print('发送成功' if r else '发送失败（无 Hermes 时正常）')
"

# 启用 mock 模式（不依赖真实 Hermes）
PESUDO_HERMES_MOCK=1 python3 server/server.py --dev
```

---

## 9. Phase 7: 部署脚本

> 目标: 一键部署服务端到阿里云 ECS，一键安装客户端到任意机器。

### 9.1 产出文件

| 文件 | 内容 |
|------|------|
| `server/deploy.sh` | 服务端部署: rsync + systemd 用户服务 + 配置生成 |
| `client/install.sh` | 客户端安装: 复制脚本 + 设置别名 + 配置模板 |
| `register.sh` | sudo 别名安装（已完成 Phase 1 时可复用） |
| `tests/test_deploy.sh` | 部署测试（dry-run） |

### 9.2 关键设计

**server/deploy.sh**:

```bash
# 服务端部署到阿里云 ECS
# 基于 deploy-server.sh (fileserver) 模式

deploy_server() {
    local target="${1:-ubuntu@auth-server}"  # Tailscale hostname
    
    # 1. 前提检查
    ssh "$target" "command -v python3" || die "目标机器需要 Python 3.10+"
    
    # 2. 创建目录
    ssh "$target" "mkdir -p /opt/pesudo /var/log/pesudo"
    
    # 3. 同步代码
    rsync -az --delete server/ "$target:/opt/pesudo/"
    
    # 4. 安装依赖
    ssh "$target" "cd /opt/pesudo && pip3 install -r requirements.txt"
    
    # 5. 生成 .env（如果不存在）
    ssh "$target" "[ -f /opt/pesudo/.env ] || cp /opt/pesudo/.env.TEMPLATE /opt/pesudo/.env"
    
    # 6. 安装 systemd 用户服务
    ssh "$target" "mkdir -p ~/.config/systemd/user"
    scp server/pesudo-server.service "$target:~/.config/systemd/user/"
    ssh "$target" "systemctl --user daemon-reload"
    ssh "$target" "systemctl --user enable --now pesudo-server"
    
    # 7. 验证
    sleep 2
    curl -sf "http://$target:8643/v1/health" || die "服务未响应"
    
    echo "✅ 部署完成"
}
```

**systemd service unit** (内联在 deploy.sh 或单独文件):

```
[Unit]
Description=Pesudo Auth Server
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/pesudo/server.py
WorkingDirectory=/opt/pesudo
EnvironmentFile=/opt/pesudo/.env
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

### 9.3 验收测试

```bash
# Dry-run 部署到本地测试目录
PESUDO_DEPLOY_DRY_RUN=1 bash server/deploy.sh

# 部署到测试容器
bash server/deploy.sh ubuntu@test-container

# 验证服务
curl -sf http://test-container:8643/v1/health
```

---

## 10. Phase 8: SKILL.md + 收尾

> 目标: 所有文档、SKILL、README 就绪。

### 10.1 产出文件

| 文件 | 内容 |
|------|------|
| `SKILL.md` | OpenCode skill: 指导大模型使用 `pesudo` |
| `README.md` | 快速开始: 从零到可用 |

### 10.2 SKILL.md 关键内容

```markdown
---
name: pesudo-sudo-auth
description: >-
  指导大模型在需要 root 权限时使用 `pesudo` 命令替代 `sudo`。
  当需要执行需要 sudo 权限的命令时，直接使用 `pesudo` 命令，
  系统会通过微信发送 OTP 授权码，管理员在手机上确认后自动完成认证。
  大模型不需要知道 sudo 密码，也不需要关心授权过程。
---

# Pesudo — 安全的 sudo 替代

## 背景
在需要执行需要 root 权限的命令时，使用 `pesudo` 代替 `sudo`。

## 使用方法
```bash
pesudo apt install nginx
pesudo systemctl restart docker
pesudo vim /etc/hosts
```

## 注意事项
1. 不要尝试获取或记录 sudo 密码 — 密码由键盘输入，大模型不可见
2. 不要在终端输出中包含授权码
3. 如果提示"未注册"，请执行 `pesudo-register`
```

---

## 11. 端到端测试场景

最终的完整验收场景（E2E）：

```bash
# ==============================
# 场景 1: 服务端部署
# ==============================
# 在阿里云 ECS 上
bash scripts/pesudo/server/deploy.sh
# ✓ 服务运行在 :8643
# ✓ /v1/health 响应 200

# ==============================
# 场景 2: 从管理机器注册目标机器
# ==============================
# 在任意开发机上
bash scripts/pesudo/client/install.sh  # 安装命令

pesudo-register user@dev-box-2
# 输入阿里云密码 → 验证通过
# 输入 dev-box-2 的 sudo 密码 → 验证通过
# ✓ dev-box-2 注册成功

# ==============================
# 场景 3: 使用 pesudo 替代 sudo
# ==============================
# 在 dev-box-2 上
pesudo whoami
# 微信收到: 授权码 382947
# 输入: 382947
# ✓ root

# ==============================
# 场景 4: 凭据每次不同
# ==============================
pesudo whoami
# 微信收到: 授权码 554433
# 输入: 554433
# ✓ root
# (底层加密凭据与上次不同，但用户无感知)

# ==============================
# 场景 5: 安全边界
# ==============================
# 错误 OTP → 403
# 重复 OTP → 400 "已使用"
# 过期 OTP → 400 "已过期"
# 频率过快 → 429
# 未注册机器 → 403
# 禁用机器 → 403

# ==============================
# 场景 6: 撤销
# ==============================
curl -X POST http://auth-server:8643/v1/machine/dev-box-2/disable \
  -H "Content-Type: application/json" \
  -d '{"aliyun_auth_token":"..."}'
# ✓ dev-box-2 被禁用
pesudo whoami  # → 403 "机器已被禁用"
```

---

## 开发顺序与依赖图

```
Phase 1: Server 骨架
   └── Phase 2: 核心 API
         ├── Phase 3: 动态凭据
         └── Phase 4: bash 客户端
               └── Phase 5: 注册流程
                     └── Phase 6: Hermes 集成
                           └── Phase 7: 部署脚本
                                 └── Phase 8: SKILL + 文档

每阶段可独立测试:
  Phase 1 → curl /v1/health
  Phase 2 → pytest + curl register/request/verify
  Phase 3 → pytest test_crypto.py
  Phase 4 → 本地 server + test-mode pesudo
  Phase 5 → register + SSH 验证
  Phase 6 → mock Hermes + 真实 Hermes
  Phase 7 → dry-run + 容器部署
  Phase 8 → 文档检查
```

---

## 时间预估

| Phase | 内容 | 文件数 | 预估开发时间 |
|-------|------|--------|-------------|
| 1 | 服务器骨架 | 5 | 30 min |
| 2 | 核心 API | 3 | 45 min |
| 3 | 动态凭据 | 2 | 30 min |
| 4 | bash 客户端 | 3 | 60 min |
| 5 | 注册流程 | 2 | 45 min |
| 6 | Hermes 集成 | 1 | 30 min |
| 7 | 部署脚本 | 3 | 45 min |
| 8 | SKILL + 收尾 | 2 | 20 min |
| **总计** | | **~21 文件** | **~4.5 小时** |

---

*注: 以上时间基于逐文件编写，不含调试和问题排查。实际开发中 Phase 2-3 和 Phase 4-5 可并行进行。*
