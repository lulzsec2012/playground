#!/usr/bin/env bash
# deploy.sh — 部署 Pesudo 授权服务器到远程节点
#
# 用法:
#   bash server/deploy.sh                    # 部署到 Tailscale auth-server
#   bash server/deploy.sh user@host          # 部署到指定主机
#   bash server/deploy.sh --dry-run          # Dry-run 模式（本地测试目录）
#   bash server/deploy.sh --help             # 帮助

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ====== 配置 ======
REMOTE_DIR="/opt/pesudo"
LOG_DIR="/var/log/pesudo"
SERVICE_NAME="pesudo-server"

# ====== 格式化输出 ======
source_if_exists() {
    [[ -f "$1" ]] && source "$1" || true
}
source_if_exists "${PROJECT_DIR}/lib/lib-format.sh"

# fallback 输出函数
if ! command -v info >/dev/null 2>&1; then
    info()  { echo -e "\033[0;36m$*\033[0m" >&2; }
    ok()    { echo -e "  \033[0;32m✓\033[0m $*" >&2; }
    warn()  { echo -e "  \033[1;33m⚠\033[0m $*" >&2; }
    die()   { echo -e "\033[0;31m❌ $*\033[0m" >&2; exit 1; }
fi

usage() {
    cat >&2 <<EOF
用法: bash server/deploy.sh [target] [options]

部署 Pesudo 授权服务器到远程节点。

参数:
  target                SSH 目标 (默认: auth-server)

选项:
  --dry-run             Dry-run 模式: 部署到 /tmp/pesudo-deploy-test
  --help                显示此帮助

示例:
  bash server/deploy.sh                    # 部署到 auth-server
   bash server/deploy.sh user@host          # 部署到指定主机
  bash server/deploy.sh --dry-run          # 本地 dry-run
EOF
    exit 0
}

# ====== 部署逻辑 ======

