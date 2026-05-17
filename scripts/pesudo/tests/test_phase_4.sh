#!/usr/bin/env bash
#
# test_phase_4.sh — Phase 4 集成测试
#
# 测试: 服务器发现、HTTP 请求、凭据解密、expect sudo 执行
#
# 用法: bash tests/test_phase_4.sh
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PESUDO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 颜色输出
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILED=1; }
info() { echo -e "${CYAN}$*${NC}"; }

FAILED=0
TEST_PORT=18643
TEST_DIR="/tmp/pesudo_test_$$"
CREDENTIALS_DIR="${HOME}/.pesudo"

cleanup() {
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ====== Setup ======
rm -f /tmp/pesudo_store.json /tmp/pesudo_audit.log
mkdir -p "$TEST_DIR"
MASTER_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
echo "🔑 Test MASTER_KEY: ${MASTER_KEY}"

# 服务器需要从 pesudo 目录运行（相对导入）
cd "$PESUDO_DIR"

# ====== Test 1: 服务器启动 ======
info "\n═══ Test 1: 服务器启动与健康检查 ═══"

PESUDO_MASTER_KEY="$MASTER_KEY" \
PESUDO_PORT="$TEST_PORT" \
PESUDO_STORE="${TEST_DIR}/store.json" \
PESUDO_LOG="${TEST_DIR}/audit.log" \
PESUDO_DEV=1 \
    python3 -m server.server --dev --port "$TEST_PORT" &
SERVER_PID=$!

# 等待服务器就绪
sleep 2
if kill -0 "$SERVER_PID" 2>/dev/null; then
    pass "服务器进程已启动 (PID=$SERVER_PID)"
else
    fail "服务器启动失败"
    exit 1
fi

# 健康检查
HEALTH=$(curl -sf "http://localhost:${TEST_PORT}/v1/health" 2>/dev/null || true)
if echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'" 2>/dev/null; then
    pass "健康检查通过"
else
    fail "健康检查失败: $HEALTH"
fi

# ====== Test 2: 测试解密函数 ======
info "\n═══ Test 2: decrypt_credential 函数测试 ═══"

source "$PESUDO_DIR/client/pesudo-lib.sh"

# 通过 python 构建测试凭据
TEST_CRED=$(python3 -c "
import sys, json
sys.path.insert(0, '$PESUDO_DIR')
from server.crypto import build_one_time_credential, decrypt_credential

cred = build_one_time_credential('test-pass-123', 'req_test_001')
print(json.dumps(cred))
")

CT=$(echo "$TEST_CRED" | python3 -c "import sys,json; print(json.load(sys.stdin)['ciphertext'])")
SK=$(echo "$TEST_CRED" | python3 -c "import sys,json; print(json.load(sys.stdin)['session_key'])")

# 用 bash 库函数解密
DECRYPTED=$(decrypt_credential "$CT" "$SK" "req_test_001") || true
if [[ "$DECRYPTED" = "test-pass-123" ]]; then
    pass "凭据解密正确"
else
    fail "凭据解密失败: expected 'test-pass-123', got '$DECRYPTED'"
fi

# 测试错误 request_id（应失败）
DECRYPTED=$(decrypt_credential "$CT" "$SK" "req_wrong_id") || true
if [[ -z "$DECRYPTED" ]]; then
    pass "错误 request_id 拒绝（预期）"
else
    fail "错误 request_id 未拒绝: got '$DECRYPTED'"
fi

# 测试篡改密文（应失败）
DECRYPTED=$(decrypt_credential "aa${CT:2}" "$SK" "req_test_001") || true
if [[ -z "$DECRYPTED" ]]; then
    pass "篡改密文拒绝（预期）"
else
    fail "篡改密文未拒绝: got '$DECRYPTED'"
fi

# ====== Test 3: 注册与授权流程 ======
info "\n═══ Test 3: 注册与授权 API 流程 ═══"

# 注册测试机器
RESP=$(curl -sf -X POST "http://localhost:${TEST_PORT}/v1/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"machine_id\": \"test-box\",
        \"hostname\": \"test-box\",
        \"user\": \"tester\",
        \"encrypted_pass\": \"test-sudo-pass\",
        \"aliyun_auth_token\": \"test-token\"
    }" 2>/dev/null) || true

if echo "$RESP" | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='ok'" 2>/dev/null; then
    pass "注册成功"
else
    fail "注册失败: $RESP"
fi

# 发起授权请求
RESP=$(curl -sf -X POST "http://localhost:${TEST_PORT}/v1/auth/request" \
    -H "Content-Type: application/json" \
    -d '{"machine_id": "test-box", "command": "whoami"}' 2>/dev/null) || true

REQUEST_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('request_id',''))" 2>/dev/null) || true
if [[ -n "$REQUEST_ID" ]]; then
    pass "授权请求成功 (request_id=${REQUEST_ID})"
else
    fail "授权请求失败: $RESP"
fi

# ====== Test 4: 注册与 auth request + verify 测试 ======
info "\n═══ Test 4: 错误处理测试 ═══"

# 创建 ~/.pesudo/credentials
mkdir -p "$CREDENTIALS_DIR"
echo "machine_id=test-box" > "$CREDENTIALS_DIR/credentials"
echo "hostname=test-box" >> "$CREDENTIALS_DIR/credentials"

# 验证未注册机器拒绝（使用 -s 不带 -f 以捕获错误响应体）
RESP=$(curl -s -X POST "http://localhost:${TEST_PORT}/v1/auth/request" \
    -H "Content-Type: application/json" \
    -d '{"machine_id": "unknown-box", "command": "whoami"}' 2>/dev/null)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:${TEST_PORT}/v1/auth/request" \
    -H "Content-Type: application/json" \
    -d '{"machine_id": "unknown-box", "command": "whoami"}' 2>/dev/null)
if [[ "$HTTP_CODE" = "404" ]]; then
    pass "未注册机器正确拒绝 (404)"
else
    fail "未注册机器应该返回 404，实际返回 $HTTP_CODE"
fi

# 清理测试凭据
rm -f "$CREDENTIALS_DIR/credentials"

# ====== Test 5: 完整客户端流程测试 ======
info "\n═══ Test 5: 客户端 pesudo 命令流 ═══"

# 设置测试凭据
mkdir -p "$CREDENTIALS_DIR"
echo "machine_id=test-box" > "$CREDENTIALS_DIR/credentials"
echo "hostname=test-box" >> "$CREDENTIALS_DIR/credentials"
echo "SERVER_URL=http://localhost:${TEST_PORT}" > "$CREDENTIALS_DIR/config"

# 设置日志文件路径让 server 写入 OTP
# 注册测试机器做 verify 测试
curl -sf -X POST "http://localhost:${TEST_PORT}/v1/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"machine_id\": \"verify-test\",
        \"hostname\": \"verify-test\",
        \"user\": \"tester\",
        \"encrypted_pass\": \"test-password\",
        \"aliyun_auth_token\": \"test\"
    }" >/dev/null 2>&1

# 发起请求获取 request_id
REQ_RESP=$(curl -sf -X POST "http://localhost:${TEST_PORT}/v1/auth/request" \
    -H "Content-Type: application/json" \
    -d '{"machine_id": "verify-test", "command": "test"}' 2>/dev/null)
VERIFY_REQ_ID=$(echo "$REQ_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_id'])")

# 用错误的 OTP 测试（应返回 403）
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:${TEST_PORT}/v1/auth/verify" \
    -H "Content-Type: application/json" \
    -d "{\"machine_id\": \"verify-test\", \"request_id\": \"${VERIFY_REQ_ID}\", \"otp\": \"000000\"}" 2>/dev/null)
if [[ "$HTTP_CODE" = "403" ]]; then
    pass "错误 OTP 正确拒绝 (403)"
else
    fail "错误 OTP 未拒绝，期望 403，实际 $HTTP_CODE"
fi

# ====== 清理 ======
cleanup

# ====== 结果 ======
info "\n═══════════════════════════════════"
if [[ "$FAILED" = "1" ]]; then
    echo -e "  ${RED}❌ 部分测试失败${NC}"
    exit 1
else
    echo -e "  ${GREEN}✓ 所有测试通过${NC}"
    exit 0
fi
