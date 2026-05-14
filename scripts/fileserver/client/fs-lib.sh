_fs_check_cmds() {
    for cmd in curl rsync ssh; do
        command -v "$cmd" &>/dev/null || {
            echo "[fs] 错误: 需要 $cmd，请先安装" >&2
            return 1
        }
    done
}

# ---------- 加载配置 ----------

_fs_load_config() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cfg="$lib_dir/fileserver.conf"

    if [ ! -f "$cfg" ]; then
        echo "[fs] 错误: 配置文件不存在" >&2
        echo "   请复制 fileserver.conf.TEMPLATE 为 fileserver.conf 并编辑" >&2
        return 1
    fi

    # 保存环境变量（允许外部覆盖 config）
    local _env_fs_mode="${FS_MODE:-}"
    local _env_ssh_host="${FS_SSH_HOST:-}"
    local _env_ssh_port="${FS_SSH_PORT:-}"
    local _env_ssh_user="${FS_SSH_USER:-}"

    source "$cfg"

    local local_cfg="$lib_dir/fileserver.conf.local"
    [ -f "$local_cfg" ] && source "$local_cfg"

    [ -n "$_env_fs_mode" ]   && FS_MODE="$_env_fs_mode"
    [ -n "$_env_ssh_host" ]  && FS_SSH_HOST="$_env_ssh_host"
    [ -n "$_env_ssh_port" ]  && FS_SSH_PORT="$_env_ssh_port"
    [ -n "$_env_ssh_user" ]  && FS_SSH_USER="$_env_ssh_user"

    FS_HOST="${FS_HOST:-fileserver}"
    FS_PORT="${FS_PORT:-8080}"
    FS_MODE="${FS_MODE:-auto}"
    FS_SSH_PORT="${FS_SSH_PORT:-22}"
    FS_SSH_USER="${FS_SSH_USER:-lzlu}"
}

# ---------- 模式检测 ----------

_fs_detect_mode() {
    [ "${FS_MODE:-auto}" != "auto" ] && return 0

    if curl -sf -o /dev/null --max-time 2 "http://${FS_HOST}:${FS_PORT}/api/health" 2>/dev/null; then
        FS_MODE="tailscale"
        echo "[fs] 模式: Tailscale 内网 (${FS_HOST}:${FS_PORT})" >&2
    elif [ -n "${FS_SSH_HOST:-}" ]; then
        FS_MODE="ssh"
        echo "[fs] 模式: SSH 公网 (${FS_SSH_USER}@${FS_SSH_HOST}:${FS_SSH_PORT})" >&2
    else
        echo "[fs] 错误: 无法检测文件服务器" >&2
        echo "   确认 Tailscale 已接入且 fileserver:8080 可达" >&2
        echo "   或在 fileserver.conf 中配置 FS_SSH_HOST" >&2
        return 1
    fi
}

_fs_is_tailscale() { [ "${FS_MODE:-}" = "tailscale" ]; }
_fs_is_ssh()       { [ "${FS_MODE:-}" = "ssh" ]; }

# ---------- SSH 执行 ----------

_fs_ssh() {
    local target="${FS_SSH_USER}@${FS_SSH_HOST}"
    if [ "${FS_SSH_PORT:-22}" != "22" ]; then
        ssh -p "$FS_SSH_PORT" "$target" "$@"
    else
        ssh "$target" "$@"
    fi
}

_fs_sudo_ssh() {
    _fs_ssh "sudo $*"
}

# ---------- Filebrowser API (Tailscale 模式) ----------

_fs_login() {
    _fs_is_tailscale || return 0
    [ -n "${FS_TOKEN:-}" ] && return 0

    local resp
    resp=$(curl -sf -X POST "http://${FS_HOST}:${FS_PORT}/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${FS_USER:?[fs] 错误: FS_USER 未设置}\",\"password\":\"${FS_PASS:?[fs] 错误: FS_PASS 未设置}\"}") || {
        echo "[fs] 错误: Filebrowser 登录失败" >&2
        return 1
    }

    FS_TOKEN=$(echo "$resp" | sed 's/.*"token":"\([^"]*\)".*/\1/')
    [ -n "$FS_TOKEN" ] || {
        echo "[fs] 错误: 获取登录 Token 失败" >&2
        return 1
    }
}

