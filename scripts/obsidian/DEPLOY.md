# Obsidian LiveSync + LLM Wiki 部署手册

> 目标：在一台全新服务器上，用脚本一键重建 **Obsidian 多端同步（CouchDB LiveSync）** 与 **LLM Wiki 知识飞轮（raw → wiki）** 全部服务。
> 当前生产环境：腾讯云 <tencent-ip>（Ubuntu，Docker 已装）。

---

## 1. 架构总览

```
Obsidian 多端 (Mac / Windows / iPhone)
        │ LiveSync (http://<服务器>:5984, db: my-vault)
        ▼
┌─────────────────────────────────────────────┐
│ 服务器 (<tencent-ip>)                      │
│                                             │
│  CouchDB 容器 (:5984)                       │
│    └── my-vault  ←── vault 全量明文数据      │
│                                             │
│  vault-raw-sync.service (sync-vault-raw.sh  │
│    --daemon, 每60s)                         │
│    └── 拉取 raw/*.md → /opt/llmwiki/sources/│
│                                             │
│  llmwiki-compile.timer (每5min)             │
│    └── 全量拉取 + llmwiki compile           │
│        → /opt/llmwiki/wiki/ (概念页+index)  │
│                                             │
│  wiki/ 产物经 LiveSync 反向同步回各设备      │
└─────────────────────────────────────────────┘
        │ 模型调用
        ▼
  vLLM qwen3.6-27b (公司 2225, headscale <company-ip>:8002)
  或 new-api 网关 (<aliyun-ip>:3000, 本地模型转发)
```

## 2. 前置条件

| 项 | 要求 |
|:---|:-----|
| 服务器 | Ubuntu 22.04+，公网 IP，root/sudo 权限 |
| Docker | 已安装（deploy-couchdb.sh 可自动装） |
| 模型端点 | vLLM（headscale 内网 `<company-ip>:8002`）或 new-api 网关，二者其一可达 |
| 安全组 | 放行 `5984/TCP`（CouchDB） |

## 3. 一键部署

### 3.1 远程部署（推荐，从任意机器执行）

```bash
cd playground
# 默认: 直连 vLLM（免费）
bash scripts/obsidian/deploy/deploy-all.sh --host <tencent-ip>

# 走 new-api 网关
bash scripts/obsidian/deploy/deploy-all.sh --host <tencent-ip> \
  --model-endpoint http://<aliyun-ip>:3000/v1 \
  --model-key <new-api-key>

# 指定 CouchDB 密码 / 使用 watch 即时编译
bash scripts/obians/deploy/deploy-all.sh --host tencent --couch-pass mypass --watch
```

脚本自动完成：CouchDB 容器 → my-vault 数据库 → llmwiki CLI → systemd 服务 → 凭据文件 → 验证。**幂等**，重复执行只补齐缺失组件。

### 3.2 分步部署（手动）

| 步骤 | 命令 | 说明 |
|:-----|:-----|:-----|
| 1. CouchDB | `bash scripts/obsidian/sync/deploy-couchdb.sh --host <tencent-ip>` | Docker 容器，密码自动生成 |
| 2. llmwiki | 上传代码后 `bash scripts/obsidian/wiki/deploy-llmwiki.sh` | Node 22 + llm-wiki-compiler |
| 3. systemd | `bash scripts/obsidian/runtime/deploy-systemd.sh --couch-pass <密码>` | 3 个单元 + /etc/llmwiki.env |

### 3.3 部署产物清单

| 产物 | 位置 |
|:-----|:-----|
| CouchDB 容器 | `couchdb:latest`，数据 `/opt/couchdb/data` |
| my-vault 数据库 | CouchDB 内 |
| llmwiki CLI | `/usr/local/node/bin/llmwiki`（v0.4.x） |
| wiki 项目 | `/opt/llmwiki/`（sources/ wiki/ .llmwiki/） |
| 同步脚本 | `/usr/local/bin/sync-vault-raw.sh` |
| systemd 单元 | `/etc/systemd/system/{vault-raw-sync,llmwiki-compile}.service` + `llmwiki-compile.timer`（watch 模式另有 `llmwiki-watch.service`） |
| 模型+凭据配置 | `/etc/llmwiki.env`（权限 600） |
| 连接信息 | `scripts/obsidian/configs/couchdb-connection.txt`（gitignored） |

## 4. 客户端接入（Obsidian）

1. 安装插件 **Self-hosted LiveSync**
2. 配置（与服务器连接信息一致）:

| 字段 | 值 |
|:-----|:---|
| URI | `http://<公网IP>:5984/`（**必须 http**，当前无 TLS） |
| Username | `admin` |
| Password | 部署输出的密码 |
| Database name | `my-vault` |

3. **端到端加密：保持关闭**（服务端明文存储，开启会导致解密失败）
4. 首次同步：插件设置 → **Fetch from remote server**
5. 多端 vault 名称保持一致（避免冲突副本）

## 5. 使用流程

```bash
# 手机/电脑 Obsidian 新建笔记存入 raw/ 目录
# → LiveSync 自动同步到 CouchDB
# → 服务器 60s 内拉取到 sources/
# → 5 分钟内自动编译为 wiki 概念页
# → wiki/ 同步回所有设备
```

```bash
# 手动操作（服务器）
source /etc/llmwiki.env          # 或 source /etc/profile.d/llmwiki.sh
llmwiki ingest <file-or-url>      # 手动摄入
llmwiki compile                   # 手动编译
llmwiki query "问题" --save       # 问答并存为 wiki/queries/
llmwiki lint                      # 质量检查（broken wikilink 等）
bash scripts/obsidian/wiki/llmwiki-archive-queries.sh   # 问答页归档为概念页
bash scripts/obsidian/wiki/llmwiki-clean.sh wiki        # 清理 qwen <think> 残留
```

## 6. 运维

### 服务状态

```bash
systemctl status vault-raw-sync      # raw 拉取守护
systemctl status llmwiki-compile.timer   # 5min 自动编译
journalctl -u llmwiki-compile -f     # 编译日志
```

### 设备标注

```bash
bash scripts/obsidian/ops/obsidian-devices.sh        # 各设备连接情况
# 编辑 scripts/obsidian/devices.conf 标注 IP → 设备名
```

### 凭据轮换

```bash
# 1. 改 CouchDB 密码（新密码 <NEW>）
docker exec couchdb curl -s -X PUT http://admin:<OLD>@127.0.0.1:5984/_node/_local/_config/admins/admin \
  -d '"<NEW>"'
# 2. 更新 /etc/llmwiki.env 与 configs/couchdb-connection.txt
# 3. 重启服务
sudo systemctl restart vault-raw-sync
```

## 7. 故障排查

| 症状 | 原因 | 处理 |
|:-----|:-----|:-----|
| 手机连不上 | URI 用了 https / 端口错 | 确认 `http://IP:5984`；安全组放行 5984 |
| 同步后全报解密错误 | 客户端开了 E2EE | 关闭端到端加密后重新 fetch |
| 编译报 `403 预扣费额度失败` | new-api key 余额不足 | new-api 后台给用户充值/设超大额度，或将 llmwiki 直连 vLLM |
| `llmwiki: node not found` | 交互 shell 缺 PATH | `source /etc/profile.d/llmwiki.sh`（已含 PATH） |
| wiki 有 `[[wikilinks]]` 断链 | LLM 生成的示例链接 | `llmwiki lint` 定位后手动修正 |
| 设备连上但不写数据 | vault 名不一致 | 各端 vault 名统一 |
