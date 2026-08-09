# New-API — LLM 网关（替代 MixAPI）

[QuantumNous/new-api](https://github.com/QuantumNous/new-api) — 统一 AI 模型网关，聚合分发 OpenAI 兼容模型。
替代原 MixAPI（同为 one-api 系，但 new-api 持续维护且已修复 tool_calls 透传）。

## 为什么替换 MixAPI

| 项 | MixAPI (旧) | new-api (新) |
|:---|:-----------|:-------------|
| 维护 | ❌ 2025-11 停更 | ✅ 日更 (44.7k⭐) |
| tool_calls 透传 | ❌ 缺 2026 年上游修复 | ✅ 已修复 (llmwiki 可走网关) |
| 部署 | 源码编译 | Docker 一键 |

## 部署

```bash
# 本地/远程部署
bash scripts/newapi/deploy-newapi.sh                          # 本机
bash scripts/newapi/deploy-newapi.sh --host lzlu@39.102.52.1  # 阿里云
bash scripts/newapi/deploy-newapi.sh --status                 # 状态
bash scripts/newapi/deploy-newapi.sh --remove                 # 卸载
```

## 渠道配置

管理界面 `http://39.102.52.1:3000/`（root / 123456，首登改密）：

| 渠道 | 类型 | 代理地址 | 模型 |
|:-----|:-----|:---------|:-----|
| vLLM | OpenAI | `http://100.64.0.1:8002` | qwen3.6-27b |
| DeepSeek | DeepSeek | `https://api.deepseek.com` | deepseek-v4-* |

## 客户端接入

| 客户端 | baseUrl | key |
|:-------|:--------|:----|
| Obsidian ai-providers | `http://39.102.52.1:3000` | new-api 令牌 |
| llmwiki (腾讯云) | `OPENAI_BASE_URL=http://39.102.52.1:3000` | new-api 令牌 |

> tool_calls 已修复：llmwiki 可直接走网关，无需再绕道直连 vLLM。
