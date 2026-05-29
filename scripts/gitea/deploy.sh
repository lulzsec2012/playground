#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
BACKUP_DIR="${SCRIPT_DIR}/backups"

GITEA_VERSION="1.26.2"
VOLUME_NAME="gitea_gitea-data"

# ---- 色彩输出 ----
info()  { echo -e "[\033[0;34mINFO\033[0m] $*"; }
ok()    { echo -e "[\033[0;32m OK \033[0m] $*"; }
err()   { echo -e "[\033[0;31mERR \033[0m] $*" >&2; }

# ============================================================================
# 数据目录自动检测
#   优先级: 1. /workspace/gitea (容器内，映射自宿主机 ~/workspace/gitea)
#           2. $HOME/workspace/gitea  (物理机)
#           3. 自动创建 $HOME/workspace/gitea
#
# Docker socket 跨容器时:
#   用 findmnt 反推宿主机路径，确保 bind mount 正确。反推失败时 fallback 到
#   named volume gitea-data。
# ============================================================================

is_container() {
    [ -f /.dockerenv ]
}

detect_workspace() {
    if [ -d /workspace ]; then
        echo "/workspace"
    elif [ -d "$HOME/workspace" ]; then
        echo "$HOME/workspace"
    else
        mkdir -p "$HOME/workspace"
        echo "$HOME/workspace"
    fi
}

