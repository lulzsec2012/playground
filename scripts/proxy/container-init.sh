#!/bin/bash
# container-init.sh — 容器初始化脚本（供 --entrypoint 使用）
# 通过环境变量 PROXY_DATA_DIR 指定配置文件目录
# 用法: docker run -e PROXY_DATA_DIR=/path/to/data ... -c "$(cat container-init.sh)"

set -e

: "${PROXY_DATA_DIR:?必须设置 PROXY_DATA_DIR 环境变量}"
SING_BOX_BIN="${PROXY_DATA_DIR}/sing-box"
CONFIG="${PROXY_DATA_DIR}/config.json"
GEOIP="${PROXY_DATA_DIR}/geoip.db"
GEOSITE="${PROXY_DATA_DIR}/geosite.db"

# ── 1. 安装 sing-box ──
if [ -f "$SING_BOX_BIN" ] && [ ! -f /usr/local/bin/sing-box ]; then
	cp "$SING_BOX_BIN" /usr/local/bin/sing-box
	chmod +x /usr/local/bin/sing-box
fi

# ── 2. 复制配置 ──
if [ -f "$CONFIG" ]; then
	mkdir -p /etc/sing-box /var/lib/sing-box
	cp "$CONFIG" /etc/sing-box/config.json
fi
if [ -f "$GEOIP" ]; then
	cp "$GEOIP" /var/lib/sing-box/geoip.db
fi
if [ -f "$GEOSITE" ]; then
	cp "$GEOSITE" /var/lib/sing-box/geosite.db
fi

# ── 3. SSH (port 2221，避免与宿主机冲突) ──
# 幂等处理：用整行锚定防止重复执行时 Port 2221 → Port 222121
sed -i 's/^Port 22$/Port 2221/' /etc/ssh/sshd_config 2>/dev/null
sed -i 's/^#Port 22$/Port 2221/' /etc/ssh/sshd_config 2>/dev/null
grep -q '^Port 2221' /etc/ssh/sshd_config || echo 'Port 2221' >>/etc/ssh/sshd_config
mkdir -p /run/sshd
/usr/sbin/sshd

# ── 4. 部署工具脚本 ──
if [ -f "$SING_BOX_BIN" ]; then
	# proxy-route / proxy-optimize
	cp "$SING_BOX_BIN" /usr/local/bin/sing-box
	chmod +x /usr/local/bin/sing-box
fi
if [ -f "${PROXY_DATA_DIR}/proxy-route" ]; then
	cp "${PROXY_DATA_DIR}/proxy-route" /usr/local/bin/proxy-route
	chmod +x /usr/local/bin/proxy-route
fi
if [ -f "${PROXY_DATA_DIR}/proxy-optimize" ]; then
	cp "${PROXY_DATA_DIR}/proxy-optimize" /usr/local/bin/proxy-optimize
	chmod +x /usr/local/bin/proxy-optimize
fi
if [ -f "${PROXY_DATA_DIR}/auto-learner.py" ]; then
	cp "${PROXY_DATA_DIR}/auto-learner.py" /usr/local/bin/auto-learner.py
	chmod +x /usr/local/bin/auto-learner.py
fi

# ── 5. 启动 sing-box ──
if command -v sing-box &>/dev/null && [ -f /etc/sing-box/config.json ]; then
	sing-box run -c /etc/sing-box/config.json >/tmp/sing-box.log 2>&1 &
fi

# ── 6. 启动 auto-learner ──
sleep 3
if [ -f /usr/local/bin/auto-learner.py ]; then
	python3 /usr/local/bin/auto-learner.py >/tmp/auto-learner.log 2>&1 &
fi

# ── 7. 保持运行 ──
tail -f /dev/null