_fs_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    _fs_login || return 1

    curl -sf -X "$method" "http://${FS_HOST}:${FS_PORT}${endpoint}" \
        -H "X-Auth: ${FS_TOKEN}" \
        -H "Content-Type: application/json" \
        "$@"
}

# ---------- 文件操作 ----------

_fs_format_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.0f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

_fs_format_date() {
    local ls_month="$1" ls_day="$2" ls_time="$3"
    # Convert ls date format (e.g. "May 14 15:30" or "May 14  2023") to YYYY-MM-DD HH:MM
    local months="Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec"
    local num=1 i
    for i in $months; do
        [ "$i" = "$ls_month" ] && break
        num=$((num + 1))
    done
    local mon=$(printf "%02d" $num)
    local day=$(printf "%02d" $((10#$ls_day)))

    # If ls_time contains : it's HH:MM, otherwise it's a year
    if echo "$ls_time" | grep -q ':'; then
        # This year - use current year
        echo "$(date +%Y)-${mon}-${day} ${ls_time}"
    else
        # Older file - ls_time is the year
        echo "${ls_time}-${mon}-${day} 00:00"
    fi
}

_fs_format_list_tailscale() {
    local json="$1"
    # Filebrowser API returns array of items or {items: [...]}
    # Extract items - try both formats
    local items
    items=$(echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict):
    data = data.get('items', data.get('listing', []))
if not isinstance(data, list):
    data = [data]
for item in data:
    name = item.get('name', '?')
    is_dir = item.get('isDir', False)
    size = item.get('size', 0)
    mtime = item.get('modified', '')
    kind = 'd' if is_dir else '-'
    print(f'{kind}|{size}|{mtime}|{name}')
" 2>/dev/null) || {
        echo "[fs] 错误: 列表解析失败" >&2
        return 1
    }

    local header="权限    大小      修改日期           名称"
    echo "$header"

    local total_items=0
    local total_size=0

    while IFS='|' read -r kind size mtime name; do
        [ -z "$kind" ] && continue
        total_items=$((total_items + 1))
        total_size=$((total_size + size))

        local perm="${kind}rw-"
        local size_str
        size_str=$(_fs_format_size "$size")
        local date_str="${mtime:0:10} ${mtime:11:5}"

        printf "%-7s %5s  %s  %s\n" "$perm" "$size_str" "$date_str" "$name"
    done <<< "$items"

    local total_size_str
    total_size_str=$(_fs_format_size "$total_size")
    echo "—— 总计: ${total_items} 项, ${total_size_str} ——"
}

_fs_format_list_ssh() {
    local raw_output="$1"
    local had_header=false
    local header="权限    大小      修改日期           名称"

    local total_items=0
    local total_size=0

    while IFS= read -r line; do
        case "$line" in
            total*) continue ;;
            "")     continue ;;
            *" ."$'\t'*) continue ;;
            *" .."$'\t'*) continue ;;
            *" ./"*)  continue ;;
            *" ../"*) continue ;;
            ".")    continue ;;
            "..")   continue ;;
        esac
        [ -z "$line" ] && continue

        # drwxr-xr-x 2 user group 4.0K May 15 10:00 name
        # -rw-r--r-- 1 user group 2.0G May 14  2023 name
        local perms link_count owner group size month day time_or_year name
        read -r perms link_count owner group size month day time_or_year name <<< "$line" 2>/dev/null || continue
        [ -z "$perms" ] && continue

        # Skip . and .. entries (by name)
        case "$name" in
            .|..) continue ;;
        esac

        total_items=$((total_items + 1))

        # Convert size like 4.0K, 2.0G to display string (pass through since ls -h already does this)
        local size_str="$size"
        # pad size to right-aligned
        size_str=$(printf "%5s" "$size_str")

        # Convert permissions: drwxr-xr-x → drw- (simplified)
        local type_char="${perms:0:1}"
        local user_perm="${perms:1:3}"
        # user_perm = rwx → rw-, r-x → r--, etc.
        local display_perm="${type_char}${user_perm:0:1}${user_perm:1:1}"
        [ "${user_perm:2}" = "x" ] && display_perm="${display_perm}x" || display_perm="${display_perm}-"
        # Truncate to 5 chars for display
        display_perm=$(printf "%-5s" "${display_perm:0:5}")

        # Parse date
        local date_str
        date_str=$(_fs_format_date "$month" "$day" "$time_or_year")

        # Print formatted line
        if ! $had_header; then
            echo "$header"
            had_header=true
        fi

        printf "%-7s %s  %s  %s\n" "$display_perm" "$size_str" "$date_str" "$name"

        # Parse size in bytes for total (handle K/M/G suffixes)
        local suffix="${size: -1}"
        local num_val="${size%?}"
        case "$suffix" in
            K) total_size=$((total_size + $(awk "BEGIN {printf \"%d\", $num_val * 1024}" 2>/dev/null || echo 0))) ;;
            M) total_size=$((total_size + $(awk "BEGIN {printf \"%d\", $num_val * 1048576}" 2>/dev/null || echo 0))) ;;
            G) total_size=$((total_size + $(awk "BEGIN {printf \"%d\", $num_val * 1073741824}" 2>/dev/null || echo 0))) ;;
            T) total_size=$((total_size + $(awk "BEGIN {printf \"%d\", $num_val * 1099511627776}" 2>/dev/null || echo 0))) ;;
            *) total_size=$((total_size + ${size:-0})) ;;
        esac 2>/dev/null || true
    done <<< "$raw_output"

    local total_size_str
    total_size_str=$(_fs_format_size "$total_size")
    echo "—— 总计: ${total_items} 项, ${total_size_str} ——"
}

