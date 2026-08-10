#!/usr/bin/env bash
# ============================================================================
# sync-wiki-push.sh — 把 llmwiki 编译产物 wiki/ 写回 CouchDB (LiveSync 格式)
#
# 背景:
#   llmwiki compile 产物在服务器 /opt/llmwiki/wiki/，客户端不可见。
#   本脚本把 wiki/ 下的 .md 增量推送到 CouchDB my-vault，LiveSync 同步到各客户端。
#   LiveSync 明文模式: 文件 = plain 文档(path/children/ctime/mtime/size)
#                     + leaf 文档(_id=h:xxx, data=文件内容)。
#   LiveSync 块大小不固定（存在 94KB 单块先例），写回用单块即可。
#
# 用法:
#   bash sync-wiki-push.sh              # 增量推送（默认）
#   bash sync-wiki-push.sh --force      # 全量推送（覆盖所有 wiki 文档）
#   bash sync-wiki-push.sh --daemon     # 每 30s 循环（配合 systemd）
#
# 凭据(按优先级):
#   1. 环境变量 COUCHDB_USER / COUCHDB_PASSWORD
#   2. 同仓库 scripts/obsidian/configs/couchdb-connection.txt（gitignored）
# ============================================================================
set -euo pipefail

WIKI_DIR="${WIKI_DIR:-/opt/llmwiki/wiki}"
COUCH_URL="${COUCH_URL:-http://127.0.0.1:5984}"
COUCH_DB="${COUCH_DB:-my-vault}"
STATE_FILE="${STATE_FILE:-/tmp/wiki-push.state}"
MODE="${1:-once}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/../configs/couchdb-connection.txt"

# ---- 凭据解析: 环境变量 > configs/couchdb-connection.txt ----
COUCH_USER="${COUCHDB_USER:-}"
COUCH_PASS="${COUCHDB_PASSWORD:-}"
if [[ -z "$COUCH_USER" || -z "$COUCH_PASS" ]] && [[ -f "$CONN_FILE" ]]; then
	COUCH_USER="${COUCH_USER:-$(grep -oP 'Username: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
	COUCH_PASS="${COUCH_PASS:-$(grep -oP 'Password: \K\S+' "$CONN_FILE" 2>/dev/null || true)}"
fi
if [[ -z "$COUCH_USER" || -z "$COUCH_PASS" ]]; then
	echo "缺少 CouchDB 凭据" >&2
	exit 1
fi

COUCH_URL="$COUCH_URL" COUCH_DB="$COUCH_DB" WIKI_DIR="$WIKI_DIR" \
	COUCH_USER="$COUCH_USER" COUCH_PASS="$COUCH_PASS" STATE_FILE="$STATE_FILE" \
	MODE="$MODE" python3 <<'PYEOF'
import base64, hashlib, json, os, random, string, sys, time, urllib.parse, urllib.request

couch_url = os.environ["COUCH_URL"]
couch_db = os.environ["COUCH_DB"]
wiki_dir = os.environ["WIKI_DIR"]
auth = "Basic " + base64.b64encode(f'{os.environ["COUCH_USER"]}:{os.environ["COUCH_PASS"]}'.encode()).decode()
state_file = os.environ["STATE_FILE"]
mode = os.environ["MODE"]
BASE = f"{couch_url}/{couch_db}"

def req(method, url, data=None):
    r = urllib.request.Request(url, method=method,
        data=json.dumps(data).encode() if data else None)
    r.add_header("Authorization", auth)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:300]}

def load_state():
    if os.path.exists(state_file):
        try:
            return json.load(open(state_file))
        except Exception:
            return {}
    return {}

def save_state(st):
    tmp = state_file + ".tmp"
    json.dump(st, open(tmp, "w"))
    os.replace(tmp, state_file)

def rand_hash():
    return "h:" + "".join(random.choices(string.ascii_lowercase + string.digits, k=12))

def push_file(rel_path, abs_path, force):
    content = open(abs_path, "rb").read().decode("utf-8", errors="replace")
    fhash = hashlib.md5(content.encode()).hexdigest()
    state = load_state()
    if not force and state.get(rel_path) == fhash:
        return 0
    now_ms = int(time.time() * 1000)
    doc_id = urllib.parse.quote(rel_path, safe="")
    existing = req("GET", f"{BASE}/{doc_id}")
    rev = existing.get("_rev") if isinstance(existing, dict) else None
    h = rand_hash()
    leaf = {"_id": h, "type": "leaf", "data": content}
    plain = {"_id": rel_path, "type": "plain", "path": rel_path,
             "children": [h], "ctime": now_ms, "mtime": now_ms,
             "size": len(content.encode())}
    if rev:
        plain["_rev"] = rev
    res = req("POST", f"{BASE}/_bulk_docs", {"docs": [leaf, plain]})
    ok = isinstance(res, list) and all(x.get("ok") for x in res)
    if ok:
        st = load_state(); st[rel_path] = fhash; save_state(st)
        print(f"推送: {rel_path} ({len(content.encode())}B)")
        return 1
    print(f"失败: {rel_path} -> {res}", file=sys.stderr)
    return 0

def push_all(force=False):
    count = 0
    for root, _, files in os.walk(wiki_dir):
        for fn in sorted(files):
            if not fn.endswith(".md"):
                continue
            abs_path = os.path.join(root, fn)
            rel = os.path.relpath(abs_path, wiki_dir)
            rel_path = f"wiki/{rel}"
            count += push_file(rel_path, abs_path, force)
    # 删除同步: 已推送但本地不存在的文档
    state = load_state()
    for rel_path in list(state.keys()):
        abs_path = os.path.join(wiki_dir, rel_path[len("wiki/"):])
        if not os.path.exists(abs_path):
            doc_id = urllib.parse.quote(rel_path, safe="")
            ex = req("GET", f"{BASE}/{doc_id}")
            if isinstance(ex, dict) and ex.get("_rev"):
                req("DELETE", f"{BASE}/{doc_id}?rev={ex['_rev']}")
            del state[rel_path]
            print(f"删除: {rel_path}")
    save_state(state)
    print(f"本轮推送 {count} 个文件")
    return count

if mode == "--force":
    push_all(force=True)
elif mode == "--daemon":
    interval = int(os.environ.get("WIKI_PUSH_INTERVAL", "30"))
    print(f"守护模式: 每 {interval}s 增量推送")
    while True:
        try:
            push_all()
        except Exception as e:
            print(f"推送异常: {e}", file=sys.stderr)
        time.sleep(interval)
else:
    push_all()
PYEOF
