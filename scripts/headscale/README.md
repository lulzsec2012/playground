# Headscale 自建控制面（替代 Tailscale 云）

用 headscale 自建 Tailscale 控制面，取代官方 Tailscale 云服务，解决国内直连/中继不可用问题。

## 背景与目标

当前三台机器（Mac / 公司服务器 / 腾讯云 ECS）都接入了官方 Tailscale 云，存在：

- 官方控制面在国内不可达/不稳定（`netcheck` 显示 DERP 健康检查失败）
- 公司服务器走中继（`relay cn, rx 0`），直连失败
- 依赖外部云服务，无法自主控制

**目标**：headscale 自建控制面 + 内置 DERP 中继，三台机器互联。

## headscale 是什么角色

| 组件 | 角色 | 说明 |
|:-----|:-----|:-----|
| **headscale** | 控制面 (Control Plane) | 节点注册、身份认证、公钥交换、ACL 策略、节点发现。**不承载业务流量** |
| **tailscale (客户端)** | 数据面 (Data Plane) | 每台机器上的 `tailscaled`，通过 WireGuard 端到端加密直连 |
| **DERP** (headscale 内置) | 中继 (Relay) | 直连失败时的兜底数据通道（TLS 加密，但**看不到明文**，端到端加密仍在） |
| **STUN** (UDP 3478) | NAT 打洞辅助 | 帮助客户端发现公网映射，实现 P2P 直连 |

关键特性：headscale 只负责"介绍人"（协调），业务流量在节点间**端到端加密直传**，headscale 无法解密内容。

## 控制面部署位置选型（实测数据）

headscale 控制面**必须**能被所有节点随时访问（节点上线/重启/新节点加入时都要连它）。

| 候选位置 | 公司服务器可达? | 腾讯云可达? | 可用性 | 结论 |
|:---------|:--------------|:-----------|:-------|:-----|
| 当前 Mac | ❌ 家用 NAT 后 | ❌ | 非 24/7 | ✗ |
| 本地 NAS (Synology) | ❌ 家用 NAT 后 | ❌ | 24/7 | ✗ |
| 公司服务器 | ✅ (Mac 经 VPN) | ❌ 公司防火墙 | 24/7 | ✗ |
| **腾讯云 ECS 62.234.69.194** | ✅ 公网直达 | ✅ 公网直达 | 24/7 | ✅ |

**结论：控制面部署在腾讯云 ECS（唯一公网 IP 且三机均可达），并启用内置 DERP + STUN。**

> 注：62.234.69.194 即现有 tailnet 中的 `tencent-relay` 节点，其上曾运行一个 derper 中继
> （443/TCP + 3478/UDP，为旧官方 tailnet 部署）。headscale 上线后该 derper 已**停用并删除容器**，
> STUN 使用标准端口 **3478/UDP**。

## 直连可行性分析

- 公司网络为**对称 NAT**（`netcheck: MappingVariesByDestIP: true`）→ Mac ↔ 公司服务器 NAT 打洞大概率失败 → 必须走 DERP 中继
- Mac 家宽 NAT 类型良好（`MappingVariesByDestIP: false`，支持 UPnP/PMP/PCP）→ Mac ↔ 腾讯云 直连可行
- 结论：**腾讯云 DERP 是必须的兜底**，直连（打洞成功）时自动绕过 DERP

## 最终架构

```
                腾讯云 ECS 62.234.69.194
          ┌──────────────────────────────┐
          │  headscale 控制面 (:8443)     │
          │  内置 DERP 中继 (:8443)       │
          │  STUN (UDP :3478)            │
          │  (旧 derper :443 已停用)      │
          └──────────┬───────────────────┘
                     │ https (控制面 + DERP 兜底)
          ┌──────────┴──────────┐
          ▼                     ▼
    Mac (tailscale client)  公司服务器 (tailscale client)
    100.x.x.x                100.x.x.x
          └─── WireGuard 直连（打洞成功时）───┘
```

## 端口占用

| 端口 | 协议 | 服务 | 位置 | 说明 |
|:----:|:-----|:-----|:-----|:-----|
| 8443 | TCP | headscale 控制面 + DERP | 腾讯云 ECS | HTTPS，需安全组放行 |
| 3478 | UDP | STUN（NAT 打洞辅助） | 腾讯云 ECS | 需安全组放行 |
| 443 | TCP | 旧 derper（已停用） | 腾讯云 ECS | 容器已删除，端口空闲 |

## TLS 方案

headscale 内置 DERP 强制要求 `server_url` 为 HTTPS。当前无现成域名，采用**自签 CA**：

1. 控制服务器生成自签 CA + 服务器证书（SAN 含公网 IP）
2. CA 证书分发到每个客户端系统信任库（macOS Keychain / Linux ca-certificates）
3. 客户端 `tailscale up --login-server=https://62.234.69.194:8443`
4. 后续如有域名可平滑切换到 Let's Encrypt（headscale 支持 ACME）

## 部署步骤

### 1. 腾讯云 ECS — 控制面（headscale + DERP + STUN）

```bash
# 上传脚本到 ECS（或直接从 git 拉取 playground）
cd scripts/headscale
scp -r . ubuntu@62.234.69.194:/tmp/headscale-deploy/
ssh ubuntu@62.234.69.194
cd /tmp/headscale-deploy
sudo bash install-headscale.sh \
  --server-url https://62.234.69.194:8443 \
  --listen-addr 0.0.0.0:8443 \
  --derp-ipv4 62.234.69.194 \
  --user playground
```

