#!/usr/bin/env bash
# test_phase_7.sh — Phase 7 集成测试
# 测试: deploy 脚本 dry-run、install 脚本、register、pesudo.sh 入口

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PESUDO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILED=1; }
info() { echo -e "${CYAN}$*${NC}"; }

FAILED=0
TEST_DIR="/tmp/pesudo_test_phase7_$$"
TEST_INSTALL_DIR="${TEST_DIR}/install"
TEST_HOME="${TEST_DIR}/home"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ====== Setup ======
mkdir -p "$TEST_DIR" "$TEST_INSTALL_DIR" "$TEST_HOME"

# ====== Test 1: register.sh 别名安装 ======
info "\n═══ Test 1: register.sh 别名安装 ═══"

HOME="$TEST_HOME" bash "${PESUDO_DIR}/register.sh" 2>&1 || true

REG_FILE="${TEST_HOME}/.config/playground/registrations.d/pesudo.sh"
RC_FILE="${TEST_HOME}/.zshrc"
if grep -q "alias sudo=" "$REG_FILE" 2>/dev/null; then
    pass "register 成功写入别名到 ${REG_FILE}"
    if grep -q "registrations.d" "$RC_FILE" 2>/dev/null; then
        pass "RC 文件已包含 registrations.d/ 加载配置"
    else
        fail "RC 文件缺少 registrations.d/ 加载配置"
    fi
else
    fail "register 未创建注册文件: ${REG_FILE}"
fi

# ====== Test 2: register.sh 幂等性 ======
info "\n═══ Test 2: register.sh 幂等性 ═══"
HOME="$TEST_HOME" bash "${PESUDO_DIR}/register.sh" 2>&1 || true
alias_count=$(grep -c "alias sudo=" "$REG_FILE" 2>/dev/null || echo 0)
rc_line_count=$(grep -c "registrations.d" "$RC_FILE" 2>/dev/null || echo 0)
if [[ "$alias_count" -eq 1 && "$rc_line_count" -eq 1 ]]; then
    pass "register 幂等，别名和 RC 加载行各只出现一次"
else
    fail "register 非幂等（别名出现 ${alias_count} 次，RC 行 ${rc_line_count} 次）"
fi

# ====== Test 3: deploy.sh --dry-run ======
info "\n═══ Test 3: deploy.sh --dry-run ═══"
if bash "${PESUDO_DIR}/server/deploy.sh" --dry-run 2>&1; then
    pass "deploy --dry-run 执行成功"
else
    fail "deploy --dry-run 失败"
fi

# ====== Test 4: deploy.sh 创建了正确的文件结构 ======
info "\n═══ Test 4: deploy dry-run 文件结构检查 ═══"
deploy_dir="/tmp/pesudo-deploy-test"
required_files=(
    "${deploy_dir}/opt/pesudo/server.py"
    "${deploy_dir}/opt/pesudo/store.py"
    "${deploy_dir}/opt/pesudo/crypto.py"
    "${deploy_dir}/opt/pesudo/hermes_sender.py"
    "${deploy_dir}/opt/pesudo/requirements.txt"
    "${deploy_dir}/opt/pesudo/.env"
)
all_ok=1
for f in "${required_files[@]}"; do
    if [[ -f "$f" ]]; then
        pass "found: $f"
    else
        info "  missing: $f"
        all_ok=0
    fi
done

if [[ "$all_ok" = "1" ]]; then
    pass "deploy dry-run 生成了正确的文件结构"
else
    fail "deploy dry-run 缺少部分文件"
fi

# ====== Test 5: deploy.sh 日志目录已创建 ======
info "\n═══ Test 5: deploy.sh 日志目录检查 ═══"
if [[ -d "/tmp/pesudo-deploy-test/var/log/pesudo" ]]; then
    pass "deploy dry-run 创建了日志目录"
else
    fail "deploy dry-run 未创建日志目录"
fi

