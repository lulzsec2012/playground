#!/usr/bin/env bash
# deploy.sh — iptv-api Python 部署脚本
#
# 功能：
#   1. 使用 uv 创建虚拟环境
#   2. 从 GitHub 下载 iptv-api 源码
#   3. 安装 Python 依赖
#   4. 启动 Web 服务或执行更新
#
# 用法:
#   bash deploy.sh                    # 下载源码 + 创建 venv + 安装依赖
#   bash deploy.sh --service          # 部署并启动 Web 服务（默认端口 8080）
#   bash deploy.sh --update           # 执行一次频道更新
#   bash deploy.sh --start            # 仅启动服务（跳过部署步骤）
#   bash deploy.sh --clean            # 清理所有部署产物（venv、源码、配置、输出）
#   bash deploy.sh -h, --help         # 显示帮助
#
# 依赖:
#   - git     (用于 clone 源码)
#   - uv      (用于创建虚拟环境和安装依赖)

set -euo pipefail

# ========== 配置 ==========
REPO_URL="https://github.com/Guovin/iptv-api.git"
SRC_DIR="src"
CONFIG_DIR="config"
OUTPUT_DIR="output"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ========== 颜色输出 ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }

# ========== 帮助 ==========
usage() {
    sed -n '3,17p' "$0" | sed 's/^# \?//'
    exit 0
}

# ========== 工具函数 ==========
# 从 Pipfile 提取 [packages] 部分，转为 requirements 格式
extract_deps() {
    local pipfile="$1"
    # Pipfile 格式:  package = "==version"  → 转换为 package==version
    sed -n '/^\[packages\]/,/^\[/{/^\[/d; /^$/d; p}' "$pipfile" \
        | awk -F' = "' '{gsub(/"$/, "", $2); print $1 $2}'
}

# ========== 阶段函数 ==========

check_deps() {
    if ! command -v git &>/dev/null; then
        err "git 未安装，请先安装 git"
        exit 1
    fi
    if ! command -v uv &>/dev/null; then
        err "uv 未安装，请先安装 uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
        exit 1
    fi
    info "依赖检查通过（git + uv）"
}

clone_repo() {
    local target="$SCRIPT_DIR/$SRC_DIR"
    if [ -d "$target" ]; then
        warn "源码目录已存在，更新中..."
        git -C "$target" pull --ff-only --depth 1
    else
        info "克隆 iptv-api 仓库..."
        git clone --depth 1 "$REPO_URL" "$target"
    fi
    info "iptv-api 源码已就绪（$target）"
}

setup_uv_config() {
    # 创建 uv.toml，确保多机部署时的行为一致性
    local cfg="$SCRIPT_DIR/uv.toml"
    if [ -f "$cfg" ]; then
        return  # 已有配置，跳过
    fi
    cat > "$cfg" <<'EOF'
# uv.toml — iptv-api UV 配置
# 由 deploy.sh 自动管理，手动修改会被 --clean 清理后重新生成

# link-mode: 跨文件系统时 uv 默认 hardlink 会失败降级
# 设为 copy 避免 warning，且行为更可预测
link-mode = "copy"

# 锁定 Python 版本，避免不同机器 venv 重建时版本漂移
python-preference = "only-system"
EOF
    info "uv 配置已生成（$cfg）"
}

setup_venv() {
    cd "$SCRIPT_DIR"

    # uv 配置由 setup_uv_config 管理，确保一致性
    setup_uv_config

    if [ -d ".venv" ]; then
        warn "虚拟环境已存在，跳过创建"
    else
        info "创建 uv 虚拟环境..."
        uv venv
    fi

    info "安装依赖..."
    local tmp_req
    tmp_req="$(mktemp)"
    extract_deps "$SCRIPT_DIR/$SRC_DIR/Pipfile" > "$tmp_req"

    # 也安装 dev 依赖中的 pyinstaller（可选）
    sed -n '/^\[dev-packages\]/,/^\[/{/^\[/d; /^$/d; p}' "$SCRIPT_DIR/$SRC_DIR/Pipfile" \
        | awk -F' = "' '{gsub(/"$/, "", $2); print $1 $2}' >> "$tmp_req"

    uv pip install -r "$tmp_req"
    rm -f "$tmp_req"

    info "依赖安装完成"
    cd "$OLDPWD"
}