_fs_remote_list() {
    local path="${1:-/}"
    if _fs_is_tailscale; then
        local json
        json=$(_fs_api GET "/api/resources${path}") || {
            echo "[fs] 错误: 列表获取失败" >&2
            return 1
        }
        _fs_format_list_tailscale "$json"
    elif _fs_is_ssh; then
        local raw
        raw=$(_fs_ssh "ls -lah '/data/files${path}'") || {
            echo "[fs] 错误: 列表获取失败" >&2
            return 1
        }
        _fs_format_list_ssh "$raw"
    fi
}

_fs_remote_upload() {
    local src="$1"
    local dst_dir="${2:-/}"

    if [ ! -e "$src" ]; then
        echo "[fs] 错误: 本地路径不存在: $src" >&2
        return 1
    fi

    if _fs_is_tailscale; then
        if [ -d "$src" ]; then
            _fs_tailscale_upload_dir "$src" "${dst_dir%/}" || return 1
        else
            _fs_login || return 1
            local fname
            fname="$(basename "$src")"
            curl -sf -X POST "http://${FS_HOST}:${FS_PORT}/api/resources${dst_dir%/}/${fname}?override=true" \
                -H "X-Auth: ${FS_TOKEN}" \
                -H "Content-Type: application/octet-stream" \
                --data-binary "@${src}" >/dev/null || {
                echo "[fs] 错误: 上传失败" >&2
                return 1
            }
            echo "[fs] 上传完成: ${src} → ${dst_dir}" >&2
        fi

    elif _fs_is_ssh; then
        local remote_base="/data/files${dst_dir%/}"
        _fs_ssh "sudo mkdir -p '${remote_base}'" || return 1
        rsync -avzP --rsync-path="sudo rsync" \
            ${FS_BWLIMIT:+--bwlimit=$FS_BWLIMIT} \
            -e "ssh${FS_SSH_PORT:+ -p ${FS_SSH_PORT}}" \
            "$src" "${FS_SSH_USER}@${FS_SSH_HOST}:${remote_base}/" || {
            echo "[fs] 错误: rsync 上传失败" >&2
            return 1
        }
        if [ -d "$src" ]; then
            # 目录：rsync 会复制内容到 remote_base，直接 chown remote_base
            _fs_ssh "sudo chown -R fileserver:fileserver '${remote_base}'" || true
        else
            # 文件：rsync 复制到 remote_base/basename
            local fname
            fname="$(basename "$src")"
            _fs_ssh "sudo chown -R fileserver:fileserver '${remote_base}/${fname}'" || true
        fi
        echo "[fs] 上传完成: ${src} → ${remote_base}/" >&2
    fi
}

