#!/usr/bin/env bash
# download-clash-sub.sh - Download Clash subscription & test proxies
#
# Downloads a Clash subscription URL (which may be GFW-blocked) through
# the SOCKS5 proxy, extracts proxy nodes, and optionally tests them
# via the sing-box delay API.
#
# Usage:
#   ./download-clash-sub.sh <subscription-url>
#   ./download-clash-sub.sh <subscription-url> --test    # test via sing-box
#   ./download-clash-sub.sh <subscription-url> --add     # add to config & restart
#
# The downloaded proxy YAML is saved to scripts/proxy/merged-clash.yaml
# for use with chromego-gen-config.py --proxy-yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY="${PROXY:-socks5h://127.0.0.1:1080}"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/merged-clash.yaml}"
TIMEOUT="${TIMEOUT:-15}"
DO_TEST=false

usage() { sed -n 's/^# *//p' "$0" | sed '1,2d'; exit 0; }
[[ $# -eq 0 ]] && usage

SUB_URL="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --test) DO_TEST=true; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
    CYAN='\033[0;36m'; NC='\033[0m'
else
    # shellcheck disable=SC2034
    GREEN=''; YELLOW=''; RED=''; CYAN=''; NC=''
fi

# --- Download ---
dl_ok=false
# Try via proxy first
if curl -sL -o "$OUTPUT" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 -x "$PROXY" "$SUB_URL" 2>/dev/null \
    | grep -q '200'; then
    dl_ok=true
    echo "  Downloaded via proxy ${CYAN}${PROXY}${NC}"
fi

# Fallback: direct download
if ! $dl_ok; then
    if curl -sL -o "$OUTPUT" -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 "$SUB_URL" 2>/dev/null \
        | grep -q '200'; then
        dl_ok=true
        echo "  Downloaded directly"
    fi
fi

if ! $dl_ok; then
    echo "  ${RED}Failed to download subscription${NC}"
    rm -f "$OUTPUT"
    exit 1
fi

echo "  Saved to ${CYAN}${OUTPUT}${NC}"

# --- Parse proxies ---
parse_proxies() {
    PY_OUTPUT="$OUTPUT" python3 -c '
import os, sys, yaml, json
path = os.environ["PY_OUTPUT"]
try:
    with open(path) as f:
        data = yaml.safe_load(f)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)

proxies = data.get("proxies", [])
if not proxies:
    print("No proxies found", file=sys.stderr)
    sys.exit(1)

print(json.dumps(proxies, indent=2))
'
}

echo ""
echo "  Parsing proxies..."

tmp_json=$(mktemp)
if ! parse_proxies > "$tmp_json" 2>/tmp/parse_err; then
    err=$(cat /tmp/parse_err)
    if echo "$err" | grep -q "No module named"; then
        echo "  ${YELLOW}yaml module not available, trying yq...${NC}"
        # Fallback: use grep/sed to extract proxy names
        echo "Proxies:" > "$tmp_json"
        grep -E '^  - name:' "$OUTPUT" | sed 's/  - name: //' | while read -r name; do
            type=$(grep -A5 "  - name: $name" "$OUTPUT" | grep 'type:' | head -1 | sed 's/.*type: //')
            echo "  - name: $name, type: $type"
        done
    else
        echo "  ${RED}Parse error: $err${NC}"
        rm -f "$tmp_json"
        exit 1
    fi
fi

# Display proxy summary
PY_TMP_JSON="$tmp_json" python3 -c '
import json, os, sys
path = os.environ["PY_TMP_JSON"]
with open(path) as f:
    raw = f.read()
try:
    proxies = json.loads(raw)
except json.JSONDecodeError:
    print(raw)
    sys.exit(0)

types = {}
for p in proxies:
    t = p.get("type", "unknown")
    types[t] = types.get(t, 0) + 1

print(f"  Total proxies: {len(proxies)}")
for t, c in sorted(types.items()):
    print(f"    {t}: {c}")

print()
print("  Proxy list:")
for i, p in enumerate(proxies):
    name = p.get("name", "?")
    typ = p.get("type", "?")
    server = p.get("server", "")
    port = p.get("port", "")
    plugin = f" ({p.get("plugin", "")})" if "plugin" in p else ""
    print(f"    {i+1:2d}. [{typ}] {name}{plugin}")
    if server:
        print(f"        {server}:{port}")
' 2>/dev/null || cat "$tmp_json"

# --- Test via sing-box delay API ---
if $DO_TEST; then
    api="${SING_BOX_API:-http://127.0.0.1:9090}"
    echo ""
    echo "  Testing proxies via sing-box API ${CYAN}${api}${NC}..."
    echo ""

    PY_TMP_JSON="$tmp_json" python3 -c '
import json, os, sys, subprocess

path = os.environ["PY_TMP_JSON"]
with open(path) as f:
    raw = f.read()
try:
    proxies = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

test_urls = {
    "github": "https://github.com",
    "google": "https://www.google.com/generate_204",
    "youtube": "https://www.youtube.com/generate_204",
    "cloudflare": "http://cp.cloudflare.com/generate_204",
}

for p in proxies:
    name = p.get("name", "?")
    typ = p.get("type", "?")
    safe_name = name.replace(" ", "%20")

    results = []
    for target, url in test_urls.items():
        try:
            r = subprocess.run(
                ["curl", "-s", f"{api}/proxies/{safe_name}/delay?url={url}&timeout=5000"],
                capture_output=True, text=True, timeout=10
            )
            data = json.loads(r.stdout)
            delay = data.get("delay", "X")
            results.append(f"{target}={delay}ms")
        except:
            results.append(f"{target}=X")

    alive = sum(1 for r in results if "ms" in r and r.split("=")[1].rstrip("ms").isdigit())
    status = f"{alive}/{len(test_urls)}"
    if alive == len(test_urls):
        print(f"  {GREEN}{name:30s} [{typ:10s}] {status}{NC}  " + "  ".join(results))
    elif alive > 0:
        print(f"  {YELLOW}{name:30s} [{typ:10s}] {status}{NC}  " + "  ".join(results))
    else:
        print(f"  {RED}{name:30s} [{typ:10s}] {status}{NC}  " + "  ".join(results))
' 2>/dev/null || echo "  (sing-box API test requires running instance)"
fi

rm -f "$tmp_json" /tmp/parse_err
echo ""
echo "  Done! Use ${CYAN}--proxy-yaml${NC} to merge into config:"
echo "    python3 chromego-gen-config.py --proxy-yaml merged-clash.yaml"