do_deploy() {
    local target="$1"
    local is_dry_run="$2"

    section "Pesudo 授权服务器部署"

    # --- Step 1: 前提检查 ---
    info "Step 1: 前提检查"

    if [[ "$is_dry_run" = "1" ]]; then
        target="localhost"
        REMOTE_DIR="/tmp/pesudo-deploy-test/opt/pesudo"
        LOG_DIR="/tmp/pesudo-deploy-test/var/log/pesudo"
        info "   Dry-run 模式 → ${REMOTE_DIR}"
        mkdir -p "$REMOTE_DIR" "$LOG_DIR"
    else
        ssh "$target" "command -v python3" >/dev/null 2>&1 \
            || die "目标机器需要 Python 3.10+，未找到 python3"
        local py_version
        py_version=$(ssh "$target" "python3 --version" 2>/dev/null)
        info "   $py_version"
    fi
    ok "前提检查通过"

    # --- Step 2: 创建目录 ---
    info "Step 2: 创建目录"
    if [[ "$is_dry_run" = "1" ]]; then
        mkdir -p "$REMOTE_DIR" "$LOG_DIR"
    else
        ssh "$target" "mkdir -p ${REMOTE_DIR} ${LOG_DIR}" || die "目录创建失败"
    fi
    ok "目录已创建"

    # --- Step 3: 同步代码 ---
    info "Step 3: 同步代码"
    local server_src="${PROJECT_DIR}/server/"
    local exclude_file="${PROJECT_DIR}/server/.deploy-exclude"

    # 生成 exclude 文件
    cat > /tmp/pesudo-deploy-exclude.txt << 'EXCL'
__pycache__
*.pyc
.pytest_cache
*.egg-info
.git
EXCL

    if [[ "$is_dry_run" = "1" ]]; then
        rsync -az --delete --exclude-from=/tmp/pesudo-deploy-exclude.txt \
            "$server_src" "${REMOTE_DIR}/" 2>&1 | head -5
        info "   已同步 $(find "${REMOTE_DIR}" -type f | wc -l) 个文件"
    else
        rsync -az --delete --exclude-from=/tmp/pesudo-deploy-exclude.txt \
            "$server_src" "${target}:${REMOTE_DIR}/" || die "代码同步失败"
        info "   $(ssh "$target" "find ${REMOTE_DIR} -type f | wc -l") 个文件已同步"
    fi
    ok "代码同步完成"

    # --- Step 4: 安装 Python 依赖（venv） ---
    info "Step 4: 安装 Python 依赖"
    if [[ "$is_dry_run" = "1" ]]; then
        info "   (dry-run, 跳过)"
    else
        # 确保 python3-venv 已安装
        ssh "$target" "dpkg -l python3-venv &>/dev/null || sudo apt-get install -y -qq python3-venv" \
            || die "无法安装 python3-venv"
        # 创建 venv
        ssh "$target" "test -d ${REMOTE_DIR}/venv || python3 -m venv ${REMOTE_DIR}/venv" \
            || die "venv 创建失败"
        # 安装依赖
        ssh "$target" "${REMOTE_DIR}/venv/bin/pip install -q -r ${REMOTE_DIR}/requirements.txt" \
            || die "pip install 失败"
    fi
    ok "依赖安装完成"

    # --- Step 5: 生成 .env ---
    info "Step 5: 配置 .env"
    if [[ "$is_dry_run" = "1" ]]; then
        if [[ ! -f "${REMOTE_DIR}/.env" ]]; then
            cp "${PROJECT_DIR}/server/.env.TEMPLATE" "${REMOTE_DIR}/.env"
            # 生成随机 MASTER_KEY
            local test_key
            test_key=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || echo "test-key-not-available")
            sed -i '' "s|^PESUDO_MASTER_KEY=.*|PESUDO_MASTER_KEY=${test_key}|" "${REMOTE_DIR}/.env"
            info "   已生成测试密钥"
        fi
    else
        if ! ssh "$target" "test -f ${REMOTE_DIR}/.env" 2>/dev/null; then
            info "   首次部署，生成 .env 配置..."
            # 生成 MASTER_KEY
            local master_key
            master_key=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
            ssh "$target" "cp ${REMOTE_DIR}/.env.TEMPLATE ${REMOTE_DIR}/.env"
            ssh "$target" "sed -i 's|^PESUDO_MASTER_KEY=.*|PESUDO_MASTER_KEY=${master_key}|' ${REMOTE_DIR}/.env"
            info "   请保存此 MASTER_KEY (仅此一次可见):"
            warn "   ${master_key}"
        else
            info "   .env 已存在，跳过"
        fi
    fi
    ok "配置就绪"

    # --- Step 6: 安装 systemd 服务 ---
    info "Step 6: 安装 systemd 用户服务"
    if [[ "$is_dry_run" = "1" ]]; then
        local service_dst="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
        mkdir -p "$(dirname "$service_dst")"
        cp "${SCRIPT_DIR}/${SERVICE_NAME}.service" "$service_dst"
        info "   服务文件: ${service_dst}"
    else
        ssh "$target" "mkdir -p ~/.config/systemd/user"
        scp -q "${SCRIPT_DIR}/${SERVICE_NAME}.service" \
            "${target}:~/.config/systemd/user/${SERVICE_NAME}.service" || die "服务文件复制失败"
        ssh "$target" "systemctl --user daemon-reload && systemctl --user enable --now ${SERVICE_NAME}" \
            || warn "服务启用失败，请手动检查: ssh ${target} 'systemctl --user status ${SERVICE_NAME}'"
    fi
    ok "服务已安装"

    # --- Step 7: 验证 ---
    info "Step 7: 验证服务"
    if [[ "$is_dry_run" = "1" ]]; then
        info "   (dry-run, 跳过启动验证)"
    else
        sleep 3
        local check_host
        check_host="${target#*@}"
        local health
        health=$(curl -sf "http://${check_host}:8643/v1/health" 2>/dev/null || echo "")
        if [[ -z "$health" ]]; then
            warn "服务可能尚未就绪，请稍后手动验证:"
            warn "   curl -sf http://${check_host}:8643/v1/health"
        else
            ok "服务运行正常: ${health}"
        fi
    fi
    ok "部署完成"
}

# ====== 主流程 ======

main() {
    local target="auth-server"
    local is_dry_run=0

    for arg in "$@"; do
        case "$arg" in
            --dry-run) is_dry_run=1 ;;
            --help|-h) usage ;;
            *)
                    if [[ "$target" = "auth-server" ]]; then
                    target="$arg"
                fi
                ;;
        esac
    done

    do_deploy "$target" "$is_dry_run"
}

main "$@"
