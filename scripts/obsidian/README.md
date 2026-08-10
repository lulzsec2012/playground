# Obsidian

跨平台 Obsidian 安装、配置与 OpenCode 集成方案。

```
scripts/obsidian/
├── deploy/                  # ① 部署编排
│   └── deploy-all.sh        # 一键部署全链路（本机 / 远程 --host）
├── sync/                    # ② LiveSync 同步（server: 腾讯云）
│   ├── deploy-couchdb.sh    # CouchDB 服务端部署（Docker + 凭据生成）
│   ├── sync-vault-raw.sh    # CouchDB → sources/ 增量拉取（15s 守护）
│   └── sync-wiki-push.sh    # wiki/ 产物 → CouchDB 写回（LiveSync 格式, 30s）
├── wiki/                    # ③ LLM Wiki 编译（server: 腾讯云）
│   ├── deploy-llmwiki.sh    # 编译器 + 模型链路部署（vLLM / new-api）
│   ├── wiki-process.sh      # ⚠️ 已废弃（llmwiki 替代），仅历史参考
│   ├── setup-wiki-schema.sh # vault LLM Wiki 骨架初始化（复数命名）
│   ├── llmwiki-archive-queries.sh  # 问答页归档为概念页
│   └── llmwiki-clean.sh     # 清理 qwen <think> 残留
├── client/                  # ④ 客户端配置（client: Mac / vault）
│   ├── install.sh           # 跨平台 Obsidian 安装（brew / --cli-only）
│   ├── vault.sh             # vault 初始化 + .obsidian/ 默认配置
│   ├── setup-ai-plugins.sh  # 阶段1: AI 插件安装
│   └── setup-ai-config.sh   # 阶段1: AI 模型配置
├── runtime/                 # ⑥ 运行时托管（server，②③ 共享）
│   └── deploy-systemd.sh    # systemd 单元 + /etc/llmwiki.env
├── ops/                     # ⑤ 运维监控（server）
│   ├── obsidian-devices.sh  # 客户端设备标注 / 实时查看
│   └── register.sh          # CLI 工具 PATH 注册
├── config/                  # AI 配置模板
│   └── ai-providers.data.json  # AI Providers 配置模板
├── clipper/                 # Web Clipper 模板
│   ├── ai-summarize.json   # 阶段2: 快速总结模板
│   └── ai-deep-read.json   # 阶段2: 深度精读模板
└── wiki-schema/
    └── AGENTS.md           # 阶段3: LLM Wiki 维护规则
```

---

## 安装

```bash
# macOS: 安装 Obsidian GUI + CLI 工具
bash scripts/obsidian/client/install.sh

# Linux: 安装 CLI 工具 (headless 容器用)
bash scripts/obsidian/client/install.sh --cli-only

# 初始化 vault
bash scripts/obsidian/client/vault.sh /path/to/vault
```

---

## OpenCode 集成方案

以下三种方案按推荐度排列，可组合使用。

---

### 方案 A: `with-context-plugin` ← **首选**

OpenCode 插件，让 AI 直接读写 Obsidian vault，边写代码边记笔记。

