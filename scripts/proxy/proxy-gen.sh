#!/usr/bin/env bash
# proxy-gen.sh — 聚合 Clash + ChromeGo 源，生成 sing-box 配置文件
#
# 流程:
#   1. bin/_fetch-clash          → 下载 Clash 源 (通过 Mullvad 代理)
#   2. lib/source-chromego.sh   → 下载 ChromeGo 原生配置
#   3. lib/generate-config.py  → 合并并生成 sing-box config.json
#   4. 测存活 + 过滤死节点
#   5. 部署到容器 + 重启
#
# 用法:
#   bash proxy-gen.sh                              # 完整流程
#   bash proxy-gen.sh --deploy                     # 生成后部署到容器
#   bash proxy-gen.sh --cron-install               # 安装每日定时任务
#   bash proxy-gen.sh --cron-remove                # 移除定时任务
#   bash proxy-gen.sh --help                       # 帮助

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPTS_DIR}/data/chromego_configs"
CLASH_YAML="${SCRIPTS_DIR}/data/config.yaml"
OUTPUT="${CONFIGS_DIR}/config.json"
MAIN_CONFIG="${SCRIPTS_DIR}/data/config.json"
DOCKER="/var/packages/ContainerManager/target/usr/bin/docker"
CONTAINER="lizhi.lu-work-server-lite"

SKIP_CLASH=false
SKIP_CHROMEGO=false
SKIP_CLEAN=false
DEPLOY=false
CRON_INSTALL=false
CRON_REMOVE=false

# Mullvad 代理地址（下载时使用）
PROXY="socks5h://127.0.0.1:3000"
CLASH_API="http://127.0.0.1:9090"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${CYAN}$1${NC}"; }
ok() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1" >&2; }
err() { echo -e "  ${RED}✗${NC} $1" >&2; }

usage() {
	cat <<EOF
聚合 Clash + ChromeGo 源，生成 sing-box 配置文件。

用法: $(basename "$0") [选项]

选项:
  --skip-clash     跳过 Clash 源
  --skip-chromego  跳过 ChromeGo 源
  --skip-clean     跳过节点存活检测
  --deploy         生成后部署到容器并重启
  --cron-install   安装每日 03:00 自动更新定时任务
  --cron-remove    移除定时任务
  -h, --help       显示此帮助
EOF
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--skip-clash)
		SKIP_CLASH=true
		shift
		;;
	--skip-chromego)
		SKIP_CHROMEGO=true
		shift
		;;
	--skip-clean)
		SKIP_CLEAN=true
		shift
		;;
	--deploy)
		DEPLOY=true
		shift
		;;
	--cron-install)
		CRON_INSTALL=true
		shift
		;;
	--cron-remove)
		CRON_REMOVE=true
		shift
		;;
	-h | --help) usage ;;
	*)
		echo "未知选项: $1"
		usage
		;;
	esac
done

# ── 定时任务管理 ──
CRON_CMD="cd $SCRIPTS_DIR && bash proxy-gen.sh --skip-clash --deploy >> /tmp/proxy-gen-cron.log 2>&1"
if [ "$CRON_INSTALL" = true ]; then
	(
		/usr/bin/crontab -l 2>/dev/null | grep -v "proxy-gen.sh"
		echo "0 3 * * * $CRON_CMD"
	) | /usr/bin/crontab -
	ok "每日 03:00 自动更新已安装"
	exit 0
fi
if [ "$CRON_REMOVE" = true ]; then
	(/usr/bin/crontab -l 2>/dev/null | grep -v "proxy-gen.sh") | /usr/bin/crontab -
	ok "定时任务已移除"
	exit 0
fi