# Tailscale 模式：递归上传目录
_fs_tailscale_upload_dir() {
    local src_dir="$1"
    local dst_dir="$2"
    src_dir="${src_dir%/}"

    local file_count=0
    while IFS= read -r -d '' file; do
        [ -z "$file" ] && continue
        local rel_path="${file#$src_dir/}"
        local remote_path="${dst_dir}/${rel_path}"

        _fs_login || return 1
        curl -sf -X POST "http://${FS_HOST}:${FS_PORT}/api/resources${remote_path}?override=true" \
            -H "X-Auth: ${FS_TOKEN}" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@${file}" >/dev/null || {
            echo "[fs] 错误: 上传失败: ${rel_path}" >&2
            return 1
        }
        file_count=$((file_count + 1))
        echo "[fs] 上传: ${rel_path}" >&2
    done < <(find "$src_dir" -type f -print0)

    [ "$file_count" -eq 0 ] && {
        echo "[fs] 警告: 目录为空，无文件上传" >&2
        return 0
    }

    echo "[fs] 目录上传完成: ${file_count} 个文件" >&2
}

# Tailscale 模式：下载单个文件
_fs_tailscale_dl_file() {
    local remote_path="$1"
    local local_path="$2"
    _fs_login || return 1
    curl -sf "http://${FS_HOST}:${FS_PORT}/api/raw${remote_path}" \
        -H "X-Auth: ${FS_TOKEN}" \
        -o "$local_path" || {
        echo "[fs] 错误: 下载失败: ${remote_path}" >&2
        return 1
    }
    echo "[fs] 下载: ${remote_path}" >&2
}

# Tailscale 模式：递归下载目录
_fs_tailscale_dl_dir() {
    local remote_dir="$1"
    local local_dir="$2"

    mkdir -p "$local_dir" || return 1

    local json
    json=$(_fs_api GET "/api/resources${remote_dir}") || return 1

    local items
    items=$(echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict):
    data = data.get('items', data.get('listing', []))
for item in data:
    name = item.get('name', '')
    is_dir = item.get('isDir', False)
    if name and name not in ('.', '..'):
        kind = 'directory' if is_dir else 'file'
        print(f'{kind}|{name}')
" 2>/dev/null) || {
        echo "[fs] 错误: 解析目录列表失败" >&2
        return 1
    }

    local exit_code=0
    while IFS='|' read -r typ name; do
        [ -z "$name" ] && continue
        local remote_item="${remote_dir%/}/${name}"
        local local_item="${local_dir}/${name}"

        if [ "$typ" = "directory" ]; then
            _fs_tailscale_dl_dir "$remote_item" "$local_item" || exit_code=1
        else
            _fs_tailscale_dl_file "$remote_item" "$local_item" || exit_code=1
        fi
    done <<< "$items"

    return $exit_code
}

_fs_remote_download() {
    local src="$1"
    local dst_dir="${2:-.}"

    if [ ! -d "$dst_dir" ]; then
        mkdir -p "$dst_dir" || return 1
    fi

    if _fs_is_tailscale; then
        local filename
        filename="$(basename "$src")"
        local local_target="${dst_dir}/${filename}"

        # 先尝试作为目录列表（以 / 结尾或响应包含 items）
        local json
        json=$(_fs_api GET "/api/resources${src%/}/" 2>/dev/null) || {
            # 不是目录，当作文件下载
            _fs_tailscale_dl_file "$src" "$local_target" || return 1
            return 0
        }

        # 检查响应是否包含 items（说明是目录）
        local has_items
        has_items=$(echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict) and ('items' in data or 'listing' in data):
    print('yes')
else:
    print('no')
" 2>/dev/null)

        if [ "$has_items" = "yes" ]; then
            _fs_tailscale_dl_dir "$src" "$local_target"
        else
            _fs_tailscale_dl_file "$src" "$local_target" || return 1
        fi

    elif _fs_is_ssh; then
        rsync -avzP --rsync-path="sudo rsync" \
            ${FS_BWLIMIT:+--bwlimit=$FS_BWLIMIT} \
            -e "ssh${FS_SSH_PORT:+ -p ${FS_SSH_PORT}}" \
            "${FS_SSH_USER}@${FS_SSH_HOST}:/data/files${src}" "$dst_dir" || {
            echo "[fs] 错误: rsync 下载失败" >&2
            return 1
        }
        echo "[fs] 下载完成: ${src} → ${dst_dir}" >&2
    fi
}

# ---------- 删除 ----------

