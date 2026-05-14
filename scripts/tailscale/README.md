# Tailscale 部署工具

基于 `playground` + `lulzsec2012/docker` 两个工程资源，提供安全、通用的 Tailscale 节点 Docker 部署脚本。

## 快速开始

```bash
# 1. 确保 scripts/docker/data/vpn.cfg 中包含 TAILSCALE_AUTH_KEY
echo 'TAILSCALE_AUTH_KEY=tskey-auth-xxxxx' >> ~/playground/scripts/docker/data/vpn.cfg

# 2. 部署基础节点
cd ~/playground/scripts/tailscale
./deploy-tailscale.sh basic -n my-server

# 3. 验证连接
docker exec ts-my-server tailscale status
```

## 脚本说明

| 文件 | 说明 |
|------|------|
| `deploy-tailscale.sh` | 主部署脚本，支持 basic / exit / subnet 三种模式 |
| `templates/entrypoint.sh` | 容器入口脚本，包含密钥安全清除逻辑 |
| `extra/` | 从 `lulzsec2012/docker` 工程复制的参考脚本 |

## 支持的模式

### basic — 基础节点
服务器仅加入 tailnet，不宣告任何路由。

```bash
./deploy-tailscale.sh basic -n my-aliyun
```

### exit — Exit Node
将服务器设为出口节点，路由内部网段流量通过此节点出站。

```bash
./deploy-tailscale.sh exit -n aliyun-exit
```

### subnet — Subnet Router
将服务器的内网网段宣告到 tailnet。

```bash
./deploy-tailscale.sh subnet -n aliyun-router -r 172.30.0.0/16
```

## 密钥安全机制

1. **部署时：** 密钥从 `scripts/docker/data/vpn.cfg` 读取后写入 `/dev/shm`（内存文件系统），不留磁盘
2. **运行时：** 密钥通过只读挂载传入容器，入口脚本认证后立即 `unset` + `rm -f`
3. **重启时：** 认证状态持久化在 Docker volume 中，无需再次传入密钥

确认节点成功加入 tailnet 后，可手动从 `scripts/docker/data/vpn.cfg` 删除密钥。

## 参考资源

`extra/` 目录包含来自 `lulzsec2012/docker` 工程的完整启动脚本：

| 脚本 | 对应 Dockerfile | 用途 |
|------|----------------|------|
| `exitnode.sh` | exit-node.Dockerfile | Exit Node 启动 |
| `derp-init.sh` | derp.Dockerfile | DERP 中继 Tailscale 初始化 |
| `derp-build_cert.sh` | derp.Dockerfile | DERP 自签名证书生成 |
| `derp-deploy.sh` | — | DERP 容器部署脚本 |

这些脚本展示了 docker 工程中不同功能场景的入口逻辑，供参考和定制。
