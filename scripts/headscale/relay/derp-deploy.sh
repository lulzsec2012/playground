#!/bin/bash
# Usage: TS_AUTH_KEY="tskey-auth-xxxxx" ./deploy_derp.sh
set -e
# 基础设施地址（gitignored: scripts/data/hosts.cfg）
HOSTS_CFG="${HOSTS_CFG:-}"
if [[ -z "$HOSTS_CFG" ]]; then
    for _d in "$(dirname "${BASH_SOURCE[0]}")/../../data" "$(dirname "${BASH_SOURCE[0]}")/../data"; do
        [[ -f "$_d/hosts.cfg" ]] && { HOSTS_CFG="$_d/hosts.cfg"; break; }
    done
fi
[[ -f "$HOSTS_CFG" ]] && source "$HOSTS_CFG"
TENCENT_IP="${TENCENT_IP:-}"; SSH_USER="${SSH_USER:-}"


if [ -z "${TS_AUTH_KEY}" ]; then
    echo "ERROR: TS_AUTH_KEY is required."
    echo "Get one from https://login.tailscale.com/admin/settings/authkeys"
    echo ""
    echo "Usage: TS_AUTH_KEY=\"tskey-auth-xxxxx\" $0"
    exit 1
fi

# === CONFIG ===
DERP_HOST="${DERP_HOST:-${TENCENT_IP}}"
DERP_DOMAIN="${DERP_DOMAIN:-${DERP_HOST}}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-cn-derp}"
IMAGE="${IMAGE:-lulzsec2012/derp:latest}"
# ==============

echo "=== Pulling image: ${IMAGE} ==="
docker pull "${IMAGE}"

echo "=== Stopping old container ==="
docker rm -f derper 2>/dev/null && echo "Removed old derper container" || echo "No existing derper container"

echo "=== Starting new DERP relay ==="
docker run -d --name derper \
  --restart always \
  --network host \
  -e TAILSCALE_AUTH_KEY="${TS_AUTH_KEY}" \
  -e DERP_DOMAIN="${DERP_DOMAIN}" \
  -e DERP_HOST="${DERP_HOST}" \
  -e DERP_ADDR="0.0.0.0:443" \
  -e DERP_STUN="true" \
  -e DERP_VERIFY_CLIENTS="false" \
  -e DERP_CERTS="/app/certs" \
  -e DERP_HTTP_PORT="80" \
  -e TAILSCALE_STATE_ARG="mem:" \
  -e TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME}" \
  "${IMAGE}"

echo "=== Waiting for startup... ==="
sleep 5

echo "=== Container status ==="
docker ps --filter name=derper --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo ""
echo "=== Recent logs ==="
docker logs derper --tail 15 2>&1

echo ""
echo "=== DERP process check ==="
docker exec derper ps aux 2>/dev/null | grep -E 'derper|tailscale'

echo ""
echo "=== DONE ==="
echo "To verify STUN: printf '\x00\x01\x00\x00\x21\x12\xa4\x42\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c' | nc -u -w 3 ${DERP_HOST} 3478 | xxd"