_fs_remote_delete() {
    local path="$1"
    local recursive="${2:-false}"

    if _fs_is_tailscale; then
        # 优先尝试 Filebrowser API 删除（静默登录，失败走 SSH 回退）
        if _fs_login 2>/dev/null; then
            if curl -sf -X DELETE "http://${FS_HOST}:${FS_PORT}/api/resources${path}" \
                -H "X-Auth: ${FS_TOKEN}" >/dev/null 2>&1; then
                echo "[fs] 已删除: ${path}" >&2
                return 0
            fi
        fi

        # API 删除失败（非空目录或网络不通）→ 自动 SSH 回退
        if [ -n "${FS_SSH_HOST:-}" ]; then
            local remote_path="/data/files${path}"
            [ "${FS_SSH_HOST:-}" != "${FS_SSH_HOST#fileserver}" ] && echo "[fs] 注意: FS_SSH_HOST 应设为公网 IP，非 Tailscale 主机名" >&2
            echo "[fs] Filebrowser API 不可用，通过 SSH 回退删除..." >&2
            _fs_ssh "sudo rm -rf '${remote_path}'" || {
                echo "[fs] 错误: SSH 回退删除也失败: ${path}" >&2
                return 1
            }
            echo "[fs] 已删除: ${path}" >&2
            return 0
        fi

        # 无 SSH 配置，给出提示
        echo "[fs] 错误: 删除失败: ${path}" >&2
        echo "   可能是 Tailscale 网络不通或目录非空" >&2
        echo "   请在 fileserver.conf 中配置 FS_SSH_HOST 以启用 SSH 回退" >&2
        return 1

    elif _fs_is_ssh; then
        local remote_path="/data/files${path}"
        local rm_flags="-rf"
        [ "$recursive" = "false" ] && rm_flags="-f"

        _fs_ssh "sudo rm ${rm_flags} '${remote_path}'" || {
            echo "[fs] 错误: 删除失败: ${path}" >&2
            return 1
        }
        echo "[fs] 已删除: ${path}" >&2
    fi
}

# ---------- 移动/重命名 ----------

