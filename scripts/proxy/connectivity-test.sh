#!/usr/bin/env bash
# connectivity-test.sh - Test proxy connectivity for a list of sites
#
# Tests each site through the SOCKS5 proxy and shows reachable/unreachable.
# Reads from a URL list file, or defaults to domains from site-groups.yaml.
#
# Usage:
#   ./connectivity-test.sh                              # test site-groups.yaml domains
#   ./connectivity-test.sh -f my-sites.txt               # test custom URL list
#   ./connectivity-test.sh -p socks5://127.0.0.1:1080   # custom proxy addr
#   ./connectivity-test.sh -t 5                          # custom timeout (seconds)
#   ./connectivity-test.sh -v                            # verbose
#   ./connectivity-test.sh --machine                     # machine-readable output
#
# File format (-f): one URL or "label|URL" per line, # for comments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY="${PROXY:-socks5h://127.0.0.1:1080}"
TIMEOUT="${TIMEOUT:-8}"
VERBOSE=false
FILE=""
MACHINE=false

usage() { sed -n 's/^# *//p' "$0" | sed '1,2d'; exit 0; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -f|--file) FILE="$2"; shift 2 ;;
        -p|--proxy) PROXY="$2"; shift 2 ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        --machine) MACHINE=true; shift ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

ok=0; fail=0
URLS=()

if [[ -n "$FILE" ]]; then
    [[ -f "$FILE" ]] || { echo "Error: file not found: $FILE" >&2; exit 1; }
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        URLS+=("$line")
    done < "$FILE"
else
    YAML="$SCRIPT_DIR/site-groups.yaml"
    if [[ -f "$YAML" ]]; then
        mapfile -t URLS < <(python3 -c '
import sys, yaml
try:
    with open("'"$YAML"'") as f:
        groups = yaml.safe_load(f)
except Exception:
    sys.exit(1)
for key, g in (groups or {}).items():
    label = g.get("label", key)
    domains = g.get("domains", [])
    if domains:
        d = domains[0]
        print(f"{label}|https://www.{d}/generate_204")
        print(f"{label}|https://{d}")
' 2>/dev/null || true)
    fi
    if [[ ${#URLS[@]} -eq 0 ]]; then
        URLS=(
            "YouTube|https://www.youtube.com/generate_204"
            "GitHub|https://github.com"
            "Telegram|https://telegram.org"
            "AI|https://www.bing.com"
            "Google|https://www.google.com/generate_204"
            "Docker Hub|https://www.docker.com"
            "Hugging Face|https://huggingface.co"
        )
    fi
fi

if ! $MACHINE; then
    echo ""
    echo "  Proxy: ${CYAN}${PROXY}${NC}"
    echo "  Timeout: ${YELLOW}${TIMEOUT}s${NC}"
    echo ""
fi

for entry in "${URLS[@]}"; do
    if [[ "$entry" == *"|"* ]]; then
        label="${entry%%|*}"; url="${entry#*|}"
    else
        label="$(echo "$entry" | sed 's|https\?://||' | cut -d/ -f1)"
        url="$entry"
    fi

    if ! $MACHINE; then
        printf "  %-14s ... " "$label"
    fi

    # curl writes "000" via %{http_code} on failure, so || true keeps
    # output clean while preventing set -e from triggering.
    code=$(curl -sL -o /dev/null -w '%{http_code}' \
        --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 2))" \
        -x "$PROXY" "$url" 2>/dev/null || true)
    time=$(curl -sL -o /dev/null -w '%{time_total}' \
        --connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 2))" \
        -x "$PROXY" "$url" 2>/dev/null || true)

    if $MACHINE; then
        if [[ "$code" == "000" ]]; then
            echo "FAIL|${code}|${time}|${label}|${url}"
        else
            echo "OK|${code}|${time}|${label}|${url}"
        fi
        continue
    fi

    if [[ "$code" == "000" ]]; then
        printf "${RED}FAIL${NC} timeout\n"
        ((fail++))
        $VERBOSE && curl -v --connect-timeout 2 --max-time 4 \
            -x "$PROXY" "$url" 2>&1 | head -5 >&2
    elif [[ "$code" -ge 200 && "$code" -lt 400 ]]; then
        printf "${GREEN}OK${NC}   HTTP %s (%.2fs)\n" "$code" "$time"
        ((ok++))
    else
        printf "${RED}FAIL${NC} HTTP %s (%.2fs)\n" "$code" "$time"
        ((fail++))
    fi
done

if ! $MACHINE; then
    total=$((ok + fail))
    echo "  -------"
    echo "  Total: ${total}  |  ${GREEN}OK: ${ok}${NC}  |  ${RED}FAIL: ${fail}${NC}"
    echo ""
fi
