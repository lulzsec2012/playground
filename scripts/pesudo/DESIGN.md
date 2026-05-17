# Pesudo — 安全的 sudo 替代系统设计文档

> 通过微信 OTP 授权执行 sudo，防止大语言模型 agent 看到 sudo 密码明文。
> 设计版本: v2.0 | 最后更新: 2026-05-15

---

## 目录

1. [问题背景](#1-问题背景)
2. [威胁模型](#2-威胁模型)
3. [总体架构](#3-总体架构)
4. [Tailscale 自动发现协议](#4-tailscale-自动发现协议)
5. [集中式注册协议](#5-集中式注册协议)
6. [授权协议](#6-授权协议)
7. [动态凭据协议](#7-动态凭据协议)
8. [Hermes 微信集成](#8-hermes-微信集成)
9. [API 参考](#9-api-参考)
10. [文件结构](#10-文件结构)
11. [配置模板](#11-配置模板)
12. [安全分析](#12-安全分析)
13. [实施路线](#13-实施路线)

---

## 1. 问题背景

### 1.1 场景

用户通过大语言模型 agent（如 OpenCode）管理位于 Tailscale 网络内的多台 Linux/macOS 机器。当 agent 需要执行需要 `sudo` 权限的操作时（如 `apt install`、`systemctl`、修改系统配置），必须提供 sudo 密码。

### 1.2 核心矛盾

| 角色 | 需要什么 | 风险 |
|------|----------|------|
| 大模型 agent | 执行特权命令 | 看到 sudo 密码明文后可脱离人类控制 |
| 人类用户 | 授权 agent 执行 | 每次输入密码太繁琐，失去自动化意义 |
| 系统安全 | sudo 密码不被泄漏 | 一旦泄漏，所有机器暴露 |

### 1.3 设计目标

1. **防止大模型看到 sudo 密码明文** — 密码只在键盘输入期间存在，从不到达 agent 的上下文
2. **每次授权有人类确认** — 通过微信 OTP，用户不在终端前也能授权
3. **凭据每次不同** — 避免重放攻击和静态凭据泄漏
4. **零硬编码配置** — 授权服务器通过 Tailscale 自动发现
5. **集中注册** — 任意机器可为任意其他机器注册，无需逐台登录

---

## 2. 威胁模型

### 2.1 信任假设

| 信任 | 说明 |
|------|------|
| ✅ 用户本人 | 完全可信，拥有所有机器的所有权和管理权 |
| ✅ Tailscale 网络 | 可信，所有节点通过 Tailscale 认证和 WireGuard 加密通信 |
| ✅ 授权服务器节点 | 可信，运行在阿里云 ECS，Tailscale 内可达 |
| ✅ 大模型 agent 进程 | **不可信**，不能访问标准输入（`/dev/tty`）中的键盘输入 |
| ❌ 大模型 agent 输出 | **不可信**，agent 可能读取终端输出和环境变量 |
| ❌ 外部网络 | **不可信**，但 Tailscale WireGuard 已提供传输加密 |

### 2.2 核心威胁：大模型看到 sudo 密码

```
┌─────────────────────────────────────────────────┐
│  终端显示区域 (大模型 agent 可读取)               │
│                                                  │
│  $ sudo apt install nginx                        │
│  [sudo] password for user: ************       │
│  ✓ 安装成功                                      │
│                                                  │
│  ⚠️ 如果密码在终端回显，或脚本中明文存储，         │
│     agent 可捕获并重复使用                       │
└─────────────────────────────────────────────────┘
```

**防护策略**: 密码只在 `read -s` 的键盘输入瞬间出现，从不进入终端回显或任何文件。后续通过 `expect` + 进程环境变量传递到 `sudo`，agent 无法截获。

### 2.3 非威胁

- **不防物理攻击**：有人物理访问机器时可以直接操作
- **不防 root 权限恶意软件**：root 可以读取任意进程内存
- **不防 Tailscale 节点被完全控制**：节点所有者可以访问所有本地资源

---

## 3. 总体架构

### 3.1 组件

```
┌──────────────────────────────┐     Tailscale HTTPS      ┌──────────────────────────────┐
│  客户端机器 A (tailnet 内)     │ ◄──────────────────────► │  授权服务器 (阿里云 ECS)      │
│                              │                          │                              │
│  /usr/local/bin/pesudo       │    /v1/register           │  /opt/pesudo/server.py       │
│  ~/.pesudo/config            │    /v1/auth/request       │  /opt/pesudo/store.json      │
│  ~/.pesudo/credentials       │    /v1/auth/verify        │      (AES-GCM 加密存储)       │
│                              │                          │                              │
│  用户终端                    │                          │  Hermes Agent (localhost)    │
│  └─ pesudo apt install nginx │                          │  └─ WeChat 通道              │
│     └─ read -s OTP           │                          │         ↕                    │
│     └─ expect → sudo ...     │                          │  ┌──────────────────┐        │
│                              │                          │  │  用户微信         │        │
│  客户端机器 B (tailnet 内)    │                          │  │  ← OTP 授权码     │        │
│  └─ /usr/local/bin/pesudo    │                          │  └──────────────────┘        │
│                              │                          │                              │
│  注册管理机器 (任意 tailnet    │                          │                              │
│  节点，包括非目标机器)         │                          │                              │
│  └─ pesudo-register user@B   │                          │                              │
└──────────────────────────────┘                          └──────────────────────────────┘
```

### 3.2 数据流概要

```
注册 (从任何机器为任何机器注册):
  [注册者] → SSH 验证目标机器可达 → 录入目标 sudo 密码（read -s）
          → POST /v1/register {machine_id, host, user, ts_ip, encrypted_pass}
          → [服务器] AES-256-GCM 加密存储

授权 (在目标机器上):
  [目标机器] → POST /v1/auth/request {machine_id, command}
             → [服务器] 生成 OTP → Hermes → 用户微信
             → [用户] 查看微信，终端输入 OTP（read -s）
             → POST /v1/auth/verify {request_id, otp}
             → [服务器] 验证 OTP
                       → 解密存储密码
                       → 生成随机 session_key
                       → AES-GCM 重新加密（不同 nonce = 不同密文）
                       → 返回 {ciphertext, nonce, session_key}
             → [客户端] AES-GCM 解密 → 提取密码
                      → expect 执行 sudo 命令
                      → 清除所有凭据变量
```

---

## 4. Tailscale 自动发现协议

### 4.1 设计原则

- **零配置**: 客户端零硬编码 IP/域名
- **MagicDNS 优先**: 利用 Tailscale MagicDNS（`<hostname>.tail<random>.ts.net`）
- **逐步降级**: hostname → 配置 → 全量扫描

### 4.2 发现顺序

```
客户端初始化 discover_server():

  第 1 步: MagicDNS 直连
  ─────────────────────────────────────────────
  curl -sf http://auth-server:8643/v1/health
  curl -sf http://pesudo:8643/v1/health
  (Tailscale MagicDNS 会将 auth-server 解析为
   对应节点的 Tailscale IP)
  成功 → 缓存到 ~/.pesudo/config

  第 2 步: 配置文件
  ─────────────────────────────────────────────
  ~/.pesudo/config 中存在 SERVER_URL
  → 直接使用

  第 3 步: Tailscale 节点扫描
  ─────────────────────────────────────────────
  tailscale status → 列出所有在线节点
  逐台探测 port 8643
  (先探测 hostname 含 pesudo/auth 的节点)
  成功 → 缓存

  第 4 步: 提示用户
  ─────────────────────────────────────────────
  所有方式失败 → 输出提示信息
  "未找到授权服务器，请确认:
   1. 授权服务器已在 tailnet 内运行
   2. 运行: pesudo-register <user>@<auth-server>:8643"
```

### 4.3 健康检查端点

```
GET /v1/health

响应: 200 OK
{
  "status": "ok",
  "version": "1.0.0",
  "node": "auth-server"
}
```

---

## 5. 集中式注册协议

### 5.1 核心思路

注册不再需要在每台目标机器上分别执行。**从任意一台 Tailscale 节点**，使用 `pesudo-register <user>@<host>` 即可为目标机器注册。

### 5.2 注册流程

```
                   注册管理机器                   目标机器           授权服务器
                  (任意 tailnet 节点)            (被注册机器)
                        │                          │                  │
  1. 用户执行:          │                          │                  │
     pesudo-register    │                          │                  │
       user@dev-box2 │                          │                  │
                        │                          │                  │
  2. 提示输入阿里云 ECS  │                          │                  │
     SSH 密码 (验证身份) │                          │                  │
     (read -s 不回显)   │                          │                  │
                        │                          │                  │
  3. SSH 到目标机器     ├── ssh user@dev-box2 ──▶                  │
     验证可达性和       │    (Tailscale SSH,        │                  │
     sudo 密码          │      无需密码认证)         │                  │
                        │                          │                  │
  4. 提示输入目标机器    │                          │                  │
     sudo 密码          │                          │                  │
     (read -s 不回显)   │                          │                  │
                        │                          │                  │
  5. SSH 通道内验证     ├── echo "$PASS" ││          │                  │
     sudo 密码          │   | ssh dev-box2         │                  │
                        │   sudo -S whoami ───────▶│                  │
                        │   ← root ✓              │                  │
                        │                          │                  │
  6. POST /v1/register  ├────────────────────────────────────────────▶│
     {                  │                          │                  │
       machine_id,      │                          │    AES-GCM 加密  │
       hostname,        │                          │    存储密码      │
       tailscale_ip,    │                          │                  │
       user,            │                          │                  │
       encrypted_pass   │                          │                  │
     }                  │                          │                  │
                        │                          │                  │
  7. 服务器确认         ◀────────────────────────────────────────────┤
     "✓ dev-box2 注册成功"│                        │                  │
                        │                          │                  │
  8. [可选] 在目标机器   ├── ssh dev-box2 ─────────▶│                  │
     安装 pesudo 别名    │   安装 pesudo 脚本       │                  │
                        │   + ~/.pesudo/config     │                  │
                        │                          │                  │
  9. 微信通知           │                          │                  │
     "新机器 dev-box2   │                          │                  │
      已注册"           │                          │                  │
                        │                          │                  │
  10. 完成              │                          │                  │
```

### 5.3 注册命令用法

```bash
# 注册本机（传统方式，在目标机器上直接执行）
pesudo-register

# 注册远程机器（核心用法—从任意节点注册另一节点）
pesudo-register user@dev-box-2

# 注册远程机器 + 指定 tailscale IP（避免 MagicDNS 解析问题）
pesudo-register user@100.65.32.18 --hostname dev-box-2

# 批量注册（从文件读取）
pesudo-register --batch machines.txt
```

### 5.4 批量注册文件格式

```text
# machines.txt — 每行一条
user@dev-box-2
user@dev-box-3
user@worker-1
```

### 5.5 注册信息在服务端的存储结构

```json
{
  "machine_dev-box2_xxxx": {
    "hostname": "dev-box-2",
"user": "ubuntu",
    "tailscale_ip": "100.65.32.18",
    "encrypted_pass": "<AES-GCM ciphertext hex>",
    "created_at": 1715760000,
    "last_used": 1715763600,
    "allowed": true,
    "registered_by": "dev-box-1",
    "tags": []
  }
}
```

---

## 6. 授权协议

### 6.1 前提条件

1. 目标机器已通过 `pesudo-register` 注册到授权服务器
2. 目标机器已安装 `pesudo` 命令及 `register.sh` 别名
3. 目标机器可通过 Tailscale MagicDNS 发现授权服务器

### 6.2 授权流程

```
客户端 (目标机器)           Tailscale          授权服务器         用户微信
      │                       │                  │                  │
      │ sudo apt install nginx│                  │                  │
      │ (alias → pesudo)      │                  │                  │
      │                       │                  │                  │
      │ ① 自动发现服务器       │                  │                  │
      │    (MagicDNS)         │                  │                  │
      │                       │                  │                  │
      │ ② POST /v1/auth/request─────────────────▶│                  │
      │    {machine_id,       │                  │                  │
      │     command,          │                  │                  │
      │     hostname}         │                  │                  │
      │                       │                  │ ③ 频率限制检查     │
      │                       │                  │ ④ 生成 OTP        │
      │                       │                  │    (6位, 180s)    │
      │                       │                  │ ⑤ 存储 OTP        │
      │                       │                  │                   │
      │                       │                  │ ⑥ Hermes 发送微信 │
      │                       │                  ├──────────────────▶│
      │                       │                  │  "🔐 sudo 授权请求 │
      │                       │                  │   机器: dev-box-2  │
      │  ← {request_id,       │                  │   命令: apt ...    │
      │      expires_in: 180}  │                  │   授权码: 382947"  │
      │                       │                  │                   │
      │ ⑦ 提示用户输入 OTP    │                  │                   │
      │ "📱 已向微信发送授权码" │                  │                   │
      │ "请输入 6 位授权码: "  │                  │                   │
      │                       │                  │                   │
      │                       │                  │  ← 用户查看微信    │
      │                       │                  │     获取授权码      │
      │                       │                  │                   │
      │ ⑧ read -s OTP        │                  │                   │
      │    382947 (不回显)     │                  │                   │
      │                       │                  │                   │
      │ ⑨ POST /v1/auth/verify──────────────────▶│                   │
      │    {machine_id,       │                  │                   │
      │     request_id,       │ ⑩ 验证 OTP       │                   │
      │     otp: "382947"}    │    一次性检查      │                   │
      │                       │    是否过期检查    │                   │
      │                       │    哈希比较       │                   │
      │                       │                  │                   │
      │                       │ ⑪ 解密存储密码    │                   │
      │                       │ ⑫ 生成 session_key│                   │
      │                       │ ⑬ AES-GCM 重加密  │                   │
      │                       │    (随机 nonce)    │                   │
      │                       │                  │                   │
      │  ← {credential: {     │                  │                   │
      │      ciphertext,      │                  │                   │
      │      nonce,           │                  │                   │
      │      session_key,     │                  │                   │
      │      expires_at}}     │                  │                   │
      │                       │                  │                   │
      │ ⑭ 检查 expires_at     │                  │                   │
      │ ⑮ AES-GCM 解密        │                  │                   │
      │ ⑯ 验证 request_id     │                  │                   │
      │ ⑰ 提取 password 明文  │                  │                   │
      │                       │                  │                   │
      │ ⑱ expect 执行 sudo   │                  │                   │
      │    密码仅存 expect    │                  │                   │
      │    进程内存           │                  │                   │
      │                       │                  │                   │
      │ ⑲ unset 所有凭据变量  │                  │                   │
      │                       │                  │                   │
      │ ✓ apt install nginx   │                  │                   │
```

### 6.3 用户操作拆解

```
终端显示器内容                          终端键盘              微信
(大模型 agent 可见)                    (大模型不可见)        (用户手机)
                                         │                  │
  $ pesudo apt install nginx              │                  │
  🔐 正在请求 sudo 授权...                │                  │
  📱 已向微信发送授权请求                  │                  │
     命令: apt install nginx              │                  │
  ⏳ 请输入微信中的 6 位授权码:            │                  │
                                         │                  │  🔐 sudo 授权请求
                                         │                  │  机器: dev-box-2
                                         │                  │  命令: apt install nginx
                                         │                  │  授权码: 382947
                                         │  输入: 382947    │  有效期: 180 秒
                                         │  (按回车)        │
  ✓ 授权成功，正在执行...                  │                  │
  Reading package lists...                │                  │
  Building dependency tree...             │                  │
  ...                                     │                  │
```

**关键安全点**:
- ⚠️ 密码输入使用 `read -s`（不回显），大模型 agent 看不到具体按键
- ⚠️ OTP 输入也使用 `read -s`，虽然 OTP 本身有效时间短
- ⚠️ 密码从不在终端输出中出现

---

## 7. 动态凭据协议

### 7.1 设计目标

每次授权响应中传输的凭据必须不同，防止以下攻击：
- **重放攻击**: 捕获一次凭据后重复使用
- **静态凭据泄漏**: 如果加密凭据是静态文件，泄漏后永久有效
- **关联分析**: 通过相同密文推断同一密码在多处使用

### 7.2 协议细节

```
服务器侧 (每次 verify 时):
┌──────────────────────────────────────────┐
│  ① 解密存储密码 → plaintext_password P  │
│  ② 生成随机 session_key SK (32字节)     │
│     SK = AESGCM.generate_key()           │
│  ③ 生成随机 nonce N (12字节)            │
│     N = secrets.token_bytes(12)          │
│  ④ 构建明文载荷:                         │
│     payload = {                          │
│       password: P,                       │
│       request_id: <当前请求ID>,           │
│       issued_at: <时间戳>,               │
│       expires_at: <时间戳 + 30s>          │
│     } (JSON)                             │
│  ⑤ 构建 AAD (附加认证数据):              │
│     aad = "pesudo:v1:<request_id>"       │
│  ⑥ 加密:                                 │
│     ciphertext = AESGCM.encrypt(         │
│       key=SK, nonce=N,                   │
│       plaintext=payload, aad=aad         │
│     )                                    │
│  ⑦ 返回:                                 │
│     {ciphertext: hex(N+ciphertext),      │
│      session_key: hex(SK)}               │
└──────────────────────────────────────────┘

每次返回值为什么不同:
┌──────────────────────────────────────────┐
│  因素              │  每次变化?           │
│───────────────────┼─────────────────────│
│  session_key SK   │  ✓ 全新随机生成       │
│  nonce N          │  ✓ 全新随机生成       │
│  derived key      │  ✓ SK不同→派生密钥不同│
│  ciphertext       │  ✓ nonce+SK不同→密文异│
│  aad request_id   │  ✓ 每次请求不同       │
│  expires_at       │  ✓ 每次时间戳不同     │
└──────────────────────────────────────────┘
```

### 7.3 客户端解密

```bash
# 原始密码值相同，但每次传输的加密载荷完全不同
# 客户端解密:
# 1. 从响应中提取 ciphertext, nonce, session_key
# 2. 验证 expires_at 未过期
# 3. 验证密文中的 request_id 与本次请求一致
# 4. AES-GCM 解密提取密码
# 5. 立即用于 expect
# 6. 清除所有变量

ciphertext=$(echo "$RESP" | jq -r '.credential.ciphertext')
session_key=$(echo "$RESP" | jq -r '.credential.session_key')

# Python 解密
SUDO_PASS=$(python3 -c "
import json, binascii
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ct = binascii.unhexlify('$ciphertext')
key = binascii.unhexlify('$session_key')
nonce = ct[:12]
data = ct[12:]

aad = b'pesudo:v1:${REQUEST_ID}'
aesgcm = AESGCM(key)
plain = aesgcm.decrypt(nonce, data, aad)
print(json.loads(plain)['password'])
")

# 立即清除（密码只在 expect 进程存在）
export SUDO_PASS
expect -c '
    set password $env(SUDO_PASS)
    spawn sudo -k {*}$argv
    expect {
        -re {password for .*:} { send "$password\r"; exp_continue }
        eof { exit [lindex [wait] 3] }
    }
'
unset SUDO_PASS
```

---

## 8. Hermes 微信集成

### 8.1 集成方案

授权服务器与 Hermes Agent 部署在**同一台阿里云 ECS** 上。授权服务器通过 Hermes 的 OpenAI 兼容 API（`:8642`）发送微信消息。

```
授权服务器                 Hermes Agent              iLink Bot API
server.py ──HTTP POST──▶ hermes-api(:8642) ────────▶ WeChat 消息
            :8643         :8642                       → 用户手机
                         (OpenAI API)
```

### 8.2 消息类型

**OTP 授权通知**:
```
🔐 sudo 授权请求
机器: dev-box-2
命令: apt install nginx
授权码: 382947
有效期: 180 秒
请在终端输入此授权码以授权。
```

**注册通知**:
```
✅ 新机器注册成功
机器: dev-box-2 (100.65.32.18)
用户: ubuntu
```

**安全告警**:
```
⚠️ 授权失败告警
机器: dev-box-2
原因: OTP 连续错误 3 次
时间: 2026-05-15 14:30:00
```

### 8.3 配置

```bash
# .env 配置
HERMES_API=http://localhost:8642/v1
HERMES_API_KEY=change-me-local-dev
```

### 8.4 备用方案

如果 Hermes API Server 不可用，提供降级模式（通过 stderr 输出 OTP，用户可以 SSH 到授权服务器查看）：

```bash
# server.py 降级逻辑
if not hermes.send_otp(...):
    logger.warning(
        f"OTP for {hostname}: {otp} "
        f"(Hermes 不可用，请 SSH 到服务器查看)"
    )
    # OTP 同时写入 /opt/pesudo/pending_otps/{request_id}.otp
```

---

## 9. API 参考

### 9.1 `GET /v1/health`

健康检查，用于 Tailscale 自动发现。

**响应**:
```json
{
  "status": "ok",
  "version": "1.0.0"
}
```

### 9.2 `POST /v1/register`

注册一台机器到授权服务器。可从任意 Tailscale 节点发起。

**请求**:
```json
{
  "machine_id": "uuid-or-hostname-hash",
  "hostname": "dev-box-2",
  "tailscale_ip": "100.65.32.18",
  "user": "ubuntu",
  "encrypted_pass": "<base64-encrypted-sudo-password>",
  "aliyun_auth_token": "<阿里云SSH密码派生的认证令牌>"
}
```

**响应 (200)**:
```json
{
  "status": "ok",
  "machine_id": "m_dev-box2_xxxx"
}
```

**错误 (403)**:
```json
{
  "error": "身份验证失败"
}
```

### 9.3 `POST /v1/auth/request`

发起一次 sudo 授权请求，触发 OTP 发送。

**请求**:
```json
{
  "machine_id": "m_dev-box2_xxxx",
  "command": "apt install nginx"
}
```

**响应 (200)**:
```json
{
  "request_id": "req_a1b2c3d4e5f6",
  "expires_in": 180
}
```

**错误 (429)**:
```json
{
  "error": "请求过于频繁，每分钟最多 3 次",
  "retry_after": 45
}
```

### 9.4 `POST /v1/auth/verify`

验证 OTP，获取一次性加密凭据。

**请求**:
```json
{
  "machine_id": "m_dev-box2_xxxx",
  "request_id": "req_a1b2c3d4e5f6",
  "otp": "382947"
}
```

**响应 (200)**:
```json
{
  "credential": {
    "ciphertext": "<aes-gcm-密文-hex>",
    "session_key": "<一次性-32字节密钥-hex>",
    "expires_at": 1715760180
  }
}
```

**错误码**:
| HTTP | 含义 |
|------|------|
| 400 | 无效请求 ID |
| 400 | 授权码已使用 |
| 400 | 授权码已过期 |
| 403 | 授权码错误 |
| 404 | 机器未注册或已禁用 |

### 9.5 `POST /v1/machine/{machine_id}/disable`

撤销一台机器的授权。

**请求** (管理接口, 需阿里云认证令牌):
```json
{
  "aliyun_auth_token": "<...>"
}
```

**响应 (200)**:
```json
{
  "status": "disabled",
  "machine_id": "m_dev-box2_xxxx"
}
```

---

## 10. 文件结构

```
scripts/pesudo/
│
├── DESIGN.md                          ← 本设计文档
├── README.md                          ← 快速开始
├── SKILL.md                           ← OpenCode skill（指导大模型使用 pesudo）
│
├── client/                            # 客户端组件
│   ├── pesudo                         # ★ 主命令: pesudo <command>
│   │                                     代替 sudo 执行命令
│   ├── pesudo-register                # ★ 注册命令: pesudo-register [user@host]
│   │                                     集中注册任意机器
│   ├── pesudo-lib.sh                  #   公共函数库
│   │                                     自动发现服务器
│   │                                     OTP 请求与验证
│   │                                     AES-GCM 解密
│   │                                     expect sudo 执行
│   ├── pesudo.conf.TEMPLATE           #   客户端配置文件模板
│   └── install.sh                     #   安装/卸载脚本
│
├── server/                            # 服务端组件
│   ├── server.py                      # ★ FastAPI 授权服务器（端口 8643）
│   ├── hermes_sender.py               #   Hermes 微信消息发送桥
│   ├── store.py                       #   加密凭据库管理
│   ├── requirements.txt               #   Python 依赖
│   ├── deploy.sh                      #   一键部署脚本
│   └── .env.TEMPLATE                  #   服务端配置模板
│       # PESUDO_MASTER_KEY=<AES-256 key>
│       # HERMES_URL=http://localhost:8642
│       # PESUDO_PORT=8643
│
├── register.sh                        # 别名安装 (sudo → pesudo)
│                                      自动检测 shell rc 文件
│                                      添加 alias sudo='pesudo'
│
└── tests/
    ├── test_server.py                 #   服务端单元测试
    └── test_flow.sh                   #   端到端集成测试
```

---

## 11. 配置模板

### 11.1 客户端配置 (`pesudo.conf.TEMPLATE`)

```ini
# ============================================================
# Pesudo 客户端配置
# 复制为 pesudo.conf 后使用
# ============================================================
# 此文件不含任何 IP 地址或密码

# 授权服务器发现方式:
#   auto      — MagicDNS → Tailscale 节点扫描（推荐）
#   manual    — 使用下方 SERVER_URL
DISCOVERY_MODE="auto"

# manual 模式下使用此值:
# SERVER_URL="http://auth-server:8643"

# 本机 machine_id（注册时自动生成）
# MACHINE_ID="m_dev-box2_xxxx"
```

### 11.2 服务端配置 (`.env.TEMPLATE`)

```bash
# ============================================================
# Pesudo 授权服务器配置
# 复制为 .env 后使用
# ============================================================

# AES-256-GCM 主密钥（用于加密存储所有机器的 sudo 密码）
# 生成: python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
PESUDO_MASTER_KEY=

# Hermes API 地址（同机部署，默认 localhost）
HERMES_URL=http://localhost:8642/v1
HERMES_API_KEY=change-me-local-dev

# 授权服务器监听端口
PESUDO_PORT=8643

# 阿里云 ECS SSH 认证配置
# 用于注册时验证管理员身份
ALIYUN_SSH_HOST=localhost
ALIYUN_SSH_USER=

# 数据存储路径
PESUDO_STORE=/opt/pesudo/store.json
PESUDO_LOG=/var/log/pesudo/audit.log

# OTP 配置
OTP_LENGTH=6
OTP_EXPIRE_SECONDS=180
RATE_LIMIT_PER_MINUTE=3
```

---

## 12. 安全分析

### 12.1 攻击面覆盖矩阵

| 攻击路径 | 防护方式 | 严重程度 |
|----------|----------|----------|
| **大模型看到密码** | `read -s` 不回显键盘输入，密码仅存 expect 进程内存 | ✅ 已防护 |
| **重放请求** | OTP 一次性 + request_id 单次有效 + 凭据绑定 request_id | ✅ 已防护 |
| **OTP 暴力破解** | 频率限制（每分钟 3 次）+ 6 位 OTP（百万分之一） | ✅ 已防护 |
| **凭据静态重复** | AES-GCM 每次随机 nonce + 独立 session_key | ✅ 已防护 |
| **MITM 窃听** | Tailscale WireGuard 端到端加密 | ✅ 已防护 |
| **服务器数据泄漏** | AES-256 加密存储，MASTER_KEY 独立于代码 | ✅ 已防护 |
| **未授权注册** | 阿里云 SSH 密码验证管理员身份 | ✅ 已防护 |
| **已注册机器撤销** | 服务器端 API 禁用 | ✅ 已防护 |
| **审计追溯** | 每次请求/授权/失败记录到 `/var/log/pesudo/audit.log` | ✅ 已防护 |
| **expect 密码泄漏** | 密码通过环境变量传递，expect 退出后释放；不写入 /proc/pid/cmdline | ✅ 已防护 |

### 12.2 密码生命周期

```
注册时键盘输入
  │
  ▼
加密传输 -> 服务器 AES-256-GCM 加密存储 (永远不返回给客户端)
  │                                                    ▲
  │                                                    │ (每次 verify 时)
  │  服务器解密 ──→ 生成 session_key + nonce ──→ AES-GCM 重加密
  │                                                    │
  │                                                    ▼
  │                                    客户端接收 -> AES-GCM 解密
  │                                                    │
  │                                                    ▼
  │                                    expect 进程内存 -> sudo 认证
  │                                                    │
  │                                                    ▼
  │                                    expect 退出 -> 密码自动释放
  │
  └─────────────────────────────────────────────────────┘
  密码仅在 3 个时刻以明文形式存在:
  1. 注册时: 用户键盘输入 → 服务器内存（1 秒内加密）
  2. 授权时: 服务器内存 → 客户端内存（30 秒内使用并清除）
  3. 执行时: expect 进程内存 → sudo 验证（命令执行后释放）
  
  密码从不出现的位置:
  ✅ 终端回显
  ✅ 磁盘文件
  ✅ 进程命令行参数 (/proc/pid/cmdline)
  ✅ 大语言模型上下文窗口
  ✅ 日志文件
  ✅ 网络抓包 (Tailscale 加密)
```

### 12.3 审计日志格式

```json
{"timestamp":"2026-05-15T14:30:00Z","action":"request","machine_id":"m_dev-box2_xxxx","command":"apt install nginx","result":"otp_sent"}
{"timestamp":"2026-05-15T14:30:15Z","action":"verify","machine_id":"m_dev-box2_xxxx","detail":"otp_match","result":"credential_issued"}
{"timestamp":"2026-05-15T14:30:00Z","action":"verify","machine_id":"m_dev-box2_xxxx","detail":"otp_mismatch","result":"denied"}
{"timestamp":"2026-05-15T14:29:00Z","action":"register","machine_id":"m_dev-box2_xxxx","hostname":"dev-box-2","registered_by":"dev-box-1"}
{"timestamp":"2026-05-15T14:31:00Z","action":"disable","machine_id":"m_dev-box2_xxxx","trigger":"admin"}
```

---

## 13. 实施路线

| Phase | 内容 | 文件 | 预估工作量 |
|-------|------|------|-----------|
| **1** | 目录结构 + `register.sh` + `install.sh` + `pesudo.conf.TEMPLATE` | `register.sh`, `install.sh`, `pesudo.conf.TEMPLATE` | 小 |
| **2** | 授权服务器核心 (`server.py` + `store.py`) | `server/server.py`, `server/store.py`, `server/requirements.txt`, `server/.env.TEMPLATE` | 中 |
| **3** | 客户端核心 (`pesudo-lib.sh` + `pesudo` + `pesudo-register`) | `client/pesudo*` | 大 |
| **4** | Hermes 集成 (`hermes_sender.py` + 调试) | `server/hermes_sender.py` | 小 |
| **5** | 部署脚本 + 测试 | `server/deploy.sh`, `tests/*` | 中 |
| **6** | `SKILL.md` + `README.md` | `SKILL.md`, `README.md` | 小 |

### Phase 1 依赖

```
register.sh   → 无依赖（纯 shell rc 修改）
install.sh    → 依赖 register.sh
pesudo.conf.TEMPLATE → 无依赖
```

### Phase 2 依赖

```
server.py     → FastAPI, cryptography, httpx, python-dotenv
store.py      → cryptography (Fernet)
```

### Phase 3 依赖

```
pesudo        → pesudo-lib.sh, 需要 expect, curl, python3, jq
pesudo-register → pesudo-lib.sh, 需要 ssh (Tailscale SSH)
pesudo-lib.sh → 需要 curl, tailscale CLI, python3
```

---

## 附录 A：与现有基础设施的集成

### A.1 Hermes Agent

Hermes Agent 已运行在阿里云 ECS，端口 `:8642` 提供 OpenAI 兼容 API。授权服务器通过此 API 发送微信通知，无需安装额外 WeChat 客户端。

### A.2 Tailscale

所有机器已接入同一 Tailscale 网络。使用 Tailscale SSH 进行机器间通信（无需管理 SSH 密钥）。MagicDNS 提供 hostname 解析。

### A.3 配置管理模式

沿用 playground 现有模式：
- `data/` 目录下的实际配置被 `.gitignore` 忽略
- `*.TEMPLATE` 文件作为配置模板提交到 Git
- 安装脚本自动从 TEMPLATE 复制创建实际配置

### A.4 lib-tailnet.sh

重用 `scripts/mixapi/lib/lib-tailnet.sh` 中的 `ts_nodes()` 和 `check_port()` 函数进行 Tailscale 节点发现和端口探测。

---

## 附录 B：与已有方案的比较

| 特性 | fs-temp-user (已有) | mixapi-temp-user (已有) | pesudo (本方案) |
|------|---------------------|------------------------|-----------------|
| 触发方式 | SSH 手动创建 | API 调用创建 | 自动拦截 sudo |
| 凭据类型 | SSH 临时用户 | 临时密码 | 动态 OTP 授权 |
| 人类确认 | ❌ 无需确认 | ❌ 无需确认 | ✅ 微信 OTP |
| 密码存储 | SSH key | 临时密码 | AES-GCM 加密 |
| 注册方式 | 手动 | 手动 | 集中式命令行 |
| 自动发现 | ❌ 硬编码 | ❌ 硬编码 | ✅ Tailscale MDNS |
| 审计 | ❌ | ❌ | ✅ 完整日志 |