resolve_host_path() {
    local path="$1"

    if ! is_container; then
        echo "$path"
        return 0
    fi

    if command -v findmnt &>/dev/null; then
        local source
        source=$(findmnt -T "$path" -o SOURCE --noheadings 2>/dev/null)
        # findmnt 输出格式: /dev/sda1[/host/path]，提取括号内宿主机路径
        if [ -n "$source" ] && [[ "$source" =~ \[(.+)\]$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    return 1
}

compute_data_dir() {
    local ws
    ws=$(detect_workspace)
    mkdir -p "$ws/gitea"
    chmod 700 "$ws/gitea"

    local host_path
    host_path=$(resolve_host_path "$ws" 2>/dev/null || true)

    if [ -n "$host_path" ]; then
        echo "bind|${host_path}/gitea"
    else
        echo "volume|gitea-data"
    fi
}

# ---- 获取宿主机可达 IP ----
get_host_ip() {
    if [ -n "${HOST_IP:-}" ]; then
        echo "$HOST_IP"
    else
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

# ---- Docker 检测 ----
check_docker() {
    if ! command -v docker &>/dev/null; then
        err "未找到 docker 命令。请先安装 Docker。"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        err "Docker daemon 未运行或当前用户不在 docker 组。"
        exit 1
    fi
}

# ============================================================================
# 命令实现
# ============================================================================

up() {
    check_docker

    local data_info
    data_info=$(compute_data_dir)
    local data_type="${data_info%%|*}"
    local data_value="${data_info#*|}"

    export GITEA_DATA_DIR="$data_value"
    local host_ip
    host_ip=$(get_host_ip)

    info "拉取镜像 docker.gitea.com/gitea:${GITEA_VERSION} ..."
    docker compose -f "$COMPOSE_FILE" pull || {
        err "拉取镜像失败"
        err "可尝试配置 Docker 镜像加速器，或手动 docker pull 后再执行 deploy.sh up"
        exit 1
    }

    info "启动 Gitea 服务..."
    info "数据存储: [$data_type] $data_value"
    docker compose -f "$COMPOSE_FILE" up -d

    echo ""
    ok "Gitea 已启动！"
    echo ""
    echo "  Web 界面: http://${host_ip}:3000"
    echo "  SSH 地址: ssh://git@${host_ip}:222"
    echo ""
    echo "  首次访问时会进入安装向导。"
    echo "  第一个注册的用户将自动成为管理员。"
    echo "  数据库类型选择 SQLite3 即可。"
    echo "  SSH 服务端口填 22（容器内部端口），克隆地址的端口是 222（宿主机映射端口）"
    echo ""
    if [ "$data_type" = "bind" ]; then
        echo "  数据目录: ${data_value}"
    else
        echo "  数据存储在 named volume '${VOLUME_NAME}' 中"
        echo "  查看: docker volume inspect ${VOLUME_NAME}"
    fi
    echo "  备份: bash deploy.sh backup"
    echo ""
}

down() {
    check_docker
    info "停止 Gitea 服务（数据保留）..."
    docker compose -f "$COMPOSE_FILE" down
    ok "已停止。数据保留。"
}

restart() {
    check_docker
    info "重启 Gitea..."
    docker compose -f "$COMPOSE_FILE" restart
    ok "已重启。"
}

status() {
    check_docker
    echo "Gitea 容器状态:"
    docker compose -f "$COMPOSE_FILE" ps 2>/dev/null || echo "  (未启动)"
    echo ""

    if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
        echo "数据存储: [named volume] ${VOLUME_NAME}"
        docker volume inspect "$VOLUME_NAME" --format '  名称: {{.Name}}
  驱动: {{.Driver}}
  挂载点: {{.Mountpoint}}'
        echo ""
        echo "  数据量:"
        docker run --rm -v "${VOLUME_NAME}:/data" alpine:3.20 du -sh /data 2>/dev/null || echo "    无法获取"
    elif [ -d /workspace/gitea ]; then
        echo "数据存储: [bind mount] /workspace/gitea"
        du -sh /workspace/gitea 2>/dev/null | awk '{print "  数据量: " $1}'
    elif [ -d "$HOME/workspace/gitea" ]; then
        echo "数据存储: [bind mount] $HOME/workspace/gitea"
        du -sh "$HOME/workspace/gitea" 2>/dev/null | awk '{print "  数据量: " $1}'
    else
        echo "数据存储: 尚未创建"
    fi
}

logs() {
    check_docker
    docker compose -f "$COMPOSE_FILE" logs -f
}

shell() {
    check_docker
    info "进入 Gitea 容器..."
    docker exec -it gitea /bin/bash
}

backup() {
    check_docker

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi
    local backup_file="${BACKUP_DIR}/gitea-${timestamp}.tar.gz"

    if [ -d /workspace/gitea ]; then
        info "备份 Gitea 数据（来自 /workspace/gitea）..."
        tar czf "$backup_file" -C /workspace gitea
    elif [ -d "$HOME/workspace/gitea" ]; then
        info "备份 Gitea 数据（来自 $HOME/workspace/gitea）..."
        tar czf "$backup_file" -C "$HOME/workspace" gitea
    elif docker volume inspect "$VOLUME_NAME" &>/dev/null; then
        info "备份 Gitea 数据（来自 volume '${VOLUME_NAME}'）..."
        docker run --rm \
            -v "${VOLUME_NAME}:/data" \
            -v "${BACKUP_DIR}:/backup" \
            alpine:3.20 \
            tar czf "/backup/gitea-${timestamp}.tar.gz" -C /data .
    else
        err "未找到数据（bind mount 目录和 named volume 均不存在）"
        exit 1
    fi

    ok "备份完成: ${backup_file}"
    du -h "$backup_file"
}

help() {
    echo "Gitea 部署管理脚本 — 方案 A（SQLite）"
    echo ""
    echo "用法: bash deploy.sh <命令>"
    echo ""
    echo "命令:"
    echo "  up        启动 Gitea（自动检测并 bind mount 数据目录）"
    echo "  down      停止 Gitea（数据保留）"
    echo "  restart   重启容器"
    echo "  status    查看容器和数据存储状态"
    echo "  logs      实时跟踪日志"
    echo "  shell     进入容器内部"
    echo "  backup    备份数据到 backups/"
    echo "  help      显示此帮助"
    echo ""
    echo "数据目录自动检测:"
    echo "  优先级 1: /workspace/gitea          ← 容器内"
    echo "  优先级 2: \$HOME/workspace/gitea    ← 物理机"
    echo "  优先级 3: 自动创建 \$HOME/workspace/gitea"
    echo ""
    echo "跨容器 Docker socket:"
    echo "  容器内运行时通过 findmnt 反推宿主机路径，确保 bind mount 正确。"
    echo "  反推失败时 fallback 到 named volume '${VOLUME_NAME}'。"
    echo ""
}

case "${1:-help}" in
    up)      up ;;
    down)    down ;;
    restart) restart ;;
    status)  status ;;
    logs)    logs ;;
    shell)   shell ;;
    backup)  backup ;;
    help|--help|-h) help ;;
    *)
        err "未知命令: $1"
        echo "用法: bash deploy.sh up|down|restart|status|logs|shell|backup|help"
        exit 1
        ;;
esac