setup_dirs() {
    mkdir -p "$SCRIPT_DIR/$CONFIG_DIR" "$SCRIPT_DIR/$OUTPUT_DIR"

    # 如果 src/config 下有默认配置模板，复制到外部 config 目录
    if [ -d "$SCRIPT_DIR/$SRC_DIR/config" ] && [ -z "$(ls -A "$SCRIPT_DIR/$CONFIG_DIR" 2>/dev/null)" ]; then
        cp -rn "$SCRIPT_DIR/$SRC_DIR/config/." "$SCRIPT_DIR/$CONFIG_DIR/" 2>/dev/null || true
        info "默认配置已复制到 $CONFIG_DIR/"
    fi

    info "数据目录已就绪"
}

clean_all() {
    cd "$SCRIPT_DIR"
    local cleaned=false
    for d in "uv.toml" ".venv" "$SRC_DIR" "$CONFIG_DIR" "$OUTPUT_DIR"; do
        if [ -e "$d" ]; then
            rm -rf "$d"
            info "已删除: $d"
            cleaned=true
        fi
    done
    $cleaned || info "没有需要清理的内容"
    cd "$OLDPWD"
}

show_usage_hint() {
    local port="5180"  # iptv-api 默认端口
    [ -f "$SCRIPT_DIR/$CONFIG_DIR/config.ini" ] \
        && port=$(grep -m1 '^app_port' "$SCRIPT_DIR/$CONFIG_DIR/config.ini" 2>/dev/null \
            | sed 's/.*= *//' || echo "5180")
    echo ""
    echo "=========================================="
    info "部署完成！可用操作："
    echo ""
    echo "  启动 Web 服务:  bash $0 --start"
    echo "  运行频道更新:   bash $0 --update"
    echo "  打开浏览器:     http://localhost:${port}"
    echo "  查看日志:       tail -f $SCRIPT_DIR/service.log"
    echo "=========================================="
}

# ========== 主流程 ==========

do_deploy() {
    check_deps
    clone_repo
    setup_venv
    setup_dirs
    show_usage_hint
}

do_start() {
    cd "$SCRIPT_DIR"

    if [ ! -d ".venv" ]; then
        err "虚拟环境不存在，请先运行: bash $0"
        exit 1
    fi
    if [ ! -d "$SRC_DIR/service" ]; then
        err "服务目录不存在，请先运行: bash $0"
        exit 1
    fi

    local python="$SCRIPT_DIR/.venv/bin/python"
    local app="$SCRIPT_DIR/$SRC_DIR/service/app.py"

    if [ ! -f "$app" ]; then
        err "未找到服务入口: $app"
        exit 1
    fi
    local port="5180"
    [ -f "$SCRIPT_DIR/$CONFIG_DIR/config.ini" ] \
        && port=$(grep -m1 '^app_port' "$SCRIPT_DIR/$CONFIG_DIR/config.ini" 2>/dev/null \
            | sed 's/.*= *//' || echo "5180")

    info "启动 iptv-api Web 服务..."
    echo "  访问地址: http://localhost:${port}"
    echo "  查看日志: tail -f $SCRIPT_DIR/service.log"
    echo "  退出: Ctrl+C"
    echo "=========================================="
    echo ""
    cd "$SCRIPT_DIR/$SRC_DIR"
    exec "$python" service/app.py
}

do_update() {
    cd "$SCRIPT_DIR"

    if [ ! -d ".venv" ]; then
        err "虚拟环境不存在，请先运行: bash $0"
        exit 1
    fi
    if [ ! -f "$SRC_DIR/main.py" ]; then
        err "更新脚本不存在，请先运行: bash $0"
        exit 1
    fi

    local python="$SCRIPT_DIR/.venv/bin/python"
    info "执行频道更新..."
    cd "$SCRIPT_DIR/$SRC_DIR"
    exec "$python" main.py
}

# ========== 参数解析 ==========
MODE="deploy"
case "${1:-}" in
    --service)  MODE="deploy-service" ;;
    --update)   MODE="update" ;;
    --start)    MODE="start" ;;
    --clean)    MODE="clean" ;;
    -h|--help)  usage ;;
    "")         ;;  # 默认 deploy
    *)
        err "未知参数: $1"
        usage
        ;;
esac

# ========== 执行 ==========
case "$MODE" in
    deploy)
        do_deploy
        ;;
    deploy-service)
        do_deploy
        echo ""
        do_start
        ;;
    start)
        do_start
        ;;
    update)
        do_update
        ;;
    clean)
        clean_all
        ;;
esac