脚本自动完成：下载安装 headscale (.deb) → 生成自签 CA/证书 → 写入配置 → systemd 启动 → 创建用户。

**注意**：需在腾讯云控制台安全组放行 `8443/TCP` 与 `3478/UDP`。

### 2. 生成预授权密钥（在 ECS 上）

```bash
sudo headscale preauthkeys create --user playground
# 输出: tskey-auth-xxxxxxxx  （一次性，有效 1 小时，可加 --expiration 调整）
```

### 3. Mac / 公司服务器 — 客户端加入

```bash
cd scripts/headscale
# 从 ECS 拉取 CA 证书:
scp ubuntu@62.234.69.194:/var/lib/headscale/certs/ca.crt /tmp/headscale-ca.crt

sudo bash join-client.sh \
  --server https://62.234.69.194:8443 \
  --authkey tskey-auth-xxxxxxxx \
  --hostname mac-mini \
  --ca /tmp/headscale-ca.crt
```

公司服务器同样执行（`--hostname ts-210-2225`）。

### 4. 验证

```bash
# 控制面查看节点
ssh ubuntu@62.234.69.194 sudo headscale nodes list

# 客户端互 ping（tailscale 内部 IP）
tailscale ping 100.x.x.x          # 输出 via direct 或 via DERP
ssh lulizhi@100.x.x.x             # 走 headscale 网络 SSH

# 查看直连/中继路径
tailscale netcheck
tailscale status
```

### 5. 容器化节点部署（原 scripts/tailscale 合并而来）

无需在主机安装客户端，以 Docker 容器加入 headscale 网络。
默认接入自建控制面 `https://62.234.69.194:8443`，三种模式：

```bash
# basic — 基础节点（仅加入网络）
HEADSCALE_AUTH_KEY=hskey-xxx bash deploy-node-container.sh basic -n my-node

# exit — Exit Node（出口代理）
HEADSCALE_AUTH_KEY=hskey-xxx bash deploy-node-container.sh exit -n my-exit

# subnet — Subnet Router（宣告内网路由）
HEADSCALE_AUTH_KEY=hskey-xxx bash deploy-node-container.sh subnet -n my-router -r 172.30.0.0/16
```

安全机制：密钥经 `/dev/shm` 临时文件传入容器，认证后立即清除；
state 持久化在 Docker volume，重启免认证。

> 注：原 `scripts/tailscale/` 目录已合并至此（deploy-node-container.sh + templates/ + extra/），
> 官方 tailscale 控制面部署脚本不再需要。

## 运维命令（register.sh 注册为 hs-* 别名）

| 命令 | 说明 |
|:-----|:-----|
| `hs-ctrl <args>` | 在 ECS 上执行 headscale 命令（SSH 包装） |
| `hs-nodes` | 节点列表 |
| `hs-users` | 用户列表 |
| `hs-keys` | 预授权密钥列表 |
| `hs-ping <ip>` | tailscale ping |
| `hs-status` | 本机 tailscale 状态 |

## NAS 跳板方案（Mac 经局域网接入 tailnet）

**背景**：Mac 本机 tailscale 客户端（macOS 网络扩展）对自签 CA 的信任加载存在系统限制。
**方案**：NAS 2221 容器 (ubuntu-lite) 部署 tailscale（userspace 模式 + SOCKS5 代理），
局域网内 Mac 经 NAS 代理访问 tailnet，延迟仅多 ~0.5ms（千兆内网）。

```
Mac ──局域网(≈0.5ms)──► NAS:1080 (SOCKS5) ──tailnet(DERP 12-38ms)──► 公司服务器 100.64.0.1
```

部署（已由脚本固化）:

```bash
# 一键部署（在 Mac 上执行）:
bash scripts/headscale/deploy-nas-jump.sh <preauthkey>

# Mac 使用（SOCKS5 指向 NAS）:
export ALL_PROXY="socks5h://192.168.50.179:1080"
ssh -o ProxyCommand="nc -X 5 -x 192.168.50.179:1080 %h %p" lulizhi@100.64.0.1
```

说明:
- 容器无 `/dev/net/tun`（内核 4.4），tailscaled 用 `--tun=userspace-networking` 纯用户态模式
- SOCKS5 监听 `0.0.0.0:1080`，容器重启后由 `/etc/rc.local` 自动拉起
- 当前节点: `ts-nas-hs` = 100.64.0.3

## 故障排查

- **`tailscale up` 报 TLS 错误** → CA 未信任，重跑 `join-client.sh`（或手动 `security add-trusted-cert`）
- **节点显示 offline** → 检查 ECS 8443 端口可达性：`nc -vz 62.234.69.194 8443`
- **全部走 DERP 无直连** → 公司网络对称 NAT 属预期，见上文分析
- **headscale 服务状态** → `systemctl status headscale`（ECS），日志 `journalctl -u headscale -f`
- **Mac 本机客户端失败** → 改用 NAS 跳板（见上），或重启 Mac 后运行 `join-mac.sh`
- **Mullvad VPN 开启后 hs-* 连接失败** → Mullvad 全隧道模式劫持局域网路由，执行 `lan-route-fix`（zshrc 已内置）手动添加 192.168.50.0/24 → en1 直连路由

## 后续扩展

- 迁移其他节点（NAS/手机/其他服务器）：同一 `join-client.sh`，新节点自动进入同一 tailnet
- 有域名后切换到 Let's Encrypt（headscale `acme` 配置），去掉自签 CA
- 配置 ACL 策略（headscale policy 命令）实现节点间访问控制
