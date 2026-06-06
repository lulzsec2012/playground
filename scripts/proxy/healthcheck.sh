#!/usr/bin/env bash
# Healthcheck watchdog for sing-box proxy.
# Tests SOCKS5 proxy against key sites. Restarts on failure, triggers
# full regeneration on repeated failures.
#
# Usage:
#   ./healthcheck.sh                    # run once (for cron)
#   ./healthcheck.sh --repair           # force full repair + restart
#   ./healthcheck.sh --check-only       # test only, no action
#
# Exit codes:
#   0 = all sites reachable
#   1 = some sites unreachable (repaired or queued repair)
#   2 = proxy port not listening

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY="socks5h://127.0.0.1:1080"
LOG_FILE="${SCRIPT_DIR}/chromego_logs/healthcheck.log"
FAIL_COUNTER="${SCRIPT_DIR}/chromego_logs/.healthcheck_fails"
SERVICE="sing-box-chromego"
CONFIG_DIR="${SCRIPT_DIR}/chromego_configs"
CONFIG_FILE="${CONFIG_DIR}/config.json"
MAX_FAILS=3
TIMEOUT=8

mkdir -p "$(dirname "$LOG_FILE")"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; echo "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

check_site() {
    local url="$1" label="$2"
    local code
    code=$(curl -s --proxy "$PROXY" --max-time "$TIMEOUT" \
        -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^[2-3][0-9]{2}$ ]]; then
        info "OK  $label ($code)"
        return 0
    else
        warn "FAIL $label ($code)"
        return 1
    fi
}

restart_service() {
    info "Restarting $SERVICE..."
    if command -v systemctl &>/dev/null; then
        sudo systemctl restart "$SERVICE" 2>/dev/null || true
        sleep 3
        if sudo systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            info "Service restarted OK"
            return 0
        else
            err "Service failed to restart"
            return 1
        fi
    else
        # Fallback: try direct sing-box restart
        pkill sing-box 2>/dev/null || true
        sleep 2
        nohup sing-box run -c "$CONFIG_FILE" >/dev/null 2>&1 &
        sleep 3
        return 0
    fi
}

full_repair() {
    info "=== FULL REPAIR ==="
    
    # 1. Fetch ChromeGo sources
    if [[ -x "${SCRIPT_DIR}/chromego-source.sh" ]]; then
        info "Fetching ChromeGo nodes..."
        bash "${SCRIPT_DIR}/chromego-source.sh" 2>&1 | while IFS= read -r line; do log "  $line"; done
    fi
    
    # 2. Fetch Clash nodes
    if [[ -x "${SCRIPT_DIR}/fetch.sh" ]]; then
        info "Fetching Clash nodes..."
        bash "${SCRIPT_DIR}/fetch.sh" 2>&1 | while IFS= read -r line; do log "  $line"; done
    fi
    
    # 3. Generate new config
    local yaml_arg=""
    if [[ -f "${SCRIPT_DIR}/config.yaml" ]]; then
        yaml_arg="--proxy-yaml ${SCRIPT_DIR}/config.yaml"
    fi
    info "Generating config..."
    python3 "${SCRIPT_DIR}/chromego-gen-config.py" \
        --configs "$CONFIG_DIR" \
        $yaml_arg \
        --output "$CONFIG_FILE" \
        --listen "0.0.0.0" --port 1080 2>&1 | while IFS= read -r line; do log "  $line"; done
    
    # 4. Restart service
    restart_service
    
    info "=== REPAIR COMPLETE ==="
}

main() {
    local mode="${1:-check}"
    
    case "$mode" in
        --repair)
            full_repair
            rm -f "$FAIL_COUNTER"
            exit 0
            ;;
        --check-only)
            check_site "https://www.youtube.com" "YouTube"
            check_site "https://github.com" "GitHub"
            check_site "https://www.google.com" "Google"
            exit 0
            ;;
    esac
    
    # Check if proxy port is listening
    if ! ss -tln 2>/dev/null | grep -q ":1080 "; then
        err "Port 1080 not listening"
        restart_service || full_repair
        exit 2
    fi
    
    # Test key sites
    local ok=0 fail=0
    check_site "https://www.youtube.com/generate_204" "YouTube" && ok=$((ok+1)) || fail=$((fail+1))
    check_site "https://github.com" "GitHub" && ok=$((ok+1)) || fail=$((fail+1))
    check_site "https://www.google.com" "Google" && ok=$((ok+1)) || fail=$((fail+1))
    
    local total=$((ok+fail))
    info "Results: ${ok}/${total} sites OK"
    
    if [[ "$fail" -eq 0 ]]; then
        # All good, reset failure counter
        rm -f "$FAIL_COUNTER"
        exit 0
    fi
    
    # Count consecutive failures
    local fails=1
    if [[ -f "$FAIL_COUNTER" ]]; then
        fails=$(cat "$FAIL_COUNTER" 2>/dev/null || echo 1)
        fails=$((fails + 1))
    fi
    echo "$fails" > "$FAIL_COUNTER"
    warn "Consecutive failures: $fails/$MAX_FAILS"
    
    if [[ "$fails" -ge "$MAX_FAILS" ]]; then
        err "Max consecutive failures reached, triggering full repair"
        full_repair
        rm -f "$FAIL_COUNTER"
    else
        warn "Restarting service (attempt $fails/$MAX_FAILS)"
        restart_service
    fi
    
    exit 1
}

main "$@"