_fs_remote_move() {
    if [ $# -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo "[fs] 错误: 需要源路径和目标路径" >&2
        return 1
    fi

    local src="$1"
    local dst="$2"

    if _fs_is_tailscale; then
        # 优先尝试 Filebrowser API 重命名（静默登录，失败走 SSH 回退）
        if _fs_login 2>/dev/null; then
            local payload
            payload=$(printf '{"action": "rename", "destination": "%s"}' "${dst}")
            if curl -sf -X PATCH "http://${FS_HOST}:${FS_PORT}/api/resources${src}" \
                -H "X-Auth: ${FS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$payload" >/dev/null 2>&1; then
                echo "[fs] 已移动/重命名: ${src} → ${dst}" >&2
                return 0
            fi
        fi

        # API 重命名失败 → 自动 SSH 回退
        if [ -n "${FS_SSH_HOST:-}" ]; then
            echo "[fs] Filebrowser API 不可用，通过 SSH 回退移动..." >&2
            _fs_ssh "sudo mv '/data/files${src}' '/data/files${dst}'" || {
                echo "[fs] 错误: SSH 回退移动失败: ${src} → ${dst}" >&2
                return 1
            }
            echo "[fs] 已移动/重命名: ${src} → ${dst}" >&2
            return 0
        fi

        echo "[fs] 错误: 移动失败: ${src} → ${dst}" >&2
        echo "   请在 fileserver.conf 中配置 FS_SSH_HOST 以启用 SSH 回退" >&2
        return 1

    elif _fs_is_ssh; then
        _fs_ssh "sudo mv '/data/files${src}' '/data/files${dst}'" || {
            echo "[fs] 错误: 移动失败: ${src} → ${dst}" >&2
            return 1
        }
        echo "[fs] 已移动/重命名: ${src} → ${dst}" >&2
    fi
}

# ---------- 复制 ----------

_fs_remote_copy() {
    if [ $# -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        echo "[fs] 错误: 需要源路径和目标路径" >&2
        return 1
    fi

    local src="$1"
    local dst="$2"

    if _fs_is_tailscale; then
        # Filebrowser API 无复制端点，必须走 SSH 回退
        if [ -n "${FS_SSH_HOST:-}" ]; then
            echo "[fs] Tailscale 模式无复制 API，通过 SSH 回退复制..." >&2
            _fs_ssh "sudo cp -r '/data/files${src}' '/data/files${dst}'" || {
                echo "[fs] 错误: SSH 回退复制失败: ${src} → ${dst}" >&2
                return 1
            }
            echo "[fs] 已复制: ${src} → ${dst}" >&2
            return 0
        fi

        echo "[fs] 错误: Tailscale 模式不支持复制（无 SSH 回退）" >&2
        return 1

    elif _fs_is_ssh; then
        _fs_ssh "sudo cp -r '/data/files${src}' '/data/files${dst}'" || {
            echo "[fs] 错误: 复制失败: ${src} → ${dst}" >&2
            return 1
        }
        echo "[fs] 已复制: ${src} → ${dst}" >&2
    fi
}

# 分享 — 需要服务端 sudo，始终走 SSH
_fs_remote_share() {
    local path="$1"
    local password="${2:-}"
    local ttl="${3:-}"

    local share_id="s$(date +%s)$((RANDOM % 10000))"

    if [ -n "$ttl" ]; then
        _fs_sudo_ssh "fs-share-helper create-with-ttl '${share_id}' '${path}' '${ttl}'" || return 1
    elif [ -n "$password" ]; then
        _fs_sudo_ssh "fs-share-helper create-protected '${share_id}' '${path}' '${password}'" || return 1
    else
        _fs_sudo_ssh "fs-share-helper create '${share_id}' '${path}'" || return 1
    fi

    local public_ip
    public_ip=$(_fs_get_public_ip) || public_ip="${FS_SSH_HOST}"

    echo "http://${public_ip}:${FS_PORT}/s/${share_id}"
    [ -n "$password" ] && echo "${password}"
}

_fs_remote_unshare() {
    local share_id="$1"
    _fs_sudo_ssh "fs-share-helper delete '${share_id}'" || return 1
    echo "[fs] 分享已删除: ${share_id}" >&2
}

_fs_remote_list_shares() {
    _fs_sudo_ssh "fs-share-helper list" || return 1
}

# ---------- 信息查询 ----------

# ---------- 磁盘信息 ----------

_fs_remote_df() {
    if _fs_is_tailscale && [ -z "${FS_SSH_HOST:-}" ]; then
        echo "[fs] 错误: Tailscale 模式不支持查看磁盘（无 SSH 回退）" >&2
        return 1
    fi

    echo "[fs] 文件服务器磁盘使用情况:" >&2
    echo "" >&2
    echo "分区使用:" >&2
    _fs_ssh "df -h /data/files" || return 1
    echo "" >&2
    echo "文件总大小:" >&2
    _fs_ssh "sudo du -sh /data/files" || return 1
}

_fs_get_public_ip() {
    if _fs_is_tailscale; then
        local ip
        _fs_login
        ip=$(curl -sf "http://${FS_HOST}:${FS_PORT}/api/raw/public-ip.txt" \
            -H "X-Auth: ${FS_TOKEN}" 2>/dev/null) && {
            echo "$ip"
            return 0
        }
    fi

    if [ -n "${FS_SSH_HOST:-}" ]; then
        local ip
        ip=$(_fs_ssh "cat /data/files/public-ip.txt" 2>/dev/null) && {
            echo "$ip"
            return 0
        }
        echo "$FS_SSH_HOST"
        return 0
    fi

    echo "[fs] 错误: 无法获取公网 IP" >&2
    return 1
}

_fs_health_check() {
    if _fs_is_tailscale; then
        echo "[fs] 检测 Tailscale 内网连接..." >&2
        curl -sf -o /dev/null --max-time 3 "http://${FS_HOST}:${FS_PORT}/api/health" && {
            echo "[fs] ✅ HTTP API 可达 (${FS_HOST}:${FS_PORT})" >&2
            return 0
        }
        echo "[fs] ❌ HTTP API 不可达" >&2
        return 1
    fi

    if _fs_is_ssh; then
        echo "[fs] 检测 SSH 连接..." >&2
        _fs_ssh "echo ok" &>/dev/null && {
            echo "[fs] ✅ SSH 可达 (${FS_SSH_USER}@${FS_SSH_HOST}:${FS_SSH_PORT})" >&2
            return 0
        }
        echo "[fs] ❌ SSH 不可达" >&2
        return 1
    fi

    return 1
}