| 方面 | 说明 |
|---|---|
| **仓库** | [boxpositron/with-context-plugin](https://github.com/boxpositron/with-context-plugin) |
| **原理** | OpenCode 插件 → REST API (27124端口) → Obsidian 本地 vault |
| **AI 工具** | `write_note`, `read_note`, `search_notes`, `add_todo`, `add_changelog_entry`, `start_session` |
| **适用** | 写代码时 AI 自动记录 session、变更日志、Todo 到 vault |

**安装**:
```bash
# 1. Obsidian 内安装 Local REST API 插件 (coddingtonbear)
#    设置 → 第三方插件 → 社区插件 → 搜索 "Local REST API"

# 2. 获取 API Key，设置环境变量
export OBSIDIAN_API_URL="https://127.0.0.1:27124"
export OBSIDIAN_API_KEY="复制你的key"
export OBSIDIAN_VAULT="你的Vault名称"

# 3. 复制插件到 OpenCode
cp -r with-context-plugin ~/.config/opencode/plugin/with-context

# 4. 重启 OpenCode，AI 即可读写 vault
```

**工作流**:
```
你写代码 → OpenCode 自动 start_session
         → 每次改完文件 AI 执行 add_changelog_entry
         → 生成的文档自动 write_note 进入 vault
         → 遗留任务自动 add_todo
```

---

### 方案 B: `opencode-obsidian-sync`

将 OpenCode 会话历史自动同步到 Obsidian 中，形成可搜索的 AI 编码知识库。

| 方面 | 说明 |
|---|---|
| **仓库** | [xeaser/opencode-obsidian-sync](https://github.com/xeaser/opencode-obsidian-sync) |
| **原理** | OpenCode session JSON → Markdown → 写入 vault (REST API) |
| **输出** | `summary.md` + `raw-log.md` 结构化笔记 |
| **需插件** | Obsidian: Dataview (仪表盘), Local REST API |
| **适用** | 积累 AI 编码历史，方便回溯 |

**特性**:
- 历史批量导入 + 实时同步
- Dataview 面板：按项目/日期/成本展示会话
- 自动标签：`topic/auth`, `tech/typescript`, `activity/bugfix`
- AI 获得 `search_session_logs` 工具，可检索历史会话

**安装**:
```bash
# 1. Obsidian 安装 Local REST API + Dataview 插件
# 2. 配置 REST API key + vault 名称
# 3. 运行导入脚本
npx tsx import.ts  # 批量导入历史会话
# 4. 安装 oh-my-opencode 插件启动实时同步
```

---

### 方案 C: `opencode-obsidian` (Obsidian 侧边栏)

在 Obsidian 侧边栏中嵌入 OpenCode，写笔记时直接和 AI 对话。

| 方面 | 说明 |
|---|---|
| **仓库** | [windyboy/opencode-obsidian](https://github.com/windyboy/opencode-obsidian) |
| **原理** | Obsidian 插件 → HTTP/SSE → OpenCode Server |
| **能力** | 侧边栏对话、vault 读写（权限控制）、自定义 Agent/Skill |
| **适用** | 写笔记时需要 AI 辅助写作、提炼、查询 |

**安装**:
```bash
# 1. 复制插件到 vault
cp -r opencode-obsidian <vault>/.obsidian/plugins/
# 2. 在 Obsidian 中启用
# 3. 配置 OpenCode Server URL (如 http://127.0.0.1:4096)
# 4. 设置工具权限: read-only / scoped-write / full-write
```

---

---

## 方案 D: Self-hosted LiveSync (多设备同步)

使用 CouchDB 实现 Obsidian 多设备（电脑 + 手机）无缝同步。

### 架构

```
┌─ macOS ─┐     ┌─ Windows ─┐     ┌─ iOS/Android ─┐
│ Obsidian │     │ Obsidian  │     │ Obsidian      │
│ LiveSync │     │ LiveSync  │     │ LiveSync      │
└────┬─────┘     └─────┬─────┘     └──────┬────────┘
     └────────┬────────┘──────────────────┘
              │ HTTP / HTTPS
              ▼
   ┌─────────────────────┐
   │  CouchDB (Docker)   │
   │  服务器: <tencent-ip> │
   │  端口: 5984          │
   │  数据: /opt/couchdb/ │
   └─────────────────────┘
```

### 部署

```bash
# 一键部署到腾讯云服务器
bash scripts/obsidian/sync/deploy-couchdb.sh --host <tencent-ip>

# 部署后输出连接信息:
#   URI:      http://<tencent-ip>:5984/
#   Username: admin
#   Password: <自动生成>

# 查看部署状态
bash scripts/obsidian/sync/deploy-couchdb.sh --status

# 卸载
bash scripts/obsidian/sync/deploy-couchdb.sh --remove
```

### 客户端配置

1. **安装插件**: Obsidian 社区插件 → 搜索 "Self-hosted LiveSync"
2. **配置连接**:

| 字段 | 值 |
|------|-----|
| URI | `http://<tencent-ip>:5984/` |
| Username | `admin` |
| Password | 部署时生成的密码 |
| Database name | `my-vault`（自定义） |

3. **首次同步**: 保存后插件自动创建数据库并开始同步

### 服务端同步流水线（LLM Wiki 数据流）

```
Obsidian 多端 (Mac/Windows/iPhone)
        │ LiveSync
        ▼
   CouchDB my-vault (腾讯云 <tencent-ip>:5984, Docker)
        │ sync-vault-raw.sh --daemon (systemd vault-raw-sync.service, 每15s)
        ▼
   /opt/llmwiki/sources/  (raw/ 素材镜像)
        │ llmwiki watch (systemd llmwiki-watch.service, 变更即时编译)
        ▼
   /opt/llmwiki/wiki/  (LLM 整理产物)
        │ sync-wiki-push.sh --daemon (systemd sync-wiki-push.service, 每30s)
        ▼
   CouchDB my-vault → LiveSync → 各设备可见 wiki/ 目录
```

腾讯云上的 systemd 服务:

| 服务 | 作用 |
|:-----|:-----|
| `vault-raw-sync.service` | `sync-vault-raw.sh --daemon`，增量拉取 raw/ 到 sources/（15s，可用 `SYNC_INTERVAL` 覆盖） |
| `llmwiki-watch.service` | `llmwiki watch` 监视 sources/ 变更**即时编译**（当前主编译通道） |
| `llmwiki-compile.timer` | 每 5 分钟兜底编译（watch 异常时仍能出产物） |
| `sync-wiki-push.service` | `sync-wiki-push.sh --daemon`，把 wiki/ 产物以 LiveSync 格式**写回 CouchDB**（30s，增量+删除同步） |

> 关键脚本: `sync/sync-vault-raw.sh`（CouchDB → sources 拉取）+ `sync/sync-wiki-push.sh`（wiki → CouchDB 写回）。

### 运维工具

```bash
# 设备标注（IP → 设备名，里程碑节点 → 客户端上报的设备名）
bash scripts/obsidian/ops/obsidian-devices.sh        # 最近 1h 连接标注
bash scripts/obsidian/ops/obsidian-devices.sh 3h     # 指定时间窗口

# 注册表: scripts/obsidian/devices.conf（新增设备加一行 "IP 设备名"）
```

### 凭据管理

脚本统一按以下优先级读取 CouchDB 凭据（**代码库不含明文密码**）:

1. 环境变量 `COUCHDB_USER` / `COUCHDB_PASSWORD`（systemd `EnvironmentFile=/etc/llmwiki.env` 或手动 export）
2. `scripts/obsidian/configs/couchdb-connection.txt`（gitignored，部署时生成）

`deploy-couchdb.sh` 部署时输出连接信息并写入 `configs/couchdb-connection.txt`（已 gitignore，不会提交）。

### 注意事项

| 场景 | 说明 |
|:----|:------|
| **桌面版** | HTTP 直连可用 |
| **移动端** | iOS/Android 强制 HTTPS，需后续配置反向代理 |
| **安全** | 当前端口直接暴露公网，建议配合反向代理 + HTTPS |

### 后续步骤

1. **反向代理**: 配置 Caddy/Nginx 提供 HTTPS（移动端需要）
2. **Tailscale**: 如果服务器接入 Tailscale，可通过 Tailscale IP 连接（更安全）
3. **升级评估**: 若考虑迁移到 Syncthing（删除传播/版本恢复/脚本简化），见 [SYNC-UPGRADE-NOTES.md](SYNC-UPGRADE-NOTES.md)（含 iPhone 端 Möbius Sync 差距分析与决策框架）

---

## LLM 自动整理知识 — 三阶段落地

结合 MixAPI 网关（默认，qwen3.6-27b 本地模型）+ DeepSeek（备用），零订阅实现 AI 知识整理。

### 模型链路（已打通）

```
Obsidian (Copilot/AI Providers)
    │  http://<aliyun-ip>:3000/v1 (new-api 公网)
    ▼
new-api 网关 (阿里云 <aliyun-ip>, 容器 new-api)
    │  headscale 内网 (<company-ip>:8002)
    ▼
vLLM qwen3.6-27b (公司 2225 容器, 8×RTX4090)
```

- **默认模型**: `qwen3.6-27b`（本地，免费，中文强）
- **备用模型**: `deepseek-v4-flash`（DeepSeek API）
- **new-api 渠道**: `vllm-qwen` → `http://<company-ip>:8002`（headscale IP）+ `deepseek` 渠道
- **注意**: baseUrl 必须带 `/v1` 后缀（否则 SDK 请求走 web 路由而非 relay，tool_call 失效）
- **tool_calls**: new-api 已修复透传（替代 MixAPI），llmwiki 可直接走网关

### 阶段 1: Obsidian 内 AI 插件

```bash
# 1. 安装插件 (Copilot + AI Providers + Local GPT)
bash scripts/obsidian/client/setup-ai-plugins.sh /path/to/vault

# 2. 生成模型配置 (DeepSeek / MixAPI / 本地 vLLM)
DEEPSEEK_API_KEY=sk-xxx bash scripts/obsidian/client/setup-ai-config.sh /path/to/vault
```

**Obsidian 内操作**: 设置 → 第三方插件 → 启用 copilot / ai-providers / local-gpt
→ AI Providers 确认三个 provider → Copilot 选 DeepSeek 为默认模型。

### 阶段 2: 剪藏自动总结入库

安装 **Obsidian Web Clipper** (浏览器扩展)，导入模板:

| 模板 | 用途 |
|:-----|:-----|
| `clipper/ai-summarize.json` | 快速总结入库（核心观点 + 关键细节）|
| `clipper/ai-deep-read.json` | 深度精读（论点/证据/局限/相关概念）|

模板的 `{{#interpreter}}` 块自动调 DeepSeek 总结，结果存入 `0. Inbox/`。

### 阶段 3: LLM Wiki 知识飞轮 (Karpathy 模式)

**采用现成工具 [llm-wiki-compiler](https://github.com/atomicstrata/llm-wiki-compiler)（npm CLI，无 GUI 依赖，适合腾讯云无头部署）**，
替代手写脚本。已部署于腾讯云 <tencent-ip> `/opt/llmwiki`，模型走 vLLM qwen3.6-27b（公司 2225，headscale 内网直连）。

```bash
# 部署（腾讯云，已执行完成）
bash scripts/obsidian/wiki/deploy-llmwiki.sh /opt/llmwiki

# 使用
source /etc/profile.d/llmwiki.sh     # 已配好: provider/model/base_url
llmwiki ingest <file-or-url>          # 摄入材料 → sources/
llmwiki compile                       # 增量编译为 wiki 页 (自动处理长文)
llmwiki watch                         # 自动监控 sources/ 变更并重编译
llmwiki query "问题"                   # 基于 wiki 问答 (带 wikilink 引用)
llmwiki lint                          # 质量检查
bash scripts/obsidian/wiki/llmwiki-clean.sh wiki   # 清理 qwen think 残留
```

**关键配置**（注意坑）:

| 项 | 值 | 说明 |
|:---|:---|:-----|
| `LLMWIKI_PROVIDER` | `openai` | 使用 OpenAI 兼容 provider |
| `LLMWIKI_MODEL` | `qwen3.6-27b` | 默认 gpt-4o 必须改 |
| `OPENAI_BASE_URL` | `http://<company-ip>:8002/v1` | **必须带 /v1 后缀** |
| `OPENAI_API_KEY` | `sk-local` | vLLM 不校验 |

**已知限制**:
- MixAPI 网关不透传 tool_calls → llmwiki 需**直连 vLLM**（Obsidian 插件走 MixAPI 不受影响）
- qwen 输出含 `<think>` 块（无闭合标签）→ 需 `llmwiki-clean.sh` 后处理
- `watch` 模式用 `nohup llmwiki watch &` 或 systemd 常驻

**与手写脚本对比**: llmwiki 自动处理长文档分块、concept 提取、wikilink 解析、
index 生成、review 审核队列、MCP server——功能完整且维护活跃，推荐长期使用。

---

## 组合推荐

```
macOS 本机:
  Obsidian GUI
    ├── Self-hosted LiveSync  ←→  CouchDB (方案D: 多设备同步)
    ├── Local REST API 插件   ←→  with-context-plugin (方案A: AI 读写 vault)
    ├── Dataview 插件         ←→  opencode-obsidian-sync (方案B: 会话知识库)
    └── opencode-obsidian      (方案C: 侧边栏对话)

Linux 容器 (<dev-host2-ip>:2222):
  无 GUI → obsidian-export CLI
  vault 目录同步到容器
  OpenCode 直接读取 .md 文件作为知识库上下文
```

---

## 目录结构

```
vault/
├── .obsidian/
│   ├── config              # 应用设置
│   ├── appearance.json     # 主题设置
│   ├── community-plugins.json
│   ├── plugins/            # 社区插件
│   ├── themes/             # CSS 主题
│   └── snippets/           # CSS 片段
├── daily/                  # 日常笔记
├── projects/               # 项目笔记
└── reference/              # 知识库
```
