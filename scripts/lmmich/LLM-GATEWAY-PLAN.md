# LLM 网关改造方案（LiteLLM 部署 + llm-router 简化）

> 状态: 📌 规划中（未实现）
> 日期: 2026-08-10
> 背景: opencode 使用 llm-router 做 LLM 后端选择；计划引入 LiteLLM 作为本地统一网关，
> 重构探测与路由职责划分。

---

## 1. 目标

- **LiteLLM** 成为本地统一的 LLM 网关（服务所有软件），自动探测本地/headscale 网络可用的大模型，本地优先，失败 fallback 到 new-api
- **llm-router** 退化为 opencode 专用引导器（LiteLLM 存在 → 用它；不存在 → new-api）
- 消除"每个软件各自配置/认证大模型"的重复工作

## 2. 目标架构

```
┌─ LiteLLM（通用网关，服务所有软件）─────────────────────────────┐
│  deploy-litellm.sh（部署时 + 定期刷新）                        │
│    ① 探测 headscale 网络 vLLM（100.64.0.1:8000-8010 等）      │
│    ② 探测本机 Ollama（:11434）                                │
│    ③ 动态生成 config.yaml：                                   │
│         model_list = [本地 vLLM(优先), Ollama, new-api 模型]   │
│         fallback: 本地失败 → new-api                          │
│    ④ 启动容器（:4000）+ 健康检查 + --refresh 热重载            │
│                                                                │
│  消费者：opencode / 部署脚本（immich-analyze 等）/ 其他工具     │
│  全部指向 http://localhost:4000/v1，零认证                     │
└────────────────────────────────────────────────────────────────┘

┌─ llm-router（opencode 专用，极简引导）─────────────────────────┐
│  探测 localhost:4000 → 存在 → 转发 LiteLLM                    │
│  不存在 → 直接 new-api（兜底）                                │
│  保留 MCP 工具（opencode agent 用）                           │
│  删除：端口扫描探测 / 模型映射缓存 / 转发路由引擎 / Langfuse   │
└────────────────────────────────────────────────────────────────┘
```

## 3. 职责划分（关键决策）

| 能力 | 归属 | 理由 |
|:-----|:-----|:-----|
| 存在性探测（headscale vLLM / Ollama）| **LiteLLM 部署脚本** | 一次探测，所有软件受益；llm-router 只服务 opencode |
| 路由 + fallback + 重试 | **LiteLLM**（运行时）| 专业稳定（上游顺序 + fallback 链）|
| 统一 OpenAI 端点（:4000）| **LiteLLM** | 所有本地软件零认证接入 |
| 引导选择（litellm vs new-api）| **llm-router** | opencode 配置固定指向 llm-router:8000，由它决定转发目标 |
| MCP 工具暴露 | **llm-router** | LiteLLM 不是 MCP server |
| Token 日志/Langfuse | **LiteLLM**（可选回调）| 从 llm-router 移除 |

## 4. LiteLLM 部署脚本设计（deploy-litellm.sh）

建议位置: `scripts/litellm/deploy-litellm.sh`

```
用法:
  bash deploy-litellm.sh                 # 探测 → 生成 config → 启动容器
  bash deploy-litellm.sh --refresh       # 重探测 + 重载配置
  bash deploy-litellm.sh --status        # 查看上游/健康
  bash deploy-litellm.sh --remove        # 卸载

核心流程:
  1. 探测可用后端
     - headscale: tailscale ip -4 / 已知主机表（100.64.0.1）→ 扫 8000-8010 → /v1/models 获取模型名
     - 本机 Ollama: localhost:11434 → /api/tags
     - new-api: 固定（环境变量或 hosts.cfg 的 ALIYUN_IP + key）
  2. 生成 config.yaml
     model_list:
       - 本地 vLLM 模型（优先级 1，如 qwen3.6-27b @ 100.64.0.1:8002）
       - Ollama 模型（可选）
       - new-api 模型（兜底）
     router_settings:
       fallbacks: 本地模型失败 → new-api 同名模型
  3. docker run ghcr.io/berriai/litellm:main（:4000）
  4. 健康检查: curl :4000/v1/models
  5. --refresh: 重探测 → 写 config → 热重载（/config/reload 或重启容器）

依赖:
  - scripts/data/hosts.cfg（NEWAPI 地址/key 等，gitignored）
  - 复用 llm-router.py 的探测代码（port scan + /v1/models 发现）
```

## 5. llm-router 改造方案

文件: `scripts/opencode/scripts/llm-router.py`（当前 14.3KB → 目标 ~3KB）

