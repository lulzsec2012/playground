#!/bin/bash
# ============================================
# setup_channels.sh
# 配置 Hermes 聊天通道 (微信/飞书)
# ============================================

set -e

echo "============================================"
echo "  Hermes Agent 聊天通道配置向导"
echo "============================================"
echo ""

# --- 检查 hermes 命令是否可用 ---
if ! command -v hermes &>/dev/null; then
    echo "❌ 错误: 未找到 hermes 命令。"
    echo "   请先运行 install_hermes.sh 完成安装。"
    exit 1
fi

# --- 1. 配置微信通道 ---
echo "=== 步骤 1: 配置微信通道 ==="
echo ""
echo "即将启动网关配置向导，请按以下步骤操作："
echo "  1. 在 Select platforms to configure 界面"
echo "     用方向键选择 Weixin/WeChat"
echo "  2. 按 空格键 勾选，按 回车键 确认"
echo "  3. 向导会显示二维码，使用个人微信扫码登录"
echo "  4. 在手机上确认登录后，选择 Done 并重启网关"
echo "  5. 在微信中找到 ClawBot 联系人，发送消息测试"
echo ""

read -rp "按回车键继续配置微信通道 (Ctrl+C 跳过)..."

hermes gateway setup

echo ""
echo "✅ 微信通道配置完成！"
echo ""

# --- 2. 配置飞书通道 ---
echo "=== 步骤 2: 配置飞书通道 ==="
echo ""
echo "即将启动网关配置向导，请按以下步骤操作："
echo "  1. 在 Select platforms to configure 界面"
echo "     选择 Feishu/Lark"
echo "  2. 扫码登录飞书账号"
echo "  3. 在飞书开放平台完成应用授权和创建"
echo "  4. 完成配置后，在飞书中找到机器人应用测试对话"
echo ""

read -rp "按回车键继续配置飞书通道 (Ctrl+C 跳过)..."

hermes gateway setup

echo ""
echo "✅ 飞书通道配置完成！"
echo ""

echo "============================================"
echo "🎉 所有通道配置完成！"
echo "你现在可以通过微信和飞书与 Hermes Agent 对话了。"
echo "============================================"
