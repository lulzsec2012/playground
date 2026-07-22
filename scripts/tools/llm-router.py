#!/usr/bin/env python3
"""LLM Router — 自动选择最优 LLM 后端

监听本地端口，根据当前环境自动选择最快的后端:
  1. localhost (本机 vLLM)     → 0 额外延迟
  2. Tailscale (同一 tailnet)  → ~12ms 延迟  
  3. MixAPI (公网)             → 兜底

用法:
  python3 llm-router.py                    # 默认端口 8000
  python3 llm-router.py --port 8000        # 指定端口
  python3 llm-router.py --daemon           # 后台运行

OpenCode 配置:
  provider: llm-router
  baseURL: http://localhost:8000/v1
  所有设备（本机 / Tailscale / 外网）统一配置这个地址，
  router 会自动路由到最优后端。
"""

import json, os, sys, socket, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import URLError
from urllib.parse import urlparse

DEFAULT_PORT = 8000

# ── 后端配置 ──────────────────────────────────────────────────────────
# 优先级从高到低排列，第一个可达的即被选中
BACKENDS = [
    {
        "name": "localhost",
        "host": "127.0.0.1",
        "ports": {"qwen3.6-27b": 8002, "gemma4-26b-fp8": 8001},
        "api_key": None,
    },
    {
        "name": "tailscale",
        "host": "100.101.118.89",
        "ports": {"qwen3.6-27b": 8002, "gemma4-26b-fp8": 8001},
        "api_key": None,
    },
    {
        "name": "mixapi",
        "host": "39.102.52.1",
        "port": 3000,
        "api_key": os.environ.get("MIXAPI_API_KEY", ""),
    },
]

# ── 后端探测 ──────────────────────────────────────────────────────────

def port_open(host, port, timeout=1):
    """检测某个端口是否开放"""
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except (OSError, socket.timeout):
        return False

def select_backend(model):
    """按优先级选择第一个可达的后端"""
    for bk in BACKENDS:
        if bk["name"] == "mixapi":
            return bk  # mixapi 总是作为兜底返回
        port = bk["ports"].get(model)
        if port and port_open(bk["host"], port):
            return bk
    return BACKENDS[-1]  # 兜底

# ── HTTP 处理 ─────────────────────────────────────────────────────────

class RouterHandler(BaseHTTPRequestHandler):
    server_version = "LLMRouter/1.0"
    
    def _build_url(self, bk, model=None):
        """根据选中的后端构造目标 URL"""
        if bk["name"] == "mixapi":
            return f"http://{bk['host']}:{bk['port']}/v1{self.path}"
        port = bk["ports"].get(model, 8002)
        return f"http://{bk['host']}:{port}/v1{self.path}"
    
    def _forward(self, body=None):
        """转发请求到选中的后端"""
        # 解析模型名称
        model = "qwen3.6-27b"
        if body:
            try:
                model = json.loads(body).get("model", model)
            except json.JSONDecodeError:
                pass
        
        bk = select_backend(model)
        target_url = self._build_url(bk, model)
        
        # 构造转发请求
        req = Request(target_url, data=body.encode() if body else None,
                      method=self.command)
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length", "transfer-encoding"):
                continue
            req.add_header(k, v)
        if bk.get("api_key"):
            req.add_header("Authorization", f"Bearer {bk['api_key']}")
        
        try:
            resp = urlopen(req, timeout=180)
            data = resp.read()
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() in ("content-length", "content-encoding",
                                 "transfer-encoding", "connection"):
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            # 日志
            model_label = model.split("/")[-1][:20]
            print(f"  [{bk['name']:10s}] {model_label:20s} {resp.status} {len(data)}B")
        except URLError as e:
            self.send_error(502, f"Backend error: {e.reason}")
            print(f"  [{bk['name']:10s}] ERROR: {e.reason}")
    
    def do_GET(self):
        if self.path.startswith("/v1"):
            self._forward()
        else:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "service": "LLM Router",
                "backends": [b["name"] for b in BACKENDS],
                "usage": "配置 OpenCode 的 baseURL 为 http://localhost:8000/v1"
            }).encode())
    
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0))).decode()
        self._forward(body)
    
    def log_message(self, format, *args):
        pass  # 安静运行

def main():
    port = DEFAULT_PORT
    daemon = False
    for i, arg in enumerate(sys.argv[1:]):
        if arg == "--port" and i + 2 < len(sys.argv):
            port = int(sys.argv[i + 2])
        elif arg == "--daemon":
            daemon = True
        elif arg in ("-h", "--help"):
            print(__doc__); return
    
    server = HTTPServer(("0.0.0.0", port), RouterHandler)
    print(f"🚀 LLM Router 启动 :{port}")
    print(f"   路由策略: localhost → Tailscale → MixAPI")
    print(f"   OpenCode 配置: http://localhost:{port}/v1")
    print()
    
    if daemon:
        proc = os.fork()
        if proc == 0:
            os.setsid()
            server.serve_forever()
        else:
            print(f"  PID: {proc}")
    else:
        server.serve_forever()

if __name__ == "__main__":
    main()
