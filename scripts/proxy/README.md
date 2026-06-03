# Proxy — 代理工具集

两个核心功能：**订阅更新** 和 **本地代理**。

---

## 功能一：订阅更新（fetch.sh + merge.py）

从多个公开 GitHub 源下载免费 Clash 代理配置，合并到模板，生成开箱即用的配置文件。

### 手动运行

```bash
bash scripts/proxy/fetch.sh
```

输出到 `scripts/proxy/config.yaml`（已 gitignore）。

### 定时自动更新

```bash
bash scripts/proxy/cron-install.sh install    # 每天 03:00 自动更新
bash scripts/proxy/cron-install.sh show       # 查看状态
bash scripts/proxy/cron-install.sh remove     # 移除定时任务
```

### 推送到 Stash

```bash
alias stash-to-free='cp scripts/proxy/config.yaml "$STASH_CFG_DIR/config.yaml"'
```

---

## 功能二：本地代理（free.sh）

扫描 tailnet 中所有在线节点，自动发现可用的 HTTP/SOCKS5 代理，设置当前 shell 和 git 的代理环境变量。

### 使用

```bash
source scripts/proxy/free.sh           # 扫描并设置代理
source scripts/proxy/free.sh --show    # 查看当前代理状态
source scripts/proxy/free.sh --test    # 只扫描不设置
```

> 需要用 `source` 执行，才能在当前 shell 中设置 `http_proxy` 等环境变量。

### 原理

1. 获取 tailnet 所有在线节点
2. 跳过已知非代理节点（aliyun-basic, cn-derp）
3. 对每个节点并行扫描端口（7890, 7897, 1080, 10808, 3128, 8080）
4. 发现可达代理后导出 `http_proxy` / `https_proxy` 环境变量

---

## 文件说明

| 文件 | 功能 |
|------|------|
| `fetch.sh` | 下载免费 Clash 订阅源 |
| `merge.py` | 合并代理节点到模板 |
| `cron-install.sh` | 管理 fetch.sh 的定时任务 |
| `free.sh` | 扫描 tailnet 自动配置代理 |
| `config.yaml` | fetch.sh 的输出文件（gitignored） |

## 相关工具

### Aggregator

[`wzdnzd/aggregator`](https://github.com/wzdnzd/aggregator)（7K stars）— 全自动代理池流水线，可替代本项目的 `fetch.sh` + `merge.py`：

- 订阅聚合 → 去重 → 存活检测 → 按协议分类 → 推送到 Gist/PasteGG/Imperial
- 需要自建 runner 或 GitHub Actions 驱动
- 不能替代 `free.sh`（tailnet 专用）

## 依赖

- tailnet 接入（free.sh 需访问 tailscale 节点）
- python3（merge.py 需要 PyYAML：`pip3 install pyyaml`）