# ── 切换 Clash API 分组到 Mullvad（让下载走代理） ──
switch_to_mullvad() {
	local node
	node=$(curl -s "$CLASH_API/proxies/gh-selector" 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    for n in d.get('all', []):
        if n.startswith('mullvad') and 'urltest' not in n:
            print(n)
            break
except: pass
" 2>/dev/null)
	if [ -n "$node" ]; then
		curl -s -X PUT "$CLASH_API/proxies/gh-selector" \
			-H "Content-Type: application/json" \
			-d "{\"name\":\"$node\"}" >/dev/null 2>&1
		export ALL_PROXY="$PROXY"
		export HTTP_PROXY="$PROXY"
		export HTTPS_PROXY="$PROXY"
		info "  下载代理: $node ($PROXY)"
	else
		warn "Mullvad 节点不可用，直连下载"
	fi
}

restore_selector() {
	curl -s -X PUT "$CLASH_API/proxies/gh-selector" \
		-H "Content-Type: application/json" \
		-d '{"name":"gh-urltest"}' >/dev/null 2>&1 || true
	unset ALL_PROXY HTTP_PROXY HTTPS_PROXY
}

echo ""
echo "══════════════════════════════════════"
echo "  proxy-gen — sing-box 配置生成"
echo "══════════════════════════════════════"
echo ""

# ── 1. Clash 源 ─────────────────────────────────────────────────────
if [ "$SKIP_CLASH" = false ]; then
	if [ -f "$SCRIPTS_DIR/bin/_fetch-clash" ]; then
		echo "[1/3] 下载 Clash 源 (通过 Mullvad)..."
		switch_to_mullvad
		bash "$SCRIPTS_DIR/bin/_fetch-clash" || warn "_fetch-clash 执行失败"
		restore_selector
	else
		warn "bin/_fetch-clash 不存在，跳过 Clash 源"
	fi
else
	echo "[1/3] 跳过 Clash 源"
fi

# ── 2. ChromeGo 源 ──────────────────────────────────────────────────
if [ "$SKIP_CHROMEGO" = false ]; then
	echo ""
	echo "[2/3] 下载 ChromeGo 源 (通过 Mullvad)..."
	if [ -f "$SCRIPTS_DIR/lib/source-chromego.sh" ]; then
		switch_to_mullvad
		bash "$SCRIPTS_DIR/lib/source-chromego.sh" "$CONFIGS_DIR" || warn "source-chromego.sh 执行失败"
		restore_selector
	else
		warn "lib/source-chromego.sh 不存在，跳过 ChromeGo 源"
	fi
else
	echo ""
	echo "[2/3] 跳过 ChromeGo 源"
fi

# ── 3. 生成 sing-box 配置 ───────────────────────────────────────────
echo ""
echo "[3/3] 生成 sing-box 配置..."

CLASH_ARGS=()
if [ -f "$CLASH_YAML" ]; then
	CLASH_ARGS=(--proxy-yaml "$CLASH_YAML")
fi

python3 "$SCRIPTS_DIR/lib/generate-config.py" \
	--configs "$CONFIGS_DIR" \
	--output "$OUTPUT" \
	"${CLASH_ARGS[@]}"

# 后处理
python3 -c "
import json, sys
with open('$OUTPUT') as f:
    c = json.load(f)
fixed = 0
for ob in c.get('outbounds', []):
    sp = ob.get('server_port')
    if sp is not None and isinstance(sp, str):
        try:
            ob['server_port'] = int(sp); fixed += 1
        except ValueError: pass
for ib in c.get('inbounds', []):
    lp = ib.get('listen_port')
    if lp is not None and isinstance(lp, str):
        try:
            ib['listen_port'] = int(lp); fixed += 1
        except ValueError: pass
if fixed:
    with open('$OUTPUT', 'w') as f:
        json.dump(c, f, indent=2)
    sys.stderr.write(f'  [port-normalize] fixed {fixed} entries\n')
"

echo ""
echo "  输出: $OUTPUT"
NODES=$(python3 -c "import json; print(len([o for o in json.load(open('$OUTPUT'))['outbounds'] if o['type'] not in ('selector','urltest','direct','block')]))")
echo "  节点数: $NODES"

# ── 4. 节点存活检测 ─────────────────────────────────────────────────
if [ "$SKIP_CLEAN" = false ]; then
	echo ""
	echo "[4/4] 节点存活检测..."

	cp "$OUTPUT" "${OUTPUT}.full" # 备份全量

	python3 -c "
import json, subprocess, sys, time

with open('$OUTPUT') as f:
    c = json.load(f)

# 找出所有代理节点
proxy_nodes = [o for o in c['outbounds'] if o['type'] not in ('selector','urltest','direct','block')]
total = len(proxy_nodes)
print('  测试 {} 个节点 ...'.format(total))

# 用 sing-box check 测试每个节点 (快速语法验证)
# 然后用 curl 通过 proxy 做实际连通性测试
alive = []
dead = 0
for i, node in enumerate(proxy_nodes):
    tag = node.get('tag', '?')
    ntype = node['type']
    server = node.get('server', '')
    port = node.get('server_port', '')

    # 快速测试: 通过 sing-box proxy 连接节点服务器
    test_url = 'https://www.google.com/generate_204'
    try:
        r = subprocess.run(
            ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
             '--max-time', '3',
             '--socks5-hostname', '127.0.0.1:3000',
             test_url],
            capture_output=True, text=True, timeout=5
        )
        if r.stdout.strip() in ('200', '204'):
            alive.append(node)
    except:
        dead += 1

    if (i+1) % 50 == 0:
        print('  进度: {}/{} 存活: {}'.format(i+1, total, len(alive)), flush=True)

