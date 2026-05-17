# Obsidian

跨平台 Obsidian 安装、配置与 OpenCode 集成方案。

```
scripts/obsidian/
├── install.sh        # 跨平台安装 (macOS brew cask / Linux CLI tools)
├── setup-vault.sh    # 初始化 vault 目录结构 + 默认配置
└── register.sh       # CLI 工具 PATH 注册
```

---

## 安装

```bash
# macOS: 安装 Obsidian GUI + CLI 工具
bash scripts/obsidian/install.sh

# Linux: 安装 CLI 工具 (headless 容器用)
bash scripts/obsidian/install.sh --cli-only

# 初始化 vault
bash scripts/obsidian/setup-vault.sh /path/to/vault
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

## 组合推荐

```
macOS 本机:
  Obsidian GUI
    ├── Local REST API 插件 ←→ with-context-plugin (方案A: AI 读写 vault)
    ├── Dataview 插件       ←→ opencode-obsidian-sync (方案B: 会话知识库)
    └── opencode-obsidian    (方案C: 侧边栏对话)

Linux 容器 (10.10.18.211:2222):
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