# ====== Test 6: deploy.sh 生成了 .env 并包含 MASTER_KEY ======
info "\n═══ Test 6: .env 配置检查 ═══"
if grep -q "PESUDO_MASTER_KEY=" "${deploy_dir}/opt/pesudo/.env" 2>/dev/null; then
    pass ".env 包含 MASTER_KEY"
else
    fail ".env 缺少 MASTER_KEY"
fi
if grep -q "PESUDO_PORT=8643" "${deploy_dir}/opt/pesudo/.env" 2>/dev/null; then
    pass ".env 包含 PESUDO_PORT=8643"
else
    fail ".env 缺少 PESUDO_PORT"
fi

# ====== Test 7: pesudo.sh 入口可用 ======
info "\n═══ Test 7: pesudo.sh 入口命令 ═══"
help_out=$(bash "${PESUDO_DIR}/pesudo.sh" --help 2>&1 || true)
if echo "$help_out" | grep -q "Pesudo 统一管理入口"; then
    pass "pesudo.sh --help 正常显示"
else
    fail "pesudo.sh --help 异常"
fi

# ====== Test 8: pesudo.sh status 连接到本地服务器 ======
info "\n═══ Test 8: pesudo.sh status 本地测试 ═══"

# 启动测试服务器
MASTER_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
TEST_PORT=28643

cd "$PESUDO_DIR"
# 清理旧的 dev store（--dev 模式固定使用 /tmp/pesudo_store.json）
rm -f /tmp/pesudo_store.json
PESUDO_MASTER_KEY="$MASTER_KEY" \
PESUDO_PORT="$TEST_PORT" \
PESUDO_LOG="/tmp/pesudo_phase7_audit.log" \
PESUDO_DEV=1 \
    python3 -m server.server --dev --port "$TEST_PORT" &
SERVER_PID=$!
sleep 2

if kill -0 "$SERVER_PID" 2>/dev/null; then
    pass "测试服务器启动成功 (PID=$SERVER_PID)"
else
    fail "测试服务器启动失败"
    SERVER_PID=""
fi

# 注册一台测试机器
if [[ -n "${SERVER_PID:-}" ]]; then
    curl -s -X POST "http://localhost:${TEST_PORT}/v1/register" \
        -H "Content-Type: application/json" \
        -d '{
            "machine_id": "status-test-box",
            "hostname": "status-test-box",
            "user": "test-user",
            "tailscale_ip": "100.x.x.x",
            "encrypted_pass": "dGVzdC1wYXNz"
        }' > /dev/null
    pass "注册测试机器完成"

    # 测试 status 命令
    status_out=$(bash "${PESUDO_DIR}/pesudo.sh" status "localhost:${TEST_PORT}" 2>&1 || true)
    if echo "$status_out" | grep -q "status-test-box"; then
        pass "pesudo.sh status 显示已注册机器"
    else
        fail "pesudo.sh status 未显示机器"
    fi
fi

# ====== Test 9: pesudo.sh test 入口 ======
info "\n═══ Test 9: pesudo.sh test 运行单个 phase ═══"
help_out=$(bash "${PESUDO_DIR}/pesudo.sh" --help 2>&1 || true)
if echo "$help_out" | grep -q "test"; then
    pass "pesudo.sh test 子命令可用"
else
    fail "pesudo.sh 缺少 test 子命令"
fi

# ====== Cleanup ======
info "\n═══ 清理 ═══"
[[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
rm -f /tmp/pesudo_phase7_store.json /tmp/pesudo_phase7_audit.log
rm -rf "/tmp/pesudo-deploy-test"
pass "清理完成"

# ====== Summary ======
info ""
if [[ "$FAILED" = "0" ]]; then
    info "══════════════════════════════════════"
    info "  Phase 7 全部测试通过！"
    info "══════════════════════════════════════"
else
    info "══════════════════════════════════════"
    info "  Phase 7 部分测试失败"
    info "══════════════════════════════════════"
fi
exit "$FAILED"
