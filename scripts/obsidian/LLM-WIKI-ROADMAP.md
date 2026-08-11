# LLM-Wiki 综合部署方案（Karpathy 模式）+ OpenCode 集成

> 状态: 实施中（P0 主链路已跑通，OpenCode 集成待实施）
> 日期: 2026-08-10
> 目标: Obsidian 中插入素材 → LLM 自动整理 → 高质量 wiki，全端同步；开发服务器 OpenCode 直连读写

---

## 0. 进度总览

| 板块 | 状态 | 说明 |
|:-----|:-----|:-----|
| 阶段 1: 本地体验 | ✅ 80% | green-dalii 插件 + provider 配置完成 |
| 阶段 2: 云端自动编译 | ✅ 100% | llmwiki + systemd + 同步桥全部跑通 |
| 阶段 3: 多源采集 | 🟡 60% | Web Clipper/目录批量 ✅；微信导入、主题抓取待办 |
| 阶段 4: 链接自动识别 | ⬜ P2 暂缓 | 待评估 |
| 阶段 5: 提问转 wiki | ✅ 100% | query --save + 归档脚本完成 |
| 阶段 6: NotebookLM 增强 | ⬜ P2 可选 | 待评估 |
| **OpenCode 集成** | ⬜ **待实施** | 方案已定（§9），6 步落地 |

**P0 主链路已闭环**：`Obsidian 写入 → LiveSync → CouchDB → sync-vault-raw(60s) → sources/ → llmwiki compile(5min) → wiki/`

---

## 1. 需求总览

| # | 需求 | 优先级 |
|:--|:-----|:-------|
| 1 | 参考 Karpathy 思路（raw→wiki→trusted 三层）| P0 |
| 2 | 使用开源高质量工具，高完成度 | P0 |
| 3a | Obsidian 编写内容自动整理 | P0 |
| 3b | 微信等文章导入（含链接自动识别）| P1（链接识别 P2）|
| 3c | MD 文件/目录批量导入 | P1 |
| 3d | 主题自动从网络抓取 | P1 |
| 4 | 输出高质量 wiki，随资料增长完善，**连接原始来源** | P0 |
| 5 | 提问/感兴趣话题整理成 wiki | P1 |
| 6 | 跨平台（依赖 Obsidian 多端 + LiveSync）| P0 |
| 7 | NotebookLM 类增强（可选）| P2 |
| 8 | **开发服务器 OpenCode 读写 vault + 会话沉淀**（§9）| P1 |

---

## 2. 架构总览