```
改造前（现状）:
  - 扫描 localhost:8000-8010 + tailscale IP 探测 vLLM
  - /v1/models 发现模型名 → 建立 模型→端口 映射（30s 缓存）
  - 路由优先级: localhost → tailscale → mixapi
  - 转发代理 + Token 日志（Langfuse 检测推送）

改造后（简化）:
  def select_backend():
      if port_open("127.0.0.1", 4000):      # LiteLLM 存在
          return "http://127.0.0.1:4000"
      return NEWAPI_BASE_URL                  # new-api 兜底
  - 保留: OpenAI 兼容转发层（opencode 配置仍指向 :8000）、MCP 工具
  - 删除: 端口扫描、模型映射缓存、Langfuse 日志（交给 LiteLLM）

llm-router-mcp.py（1.7KB）: 保留（opencode agent 的"当前后端"工具）
```

### 5.1 LiteLLM 自动拉起（llm-router 启动时兜底）

目标: litellm 不存在时自动拉起，无需人工干预；但**不在每次 MCP 调用时拉起**（避免等待/竞态/重复启动）。

三层方案:

```
第 1 层（治本）: litellm 常驻
  deploy-litellm.sh 部署时注册:
    - Docker: --restart=always（崩溃自动重启）
    - 或 systemd: litellm.service（开机自启 + 崩溃自愈）
  → 平时不会"不存在"，仅在首次部署/手动停止时缺失

第 2 层（治标）: llm-router daemon 启动时兜底拉起一次
  启动流程:
    if not port_open(:4000):
        if LITELLM_AUTO_START != "0":      # 环境变量开关，默认开
            幂等拉起（flock 锁 + docker start / deploy-litellm.sh --start-only）
            不等待就绪 → 本次会话先用 new-api，后台拉起后自动切换
        拉起失败 → 记录日志 + 本会话走 new-api

第 3 层: MCP 工具保持简单（检测 + 选择，不负责拉起）
  litellm 在 → 用它；不在 → new-api
```

拉起实现（幂等）:

```python
def ensure_litellm():
    """llm-router 启动时调用一次"""
    if port_open("127.0.0.1", 4000, timeout=0.5):
        return True
    if os.environ.get("LITELLM_AUTO_START", "1") == "0":
        return False
    with flock("/tmp/litellm-start.lock"):          # 防并发重复拉起
        if port_open("127.0.0.1", 4000):
            return True                             # 已被其他进程拉起
        subprocess.Popen(                           # 后台拉起，不阻塞
            ["bash", DEPLOY_LITELLM_SH, "--start-only"])
    return False                                    # 本次先用 new-api
```

| 设计点 | 处理 |
|:-------|:-----|
| MCP 调用同步等待 | 异步 Popen 拉起，立即返回"启动中"，下次调用已就绪 |
| 并发触发 | flock 锁 + docker start 幂等 |
| 拉起失败 | 静默 fallback new-api + 日志 |
| 用户不需要 litellm | `LITELLM_AUTO_START=0` 关闭自动拉起 |
| 权限 | 运行用户需 docker 组权限或 deploy 脚本内部 sudo |

## 6. 探测细节

| 探测目标 | 方法 | 优先级 |
|:---------|:-----|:-------|
| 本机 vLLM | 扫 localhost:8000-8010 + /v1/models | 1（0ms 延迟）|
| headscale 网络 vLLM | tailscale ip -4 → 扫 8000-8010（或已知主机表）| 2 |
| 本机 Ollama | localhost:11434 /api/tags | 2.5 |
| new-api（远程）| 固定地址 + API key（hosts.cfg / 环境变量）| 3（兜底）|

刷新策略: 部署时探测一次 + 手动 `--refresh`；可选 systemd timer（10min）适配 vLLM 动态启停。

## 7. 与 lmmich 的整合

- immich-analyze 的 `IMMICH_ANALYZE_HOSTS` 可指向 LiteLLM（:4000）而非直连 Ollama — 由 LiteLLM 决定用本地 Ollama 还是 new-api 视觉模型
- 部署顺序: `deploy-litellm.sh`（网关）→ `deploy-immich.sh`（应用，探测到网关自动使用）

## 8. 实施清单（TODO）

- [ ] 新建 `scripts/litellm/deploy-litellm.sh`（探测 + config 生成 + 容器 + refresh + `--start-only` 供拉起调用）
- [ ] 新建 `scripts/litellm/config.yaml.template`
- [ ] 简化 `scripts/opencode/scripts/llm-router.py`（引导逻辑 + 启动时自动拉起 ensure_litellm + LITELLM_AUTO_START 开关）
- [ ] litellm 常驻注册（Docker `--restart=always` 或 systemd service）
- [ ] 验证: ① opencode 走 litellm ② litellm 停掉后 llm-router fallback new-api ③ litellm 不存在时 llm-router 自动拉起 → 下次调用切回
- [ ] 文档: 更新 opencode README / AGENTS.md 目录树
- [ ] 可选: systemd timer 定期 refresh

## 9. 相关文件

- `scripts/opencode/scripts/llm-router.py`（改造对象）
- `scripts/opencode/scripts/llm-router-mcp.py`（保留）
- `scripts/data/hosts.cfg`（new-api 地址/key，gitignored）
- `scripts/lmmich/`（消费者示例：immich-analyze 接入）
