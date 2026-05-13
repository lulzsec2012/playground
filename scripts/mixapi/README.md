# MIXAPI — AI 大模型网关 & LLM 网络探测

部署在 `39.102.52.1`，端口 `3000`。

## 文件说明

| 文件 | 说明 |
|------|------|
| `Dockerfile` | MIXAPI v2.5.1cl 镜像构建（Tsinghua 镜像加速） |
| `setup.sh` | 一键部署脚本（构建镜像 + 创建数据目录 + 启动容器） |
| `discover-llm-nodes.sh` | 扫描 tailnet 发现 LLM 推理服务节点及可用模型 |
| `test-llm-model.sh` | 通过 tailnet 测试 ollama 模型推理可用性和性能 |

---

## discover-llm-nodes.sh — LLM 服务发现

在 tailscale 网络中自动发现运行 LLM 推理服务的节点。

### 探测范围

| 端口 | 服务 | API 端点 | 模型提取方式 |
|------|------|----------|-------------|
| 11434 | Ollama | `/api/tags` | `models[].name` |
| 8000 | vLLM | `/v1/models` | `data[].id` |
| 80 | TGI | `/info` | `model_id` |
| 8080 | TGI-alt | `/info` | `model_id` |
| 8188 | ComfyUI | `/system_stats` | 无（标记运行中） |
| 3000 | Open WebUI | `/api/models` | `data[].id` |
| 5000 | Text-gen | `/v1/models` | `data[].id` |

### 实现原理

1. `docker exec ts-aliyun-basic tailscale status` 获取所有在线节点
2. 跳过已知非 LLM 节点（aliyun-basic, cn-derp, desktop, lizhi）
3. 对每个节点用 `nc -z` 并行扫端口
4. 端口通的节点用 `wget -qO-` 查询 API
5. 用 `grep/sed` 解析 JSON 提取模型名

### 测试结果

**2026-05-12 扫描结果：**

| 节点 | IP | 服务 | 端口 | 模型 |
|------|----|------|------|------|
| duser-nf5468m6-4090-5 | 100.117.18.87 | ollama | 11434 | 11 个模型（见下方） |
| duser-nf5468m6-4090-2 | 100.103.54.102 | — | — | 无 LLM 服务 |
| desktop-1sm2vua | 100.81.13.45 | — | — | 无 |
| lizhi | 100.120.5.114 | — | — | 无 |

**duser-nf5468m6-4090-5 上可用的模型：**

```
gemma4:26b, qwen3.6:27b, qwen3.6:35b,
qwen2.5-coder:7b, qwen2.5-coder:14b,
nemotron-3-super:latest-zh, nemotron-3-super:latest,
qwen2.5:72b-instruct-q5_K_M, qwen3-coder-next:latest,
glm-4.7-flash:latest, deepseek-r1:7b
```

### 使用方法

```bash
# 全量扫描
./discover-llm-nodes.sh

# 指定节点
./discover-llm-nodes.sh --node 100.117.18.87
```

---

## test-llm-model.sh — 模型推理测试

测试指定 ollama 模型在 tailnet 上的推理可用性和性能。

### 测试指标

- **端口连通性** — `nc -z` 检查远程 ollama 服务端口
- **模型存在性** — 调用 `/api/tags` 确认模型已拉取
- **冷启动时间** — 模型首次加载（从磁盘读入 GPU）耗时
- **热启动时间** — 已加载模型的推理首包延迟
- **推理速度** — 每秒生成 token 数 (tok/s)
- **响应完整性** — 确认返回了完整文本和统计信息

### 实现原理

1. 参数检查：目标 IP + 模型名
2. 端口连通性检测 (`nc -z`)
3. 模型存在性确认 (`GET /api/tags`)
4. 冷启动：`POST /api/generate` 首次推理（模型尚未加载到 GPU）
5. 热启动：`POST /api/generate` 第二次推理（模型已在 GPU 内存中）
6. 从 JSON 响应解析 `eval_count`, `eval_duration`, `total_duration`

### 测试结果

**2026-05-12 测试，目标: `100.117.18.87:11434`**

| 模型 | 冷启动 | 热启动 | 推理速度 |
|------|--------|--------|----------|
| **gemma4:26b** | 18.64s (加载 17.84s) | 0.96s | **148.4 tok/s** |
| **qwen2.5-coder:7b** | 7.33s (加载 6.65s) | 0.75s | **178.1 tok/s** |

### 关键发现

1. **Tailscale 网络延迟基本可忽略** — 从 aliyun-basic 到 GPU 服务器通过 tailnet 直连 (DERP China 5.8ms)，网络不是瓶颈
2. **瓶颈在模型加载和推理本身** — 冷启动主要耗时在从磁盘加载模型到 GPU（gemma4:26b 加载 17.84s，qwen2.5-coder:7b 加载 6.65s）
3. **热启动极快** — 已加载模型的推理首包不到 1s
4. **推理速度可观** — 7B 模型可达 178 tok/s，26B 模型 148 tok/s

### 使用方法

```bash
# 测试单个模型
./test-llm-model.sh 100.117.18.87 qwen2.5-coder:7b

# 输出示例
✓ 端口 11434 连通
✓ 模型 qwen2.5-coder:7b 已存在于 ollama
⟳ 冷启动: 7.33s (模型加载 6.65s)
✓ 热启动: 0.75s
✓ 推理速度: 178.1 tok/s | 输出 token: 234
```

---

## 网络架构说明

```
39.102.52.1 (Aliyun ECS)
├── MIXAPI 容器 (:3000) — AI 网关
└── ts-aliyun-basic 容器 — Tailscale 节点 (100.120.203.67)
    └── tailnet (100.x.x.x)
        ├── duser-nf5468m6-4090-5 (100.117.18.87) — ollama 11 个模型
        ├── duser-nf5468m6-4090-2 (100.103.54.102) — 无 LLM 服务
        ├── cn-derp (100.126.0.96) — DERP 中继
        ├── lizhi (100.120.5.114) — macOS
        └── desktop-1sm2vua (100.81.13.45) — Windows
```

LLM 探测脚本通过 `docker exec ts-aliyun-basic` 进入 tailscale 容器网络，利用 tailnet 直连各节点进行服务发现和性能测试。所有操作在容器内完成，不影响宿主机外部网络和其他业务。