```
┌─────────────────────────────────────────────────────────┐
│  ① 输入层                                                │
│  Obsidian笔记 / 微信剪藏 / MD+目录 / 主题抓取 / URL批量     │
│  + OpenCode 会话沉淀（开发服务器，§9）                     │
└──────────────┬──────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────┐
│  ② 处理层 (Karpathy 三层)                                │
│  raw/ → wiki/ → trusted/                                 │
│  模型: new-api 网关 (qwen3.6-27b 本地 + DeepSeek 备用)     │
└──────────────┬──────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────┐
│  ③ 存储层 (自建同步)                                      │
│  Obsidian Vault ↔ CouchDB LiveSync (腾讯云 <tencent-ip>) │
└──────────────┬──────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────┐
│  ④ 使用层 (跨平台)                                       │
│  Obsidian 多端 (Mac/Win/iOS/Android) + SurfSense(可选)    │
│  + OpenCode (开发服务器, remote MCP 直连)                 │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 工具选型与职责划分

### 3.1 工具矩阵

| 工具 | ⭐ | 角色 | 状态 |
|:-----|:---|:-----|:-----|
| **atomicstrata/llm-wiki-compiler** | 1.9k | **云端编译主力**（腾讯云 /opt/llmwiki）| ✅ 已部署 |
| **green-dalii/obsidian-llm-wiki** | 435 | **本地体验**（Obsidian 插件，手动 Ingest/问答/Lint）| ✅ 已安装 |
| **nashsu/llm_wiki** | 16k | **多源采集+Deep Research**（未来主引擎候选）| 🔲 待评估 |
| kytmanov/olw → Synto | 795/229 | 双模型轻量方案 | ⚠️ olw 维护模式，暂缓 |
| **SurfSense** | 15.8k | NotebookLM 类 Web 问答（可选）| 🔲 待评估 |
| **Obsidian LiveSync** | — | 全端同步 | ✅ 已部署 |
| **new-api 网关** | 44.7k | 模型路由（qwen3.6-27b + DeepSeek）| ✅ 已部署 |
| **cyanheads/obsidian-mcp-server** | 655 | OpenCode 集成 MCP（filesystem + Streamable HTTP）| 🔲 待部署（§9）|

### 3.2 职责边界（避免冲突）

```
目录          负责工具                         说明
────────────────────────────────────────────────────────
raw/sources/  nashsu(采集) + 用户(手动丢)       输入汇聚点
wiki/         atomicstrata 或 nashsu (二选一)   ★ 单一写者原则
trusted/      人工审核                         LLM 标记，人确认
.obsidian/    green-dalii                     本地插件配置
opencode/     obsidian-mcp-server + writeback  AI 笔记/会话沉淀（§9.3）
```

**★ 核心规则：同一时间只有一个工具写 wiki/**。当前阶段：atomicstrata 为主编译引擎；nashsu 若启用则切换为本地主引擎（互斥）。OpenCode 写入限定 `opencode/` 子目录，与人工编辑区隔离。

---

## 4. 阶段化实施计划

### 阶段 1：本地体验（P0，已完成 80%）

**目标**: Obsidian 内可手动 Ingest + 问答

- [x] 安装 green-dalii 插件（社区插件 "Karpathy LLM Wiki"）
- [x] 配置 provider → new-api (http://<aliyun-ip>:3000/v1)
- [x] 验证: 打开笔记 → ribbon 图标 → Ingest → wiki/ 生成
- [x] 验证 Lint + Smart Fix All（llmwiki lint 可用，发现 broken wikilink 待清理）
- [x] 配置 DeepSeek 作为备用 provider（new-api 已含 deepseek 渠道）
- [ ] **待办**: 清理 broken wikilink（lint 发现的遗留项）

### 阶段 2：云端自动编译（P0，已完成）

**目标**: 材料进 sources/ 自动编译

- [x] 腾讯云部署 atomicstrata llmwiki (/opt/llmwiki)
- [x] 配置 new-api 网关（tool_call 已修复）
- [x] 验证: ingest → compile → query
- [x] 配置云端自动编译（`llmwiki-watch.service` 即时编译为主，`llmwiki-compile.timer` 每 5min 兜底）
- [x] raw/ 与 vault 的同步桥（`sync/sync-vault-raw.sh` + `vault-raw-sync.service`，15s 增量拉取）
- [x] **wiki/ 产物写回客户端**（`sync/sync-wiki-push.sh` + `sync-wiki-push.service`，30s 增量推送 + 删除同步）

### 阶段 3：多源采集（P1，60%）

**目标**: 微信/网页/目录批量导入

- [ ] **待办**: 微信导入方案（见 §5，推荐路径 5.2）
- [x] Obsidian Web Clipper 配置（模板已就绪 `clipper/*.json`；浏览器端导入模板即可）
- [x] 目录批量导入（`for f in dir/*.md; do llmwiki ingest $f; done`，见 DEPLOY.md）
- [ ] **待办**: 主题抓取（nashsu Deep Research 或 SearXNG + 脚本）

### 阶段 4：链接自动识别（P2，暂缓）

**目标**: 带链接的文件自动识别并导入链接文章

- [ ] 评估 nashsu URL 批量导入
- [ ] 链接提取脚本（扫描 md 中的 URL → 批量 ingest）
- [ ] 微信文章链接自动抓取

### 阶段 5：提问转 wiki（P1，已完成）

**目标**: 提问/兴趣话题整理成 wiki

- [x] `llmwiki query --save`（atomicstrata 已支持）
- [x] 定期将 queries/ 归档到 wiki/concepts/（`wiki/llmwiki-archive-queries.sh`）

### 阶段 6：NotebookLM 增强（P2，可选）

- [ ] 评估 SurfSense 部署（Docker）
- [ ] 接入 new-api 模型
- [ ] 与 vault 同步（读 wiki/ 目录）

---

## 5. 微信导入方案（手机端重点）

### 5.1 方案选型

| 方案 | 操作 | 优点 | 缺点 |
|:-----|:-----|:-----|:-----|
| **A. Obsidian 手机端 + Web Clipper** | 手机复制链接 → Obsidian 剪藏 | 原生、无需额外 App | 手动操作 |
| **B. 微信 → 收藏 → 定期导出** | 微信收藏 → 导出 md → 同步 | 批量 | 非实时 |
| **C. 转发到专用机器人/渠道** | 转发文章给 bot → 自动入库 | 全自动 | 需自建 bot |
| **D. LiveSync 手机端手动保存** | 手机 Obsidian 保存 md 到 raw/ | 最简单 | 纯手动 |

### 5.2 推荐路径（分阶段）

```
阶段3a: 方案 D（手机 Obsidian 直接存 md 到 raw/）→ LiveSync 同步 → 云端 watch 自动编译
阶段3b: 方案 A（Obsidian Web Clipper 手机剪藏）→ 自动进 raw/
阶段4:   方案 C（微信转发 bot → 自动抓链接入库）[P2]
```

### 5.3 手机端工作流（最终形态）

```
微信看到文章 → 分享到 Obsidian(剪藏) 或 复制链接 → Web Clipper
        → raw/sources/ (手机端写入)
        → LiveSync 同步到云端 CouchDB
        → 云端 watch 检测到新文件 → llmwiki ingest + compile
        → wiki/ 更新 → LiveSync 同步回所有设备
```

---

## 6. 已完成基础设施（复用）

| 组件 | 位置 | 说明 |
|:-----|:-----|:-----|
| headscale 控制面 | 腾讯云 <tencent-ip>:8443 | 5 节点互联 |
| new-api 网关 | 阿里云 <aliyun-ip>:3000 | qwen3.6-27b + DeepSeek |
| vLLM qwen3.6-27b | 公司 2225 容器 | 8×RTX4090 |
| CouchDB LiveSync | 腾讯云 <tencent-ip>:5984 | vault 全端同步（5984 公网已开放，开发服务器直连已验证）|
| llmwiki | 腾讯云 /opt/llmwiki | atomicstrata 编译引擎 |

---

## 7. 风险与注意事项

| 风险 | 说明 | 缓解 |
|:-----|:-----|:-----|
| **多工具写 wiki 冲突** | nashsu 与 atomicstrata 同时写会覆盖 | 单一写者原则 |
| **olw/Synto 不稳定** | olw 维护模式、Synto 太新 | 暂缓，观察 Synto 成熟度 |
| **微信链接识别复杂** | 需处理短链/验证/登录墙 | P2 暂缓，先手动 |
| **手机端资源限制** | 手机不跑 LLM | 全部云端处理，手机只采集 |
| **Deep Research 需 API key** | Tavily/SerpApi 付费 | 可换 SearXNG 自建 |
| **写回格式不兼容**（§9）| LiveSync 格式错 → 客户端同步异常 | 先备份 CouchDB + 小步验证（单笔记 → 全量）|
| **5984 公网暴露**（§9）| CouchDB 直连公网 | 写回端点必须 token 鉴权；后续 Caddy/nginx 反代 HTTPS |
| **AI 误写核心笔记**（§9）| MCP 写坏人工笔记 | 写回路径隔离到 `opencode/` 子目录 |

---

## 8. 决策记录（ADR）

| 决策 | 理由 | 日期 |
|:-----|:-----|:-----|
| 主引擎选 atomicstrata | 活跃 + 完成度高 + MCP | 2026-08-09 |
| 不切换 olw | 维护模式，Synto 未成熟 | 2026-08-09 |
| green-dalii 只做本地辅助 | 避免与云端编译冲突 | 2026-08-09 |
| 链接识别 P2 暂缓 | 复杂度高，先跑通主链路 | 2026-08-09 |
| OpenCode 集成走腾讯云集中式网关 | 开发服务器零副本；读侧复用 sources/ 同步流水线；客户端可离线 | 2026-08-10 |
| 排除 obsidian-mcp-tools | 已归档停更 | 2026-08-10 |
| 排除 mcp-obsidian (MarkusPfundstein) | 需客户端运行 + Local REST API，不满足离线 | 2026-08-10 |

---

## 9. OpenCode 集成方案（待实施）

> 需求: 开发服务器 opencode ① 读取 vault 笔记 ② 会话历史沉淀进 Obsidian ③ 直接与腾讯云交互，不依赖 Mac/Windows/iPhone 在线。

### 9.1 现状（2026-08-10 实测）

| 项 | 状态 |
|----|------|
| 腾讯云 CouchDB 3.5.2 (`my-vault`, 664 文档, LiveSync 格式) | ✅ 运行中，5984 公网开放 |
| 开发服务器 → 腾讯云 5984 直连 | ✅ 已验证（HTTP 200）|
| `vault-raw-sync.service`（CouchDB → `/opt/llmwiki/sources/` md 文件, 15s 增量）| ✅ 运行中 |
| LiveSync 文档格式（leaf/plain/newnote）| ✅ 已确认（§9.3）|
| 写回机制（wiki/ → CouchDB, LiveSync 格式）| ✅ `sync/sync-wiki-push.sh` + `sync-wiki-push.service`（30s，增量+删除同步）|
| opencode remote MCP（`type: "remote"`）| ✅ 支持 |

### 9.2 推荐架构：腾讯云集中式网关

```
┌─ 开发服务器 (公司) ─────────────────────────────────────┐
│  opencode (opencode.json)                               │
│    └─ MCP remote: obsidian-mcp-server                   │
│         read/write → http://<tencent-ip>:3100/mcp      │
│                                                         │
│  会话沉淀 (cron 每30min):                                │
│    opencode.db → markdown 笔记 → POST 腾讯云写入端点      │
└──────────────────────────┬──────────────────────────────┘
                           │ HTTP + Bearer token
┌──────────────────────────▼──────────────────────────────┐
│ 腾讯云 <tencent-ip>                                    │
│                                                         │
│  ① obsidian-mcp-server  (node, systemd)                 │
│     filesystem 模式 → /opt/llmwiki/sources/             │
│     Streamable HTTP :3100 + Bearer token                │
│                                                         │
│  ② obsidian-writeback  (新小服务, watch sources/)       │
│     md 变更 → LiveSync 格式 → CouchDB _bulk_docs        │
│                                                         │
│  ③ CouchDB my-vault → LiveSync ──→ Mac/Windows/iPhone   │
└─────────────────────────────────────────────────────────┘
```

**设计理由**：
- 读取免费：`sources/` 已有 60s 增量同步流水线，AI 读到最新笔记（延迟 ≤60s），开发服务器零 vault 副本
- 写入一条链：AI 写笔记 → MCP 写 `sources/` → watch 转 LiveSync 格式 → CouchDB → 客户端自动同步（**客户端无需在线**）
- 会话沉淀只调 HTTP：导出脚本不接触 CouchDB 凭据

**组件选型**：`cyanheads/obsidian-mcp-server`（最活跃 2026-08-02 仍更新，filesystem 模式免插件 + Streamable HTTP 传输）；备选 `seekstone`（19 工具，HTTP 支持需确认）。

### 9.3 核心工程：LiveSync 写回格式

```
my-vault 文档模型（实测采样）
├── newnote  目录节点: {_id: 路径, type: "newnote", children: [...], path, ctime, mtime, size}
├── plain    文件索引: {_id: 路径, type: "plain", children: [h:...], path, ctime, mtime, size}
└── leaf     内容块:   {_id: "h:<hash>", type: "leaf", data: "markdown 明文"}
```

写回脚本（`obsidian-writeback`，python ~200 行，systemd watch）：
```
watch /opt/llmwiki/sources/ (inotify + 启动全量扫描)
  └─ 每个 新增/修改 .md:
      1. plain 文档: {_id: <相对路径>, type: "plain", path, children: [<块hash>], ctime, mtime, size}
      2. leaf 文档:  {_id: "h:<hash>", type: "leaf", data: <内容>}（>8KB 分块，children 按序）
      3. _bulk_docs 提交（更新带 _rev，冲突重读重试）
```

**注意事项**：格式必须与 LiveSync 客户端兼容（先备份 CouchDB + 单笔记验证再全量）；删除 = 删 plain + 对应 leaf；目录变更维护 newnote；AI 写入限定 `opencode/` 子目录。

### 9.4 会话历史沉淀

| 项 | 方案 |
|----|------|
| 数据源 | `~/.local/share/opencode/opencode.db`（SQLite）|
| 导出 | 按项目/日期查 session+message 表 → 结构化 markdown（模型/token/结论）|
| 输出 | `opencode-sessions/<项目>/<日期>.md`（vault 内）|
| 推送 | POST 腾讯云写回端点（token）→ CouchDB → 客户端可见 |
| 频率 | cron 每 30min（增量）|

### 9.5 落地步骤（待办清单）

- [ ] **步骤 1**: 腾讯云部署 `obsidian-mcp-server`（filesystem → `/opt/llmwiki/sources/`，HTTP :3100，Bearer token，systemd）
- [ ] **步骤 2**: 编写部署 `obsidian-writeback` 服务（watch + 格式转换 + `_bulk_docs`，systemd）
- [ ] **步骤 3**: 腾讯云验证写回（写测试笔记 → Mac/iPhone 同步可见）
- [ ] **步骤 4**: 开发服务器 `opencode.json` 加 remote MCP（见下）
- [ ] **步骤 5**: 开发服务器会话导出脚本 + cron（30min）
- [ ] **步骤 6**: 全链路测试（读/写/会话沉淀）+ 安全收尾（Caddy HTTPS 反代）

```jsonc
// opencode.json (步骤 4)
"mcp": {
  "obsidian": {
    "type": "remote",
    "url": "http://<tencent-ip>:3100/mcp",
    "headers": { "Authorization": "Bearer <token>" },
    "enabled": true
  }
}
```

### 9.6 备选方案：开发服务器本地镜像

```
开发服务器:
  ├─ local MCP: obsidian-mcp-server (filesystem → ~/vault-mirror/)
  ├─ sync 脚本 (cron 60s): 拉 5984 _all_docs → 本地 md；推本地变化 → _bulk_docs
  └─ 会话沉淀: 导出 → 写 mirror → 推送
```
✅ MCP 全本地最稳；❌ 需维护 vault 镜像 + 写回代码两边写。**不推荐，主方案优先**。

### 9.7 参考

- `sync/sync-vault-raw.sh` — 现成拉取方向脚本（CouchDB → sources）
- `sync/deploy-couchdb.sh` — LiveSync 服务端部署
- `xeaser/opencode-obsidian-sync` — 会话历史 → markdown 参考实现
- `cyanheads/obsidian-mcp-server` — MCP server（filesystem + Streamable HTTP）
- README.md "OpenCode 集成方案" A/B/C — 旧方案（依赖客户端在线，与本方案互补）
