# MIXAPI — AI 大模型网关 & 服务网格

基于 [MIXAPI v2.5.1cl](https://github.com/aiprodcoder/MIXAPI) 的 AI 网关，部署在阿里云 ECS 上。
自动发现 tailnet 中的 LLM 推理节点，同步为渠道，提供统一 API 入口。

---

## 目录结构

```
scripts/mixapi/
├── Dockerfile                      # 镜像构建（alpine + 二进制 COPY）
├── setup.sh                        # 一键部署（构建镜像 + 启动容器）
├── mixapi.sh                       # 统一管理入口
├── discover.sh                     # 扫描 tailnet LLM 服务（713行）
├── channel.sh                      # 同步服务到 MIXAPI 渠道（385行）
├── test.sh                         # LLM 模型推理测试（481行）
├── add-account.sh                  # 管理员账号管理
│
├── lib/
│   ├── lib-format.sh               # 彩色日志输出
│   ├── lib-mixapi.sh               # MIXAPI API 封装 + 凭证管理（523行）
│   └── lib-tailnet.sh              # Tailscale 操作封装
│
├── ../fileserver/client/mixapi-temp-user  # 临时密码客户端（同 repo）
│
└── README.md                       # ← 本文件
```

---

## 架构

```
                   ┌──────────────────────────────────┐
                   │      阿里云 ECS (39.102.52.1)     │
                   │                                  │
                   │  ┌──────────────────────────┐    │
                   │  │  MIXAPI (Docker) :3000    │    │
                   │  │  ┌────────┐ ┌──────────┐ │    │
                   │  │  │ root   │ │ channels │ │    │
                   │  │  │ (admin)│ │ ┌──────┐ │ │    │
                   │  │  │        │ │ │ollama│ │ │    │
                   │  │  │ sync-  │ │ │vLLM  │ │ │    │
                   │  │  │ worker │ │ │TGI   │ │ │    │
                   │  │  └────────┘ │ └──────┘ │ │    │
                   │  └──────────┬───┴──────────┘ │    │
                   │             │                 │    │
                   │  ~/.mixapi/ │ 持久化数据       │    │
                   │  ├── .credentials   ─── root/  │    │
                   │  │                     sync-   │    │
                   │  ├── services.json ── 扫描结果 │    │
                   │  └── cron.log      ── 定时日志 │    │
                   │                                  │
                   └─────────┬────────────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         tailscale     统一API       联合云通道
         SSH执行       :3000        (OpenAI等)
```

### 用户设计

| 用户 | 角色 | 用途 |
|------|------|------|
| `root` | 管理员 (role=100) | Web UI 登录、配置管理、创建用户 |
| `sync-worker` | 服务账户 (role=10) | `discover.sh`/`channel.sh` 自动同步用 |

### 数据存储

| 文件 | 内容 |
|------|------|
| `~/.mixapi/.credentials` | root + sync-worker 密码 |
| `~/.mixapi/services.json` | tailnet LLM 节点扫描结果 |
| `~/.mixapi_data/mix-api.db` | MIXAPI 数据库（用户、渠道、Token） |
| `~/.mixapi_data/logs/` | 容器日志 |

---

## 部署

### setup.sh — 一键部署

```bash
./setup.sh
```

构建 Docker 镜像 + 启动容器。二进制从 GitHub Release 预下载，使用清华镜像加速。
容器映射 `~/.mixapi_data/` → `/data`，数据库和日志持久化在宿主机。

```bash
# 手动启动（已有镜像时）
docker run -d --name mixapi --restart always \
  -p 3000:3000 \
  -v ~/.mixapi_data:/data \
  -e TZ=Asia/Shanghai \
  mixapi:latest
```

---

## 使用流程

### mixapi.sh — 统一入口

**初始化（首次）**:

```bash
./mixapi.sh init
```

分 7 步：
1. 部署容器（调用 setup.sh）
2. 等待 API 就绪
3. 创建 root 账号（随机密码）
4. 创建 sync-worker 账号（随机密码）
5. 生成 API Token（`sk-...`）
6. 保存凭证到 `~/.mixapi/.credentials`
7. 提示后续操作

**扫描 LLM 节点**:

```bash
./mixapi.sh discover          # 手动全量扫描
./mixapi.sh discover --force  # 强制全量扫描
```

**同步为渠道**:

```bash
./mixapi.sh channel           # 扫描结果 → MIXAPI 渠道
./mixapi.sh channel --dry-run # 预览变更，不执行
```

**查看状态**:

```bash
./mixapi.sh status            # 显示发现的 LLM 服务
```

**安装自动同步**:

```bash
./mixapi.sh cron-install      # crontab 每 5 分钟增量扫描 + 同步
./mixapi.sh cron-remove       # 移除 cron
```

**测试模型**:

```bash
./mixapi.sh test              # 交互式选择模型测试
./mixapi.sh test --all        # 测试所有活跃服务
```

**管理员账号**:

```bash
./mixapi.sh add-account       # 创建新管理员
./mixapi.sh add-account --only-change-root  # 修改 root 密码
```

### discover.sh — LLM 服务发现

扫描 tailnet 中的所有在线节点，检测 LLM 推理服务。

**探测范围**:

| 端口 | 服务 | 说明 |
|------|------|------|
| 11434 | Ollama | 最常用的本地推理引擎 |
| 8000 | vLLM | 高性能推理服务 |
| 80 | TGI | HuggingFace TGI |
| 8080 | TGI-alt | 备用端口 |
| 8188 | ComfyUI | 图像生成 |
| 3000 | Open WebUI | Web 聊天界面 |
| 5000 | Text-gen | 文本生成 |

**扫描模式**:

| 模式 | 触发条件 | 间隔 |
|------|---------|------|
| 全量 | `--full` 或 `--force` | 扫描所有节点 × 所有端口 |
| 增量 | `--cron`（默认） | 不扫描，只检查活跃节点 |
| 自适应 | `--cron` 自动 | 有活跃节点：5min；无：30min |

**增量扫描策略**:
- 跳过已知 non-LLM 节点
- 只对 `active_serve_port` 列表中的端口做连通性检查
- 连续 N 次未响应 → 标记为 `withdraw`，不再探测
- 每轮至少扫描 `MIN_SCAN_PER_CYCLE=2` 个服务

### channel.sh — 渠道同步

将 `services.json` 中的活跃服务同步到 MIXAPI 渠道。

**同步策略**:
- 读取 `services.json` → 生成期望渠道列表
- 对比 MIXAPI 现有渠道（diff）
- 新增的 → `POST /api/channel/`
- 模型变化的 → `PUT /api/channel/{id}`
- 已下线的 → 标记 `status=0`（非删除）
- 使用 `tag=auto-sync` 标记自动同步的渠道

**渠道类型**:

| 服务 | MIXAPI 类型 | API Key |
|------|------------|---------|
| Ollama | type=4 | `ollama` |
| vLLM/其他 | type=1 | `sk-placeholder` |

### test.sh — 模型推理测试

对发现的 LLM 服务执行推理可用性测试。

**测试指标**:
- 端口连通性
- 模型存在性
- 冷启动时间（首次加载）
- 热启动时间（已缓存）
- 推理速度 (tok/s)
- 响应完整性

### add-account.sh — 账号管理

```bash
# 创建新管理员（交互式）
./add-account.sh

# 只修改 root 密码
./add-account.sh --only-change-root
```

使用 sync-worker 凭证创建新用户，或修改 root 密码。

---

## 临时密码

当需要临时分享 MIXAPI 访问权限时：

```bash
# 在 Tailscale 网络内的机器上
FS_HOST=fileserver FS_SSH_USER=lzlu bash mixapi-temp-user 4h
```

输出:
```
URL:      http://fileserver:3000/login
Username: root
Password: 31894256
Expires:  4h
```

原理：SSH 到 ECS → 修改 root 密码为 8 位数字 → 到期恢复原密码。
恢复由 `fs-share-cleanup.sh` crontab（每 5 分钟）自动处理。

---

## 安全说明

| 项目 | 说明 |
|------|------|
| **公网暴露** | 仅端口 3000（MIXAPI Web UI + API）；有用户名密码认证 |
| **内网通信** | Tailscale 加密隧道 |
| **凭证存储** | `~/.mixapi/.credentials` 权限 600，仅当前用户可读 |
| **最小权限** | sync-worker 角色 10，不能管理用户或修改配置 |
| **临时密码** | 8 位数字 + TTL，到期自动恢复原始随机密码 |
| **渠道认证** | 自动同步使用 API Token，不传输密码 |

---

## 常见问题

### MIXAPI 容器重启后密码失效

容器启动时会从数据库中读取用户配置。如果数据库权限异常（如被 root 用户写入），容器内进程可能无法读取。确认 `~/.mixapi_data/mix-api.db` 权限为 `644`。

### 登录提示"用户名或密码错误"

```bash
# 检查凭证文件
cat ~/.mixapi/.credentials

# 测试登录
curl -s -X POST http://localhost:3000/api/user/login \
  -H "Content-Type: application/json" \
  -d '{"username":"root","password":"<密码>"}'
```

如果凭证文件与数据库不一致，用 sqlite3 重置：

```bash
sudo sqlite3 ~/.mixapi_data/mix-api.db \
  "UPDATE users SET password='<bcrypt_hash>' WHERE username='root';"
```

### 429 Too Many Requests

MIXAPI 有内置请求频率限制。连续快速登录会触发。等待 30 秒或重启容器：

```bash
docker restart mixapi
```

### 没有 vLLM 节点在线

扫描结果为空的排查步骤：

```bash
tailscale status                    # 确认 tailnet 有在线节点
./discover.sh --full                # 强制全量扫描
# 在目标节点上检查:
systemctl status vllm               # vLLM 是否运行
ss -tlnp | grep 8000               # 端口是否监听
```

---

## 相关文档

- `scripts/fileserver/README.md` — 文件服务器（共享存储 + Tailscale）
- `scripts/fileserver/client/mixapi-temp-user` — 临时密码脚本
- `file-server-plan.md` — 完整设计文档（含文件服务器）
