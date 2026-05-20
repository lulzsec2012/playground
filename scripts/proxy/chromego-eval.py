import json, urllib.request, urllib.parse, sys

API = "http://127.0.0.1:9090"

req = urllib.request.Request(f"{API}/proxies")
resp = urllib.request.urlopen(req)
data = json.loads(resp.read())
pd = data.get("proxies", data)

results = []
for name, info in pd.items():
    if not isinstance(info, dict):
        continue
    t = info.get("type", "")
    if t in ("Selector", "Fallback", "URLTest", "Direct"):
        continue
    
    try:
        encoded = urllib.parse.quote(name, safe="")
        url = f"{API}/proxies/{encoded}/delay?url=https://cp.cloudflare.com/generate_204&timeout=5000"
        req2 = urllib.request.Request(url)
        resp2 = urllib.request.urlopen(req2, timeout=10)
        d = json.loads(resp2.read())
        delay = d.get("delay", -1)
        results.append((name, t, delay))
    except Exception:
        results.append((name, t, -1))

results.sort(key=lambda x: (x[2] if x[2] >= 0 else 9999, x[0]))
print(f"{'节点':25s} {'类型':12s} {'延迟(ms)':10s}")
print("-" * 50)
for name, t, delay in results:
    d_str = f"{delay}ms" if delay >= 0 else "超时"
    print(f" {name:25s} {t:12s} {d_str:10s}")

req3 = urllib.request.Request(f"{API}/proxies/proxy-urltest")
resp3 = urllib.request.urlopen(req3)
d3 = json.loads(resp3.read())
print(f"\n urltest 当前选择: {d3.get('now', 'unknown')}")
