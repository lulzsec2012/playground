#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/home-config"
DATA_DIR="$SCRIPT_DIR/data"

usage() {
    echo "Usage: $0 <output_dir> [-f]"
    echo ""
    echo "Generate container home directory configuration."
    echo ""
    echo "  output_dir    Target directory (will be created if not exist)"
    echo "  -f            Force overwrite existing files"
    exit 1
}

generate_authorized_keys() {
    local src="$1"
    local dst="$2"
    if [[ -f "$src" ]]; then
        > "$dst"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            echo "$line" >> "$dst"
        done < "$src"
        echo "  authorized_keys: $(wc -l < "$dst") keys"
    fi
}

generate_bashrc() {
    local target="$1"
    local fragment_dir="$TEMPLATE/bashrc"

    : > "$target"
    for f in "$fragment_dir"/*.sh; do
        echo "# --- $(basename "$f") ---" >> "$target"
        cat "$f" >> "$target"
        echo "" >> "$target"
    done
    echo "  .bashrc: $(wc -l < "$target") lines from $(ls "$fragment_dir"/*.sh | wc -l) fragments"
}

generate() {
    local target_dir="$1"
    local force="${2:-false}"

    mkdir -p "$target_dir/.ssh" "$target_dir/.pip"

    if [[ ! -f "$target_dir/.bashrc" || "$force" == true ]]; then
        generate_bashrc "$target_dir/.bashrc"
    fi

    for src in profile gitconfig; do
        local dst="$target_dir/.$src"
        if [[ ! -f "$dst" || "$force" == true ]]; then
            cp "$TEMPLATE/$src" "$dst"
            echo "  .$src"
        fi
    done

    for src in pip.conf; do
        local dst="$target_dir/.pip/$src"
        if [[ ! -f "$dst" || "$force" == true ]]; then
            cp "$TEMPLATE/pip/$src" "$dst"
            echo "  .pip/$src"
        fi
    done

    for src in config; do
        local dst="$target_dir/.ssh/$src"
        if [[ ! -f "$dst" || "$force" == true ]]; then
            cp "$TEMPLATE/ssh/$src" "$dst"
            echo "  .ssh/$src"
        fi
    done

    if [[ ! -f "$target_dir/.ssh/authorized_keys" || "$force" == true ]]; then
        generate_authorized_keys "$DATA_DIR/ssh_keys.cfg" "$target_dir/.ssh/authorized_keys"
    fi

    if [[ ! -f "$target_dir/.ssh/vpn.cfg" || "$force" == true ]]; then
        if [[ -f "$DATA_DIR/vpn.cfg" ]]; then
            cp "$DATA_DIR/vpn.cfg" "$target_dir/.ssh/vpn.cfg"
            echo "  .ssh/vpn.cfg (from data/)"
        else
            touch "$target_dir/.ssh/vpn.cfg"
            echo "  .ssh/vpn.cfg (empty placeholder)"
        fi
    fi

    if [[ -f "$DATA_DIR/.authinfo" && (! -f "$target_dir/.authinfo" || "$force" == true) ]]; then
        cp "$DATA_DIR/.authinfo" "$target_dir/.authinfo"
        echo "  .authinfo"
    fi

    if [[ -f "$DATA_DIR/env.cfg" ]]; then
        echo "# --- env.cfg ---" >> "$target_dir/.bashrc"
        cat "$DATA_DIR/env.cfg" >> "$target_dir/.bashrc"
        echo "" >> "$target_dir/.bashrc"
        echo "  env.cfg -> .bashrc ($(wc -l < "$DATA_DIR/env.cfg") lines)"
    fi

    echo "✅ Config generated: $target_dir"
}

if [[ $# -lt 1 ]]; then
    usage
fi

force=false
target_dir=""
for arg in "$@"; do
    case "$arg" in
        -f) force=true ;;
        -*|--*) echo "Unknown option: $arg"; usage ;;
        *) target_dir="$arg" ;;
    esac
done

if [[ -z "$target_dir" ]]; then
    usage
fi

generate "$target_dir" "$force"
