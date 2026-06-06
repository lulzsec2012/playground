# ChromeGo → Sing-box 统一部署

## Goal
将 ChromeGo 所有协议配置（除 mieru 外）转换为 sing-box 统一格式，生成可直接使用的配置文件 + 一键部署脚本。

## Phases

### Phase 1: 配置转换脚本 `chromego-gen-config.py`
- 读取所有协议目录下的配置文件
- 转换为 sing-box outbound 格式
- 生成完整 config.json（inbound + outbound + proxy-groups + routing）

### Phase 2: 部署脚本 `chromego-deploy.sh`
- 安装 sing-box（检测系统，下载适合的二进制或 apt）
- 复制 config.json
- 设置 systemd 服务（如果有）
- 安装 metacubexd dashboard
- 启动服务

### Phase 3: 验证
- 检查生成的 config.json 语法正确
- 输出所有节点数量汇总