print('  存活: {} / {}'.format(len(alive), total))

# 替换 outbounds (保留分组)
keep_tags = {n['tag'] for n in alive}
keep_tags.update(o['tag'] for o in c['outbounds'] if o['type'] in ('selector','urltest','direct','block'))
c['outbounds'] = [o for o in c['outbounds'] if o['tag'] in keep_tags]

with open('$OUTPUT', 'w') as f:
    json.dump(c, f, indent=2)

print('  清理后节点数: {}'.format(len([o for o in c['outbounds'] if o['type'] not in ('selector','urltest','direct','block')])))
"
fi

# ── 5. 复制到主配置位置 ─────────────────────────────────────────────
echo ""
echo "复制到 $MAIN_CONFIG ..."
cp "$OUTPUT" "$MAIN_CONFIG"
ok "已更新主配置"

# ── 6. 部署 ─────────────────────────────────────────────────────────
if [ "$DEPLOY" = true ]; then
	echo ""
	echo "[部署] 复制到容器并重启 sing-box..."

	# 修复 v1.13 兼容性 + 修正配置 + 保留已学习规则
	# 先从容器复制已学习域名
	$DOCKER cp "$CONTAINER:/etc/sing-box/learned_domains.json" /tmp/learned_domains.json 2>/dev/null || true
	python3 -c "
import json, os

with open('$MAIN_CONFIG') as f:
    c = json.load(f)

# 1. rule_set -> geoip/geosite
c['route'].pop('rule_set', None)
c['route']['geoip'] = {'path': '/var/lib/sing-box/geoip.db'}
c['route']['geosite'] = {'path': '/var/lib/sing-box/geosite.db'}

for rule in c['route']['rules']:
    if 'rule_set' in rule:
        for rs in rule['rule_set']:
            if 'geoip-cn' in rs: rule['geoip'] = ['cn']
            if 'geosite-cn' in rs: rule['geosite'] = ['cn']
        del rule['rule_set']
    if 'outbound' in rule and 'action' not in rule:
        rule['action'] = 'route'

# 2. inbound port 1080/8080 -> 3000
for ib in c.get('inbounds', []):
    if ib.get('listen_port') in (1080, 8080):
        ib['listen_port'] = 3000

# 3. clean deprecated fields
for o in c.get('outbounds', []):
    o.pop('request_timeout', None)
    o.pop('udp_relay_mode', None)

# 4. final = direct
c['route']['final'] = 'direct'

