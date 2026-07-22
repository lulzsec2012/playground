#!/usr/bin/env python3
"""Langfuse Lite — 轻量级 LLM Token 消耗统计服务

监听 :3010，兼容 Langfuse ingestion API 格式。
Router 自动检测到它后，会推送 token 日志。
数据存储在 SQLite，随时可查。

用法:
  python3 langfuse-lite.py              # 前台运行
  python3 langfuse-lite.py --daemon     # 后台运行
  python3 langfuse-lite.py --query      # 查询统计摘要
  python3 langfuse-lite.py --query-detail  # 查询详细记录

Router 会自动检测 :3010 并开始推送数据。
"""

import sys, json, os, sqlite3, datetime, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

DB_PATH = os.path.join(os.path.dirname(__file__), "data", "token_log.db")

def get_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS token_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            time REAL,
            model TEXT,
            provider TEXT,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            total_tokens INTEGER,
            duration_ms INTEGER
        )
    """)
    conn.commit()
    return conn

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/api/public/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        if self.path == "/api/public/ingestion":
            length = int(self.headers.get("content-length", 0))
            body = json.loads(self.rfile.read(length))
            records = []
            for item in body.get("batch", []):
                b = item.get("body", {})
                u = b.get("usage", {})
                meta = b.get("metadata", {}) or {}
                t = b.get("startTime", datetime.datetime.now().isoformat())
                records.append((
                    b.get("model", "?"),
                    meta.get("provider", b.get("provider", "?")),
                    u.get("input", 0), u.get("output", 0), u.get("total", 0),
                    0, t
                ))
            if records:
                conn = get_db()
                conn.executemany(
                    "INSERT INTO token_log (model,provider,prompt_tokens,completion_tokens,total_tokens,duration_ms,time) VALUES (?,?,?,?,?,?,?)",
                    records
                )
                conn.commit()
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404); self.end_headers()

def query(conn):
    cur = conn.execute("""
        SELECT model, provider,
               SUM(prompt_tokens), SUM(completion_tokens), SUM(total_tokens),
               COUNT(*), MAX(time)
        FROM token_log
        GROUP BY model, provider
        ORDER BY SUM(total_tokens) DESC
    """)
    print(f"{'模型':30s} {'供应商':12s} {'输入':>8s} {'输出':>8s} {'总计':>8s} {'请求数':>6s}")
    print("-"*80)
    for r in cur:
        m, p, pt, ct, tt, n, t = r
        if isinstance(t, str): t = t[:19]
        print(f"{m:30s} {p:12s} {pt:>8d} {ct:>8d} {tt:>8d} {n:>6d}")
    cur = conn.execute("SELECT SUM(total_tokens), MAX(time) FROM token_log")
    tt, lt = cur.fetchone()
    print(f"\n总计: {tt:,} tokens | 最后记录: {lt}")

if __name__ == "__main__":
    if "--query" in sys.argv:
        query(get_db())
    elif "--query-detail" in sys.argv:
        cur = get_db().execute("SELECT * FROM token_log ORDER BY id DESC LIMIT 20")
        for r in cur:
            print(f"{r[3]:12s} {r[2]:30s} in={r[4]} out={r[5]} total={r[6]} {r[7]}ms")
    elif "--daemon" in sys.argv:
        pid = os.fork()
        if pid > 0: print(pid); sys.exit(0)
        os.setsid()
        if os.fork() > 0: os._exit(0)
        HTTPServer(("0.0.0.0", 3010), Handler).serve_forever()
    else:
        print("Langfuse Lite :3010 (SQLite: " + DB_PATH + ")")
        HTTPServer(("0.0.0.0", 3010), Handler).serve_forever()
