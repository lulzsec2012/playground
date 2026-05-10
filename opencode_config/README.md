# opencode-multi 配置文件

本目录包含 [opencode-multi](https://github.com/opencode-ai/opencode-multi) 的多 profile 配置。

## 目录结构

```
opencode_config/
├── profiles/           # 4 个独立 profile
│   ├── local/          # 本地开发环境
│   ├── work/           # 工作环境
│   ├── mix-local/      # 本地混合
│   └── mix-work/       # 工作混合
├── scripts/
│   ├── ollama-benchmark.sh     # Ollama 模型基准测试
│   ├── ollama-start.sh         # 启动本地 Ollama 服务
│   └── ollama-test-remote.sh   # 测试远程 Ollama 连接
└── README.md
```

## 脚本说明

- **ollama-benchmark.sh**: 对已下载的 Ollama 模型运行性能基准测试（tokens/s）。
- **ollama-start.sh**: 配置环境变量并启动本地 Ollama 服务。
- **ollama-test-remote.sh**: 测试与远程 Ollama 服务器的连通性。