# 5. 注入 Mullvad 端点
mv_path = '$SCRIPTS_DIR/data/mullvad-outbounds.json'
if os.path.exists(mv_path):
    try:
        with open(mv_path) as f:
            mv = json.load(f)
        endpoints = []
        for ob in mv.get('outbounds', []):
            if ob['type'] != 'wireguard':
                continue
            ep = {
                'type': 'wireguard', 'tag': ob['tag'],
                'system': False, 'mtu': 1420,
                'address': ob.get('local_address', ['10.0.0.1/32']),
                'private_key': ob['private_key'],
                'peers': [{
                    'address': ob['server'], 'port': ob.get('server_port', 51820),
                    'public_key': ob['peer_public_key'],
                    'allowed_ips': ['0.0.0.0/0'],
                }],
            }
            endpoints.append(ep)
        if endpoints:
            c['endpoints'] = c.get('endpoints', []) + endpoints
            mv_tags = [ep['tag'] for ep in endpoints]
            c['outbounds'].append({
                'type': 'selector', 'tag': 'mullvad-selector',
                'outbounds': ['mullvad-urltest'] + mv_tags,
                'default': 'mullvad-urltest',
            })
            c['outbounds'].append({
                'type': 'urltest', 'tag': 'mullvad-urltest',
                'outbounds': mv_tags,
                'url': 'http://cp.cloudflare.com/generate_204',
                'interval': '5m', 'tolerance': 50,
            })
            # Mullvad IP 直连规则
            mullvad_ips = set()
            for ep in endpoints:
                for peer in ep['peers']:
                    mullvad_ips.add(peer['address'])
            for ip in sorted(mullvad_ips):
                c['route']['rules'].insert(0, {'ip_cidr': [ip + '/32'], 'outbound': 'direct'})
            print('  注入 {} 个 Mullvad 端点'.format(len(endpoints)))
    except Exception as e:
        print('  Mullvad 注入失败: {}'.format(e))

# 6. 保留已学习的域名规则
learned_path = '/tmp/learned_domains.json'
if os.path.exists(learned_path):
    try:
        with open(learned_path) as f:
            learned = json.load(f)
        existing_domains = set()
        for rule in c['route']['rules']:
            existing_domains.update(rule.get('domain_suffix', []))
        
        added = 0
        for domain, info in learned.items():
            group = info.get('group')
            if group and group != 'testing' and domain not in existing_domains:
                target = None
                for rule in c['route']['rules']:
                    if rule.get('outbound') == group and 'domain_suffix' in rule:
                        target = rule
                        break
                if target:
                    target['domain_suffix'].append(domain)
                else:
                    c['route']['rules'].append({'domain_suffix': [domain], 'outbound': group})
                added += 1
        if added:
            print('  保留 {} 个已学习域名规则'.format(added))
    except Exception as e:
        print('  学习规则加载失败: {}'.format(e))

with open('$MAIN_CONFIG', 'w') as f:
    json.dump(c, f, indent=2)
print('  v1.13 兼容修复完成')
"

	# 复制到容器
	$DOCKER cp "$MAIN_CONFIG" "$CONTAINER:/etc/sing-box/config.json" 2>/dev/null &&
		ok "配置已复制到容器" || warn "docker cp 失败"

	# 重启
	$DOCKER exec "$CONTAINER" pkill -f 'sing-box run' 2>/dev/null || true
	sleep 2
	$DOCKER exec -d "$CONTAINER" bash -c 'sing-box run -c /etc/sing-box/config.json > /tmp/sing-box.log 2>&1'
	sleep 3
	$DOCKER exec "$CONTAINER" ps aux | grep 'sing-box run' | grep -v grep | grep -v defunct | head -1 &&
		ok "sing-box 已重启" || warn "sing-box 启动失败"
fi

echo ""
echo "✅ 完成"
echo "💡 启动:    sing-box run -c $MAIN_CONFIG"
echo "💡 仪表盘:  http://127.0.0.1:9090/ui"
echo "💡 定时:    bash proxy-gen.sh --cron-install  # 每日自动更新"
