# Project Knowledge

## Server Access

| Name | SSH Command |
|------|-------------|
| Dev container | `ssh lulizhi@100.122.161.91` (or `ssh lulizhi@10.10.18.210 -p 2222`) |
| Host | `ssh lulizhi@100.117.18.87` (or `ssh lulizhi@10.10.18.210`) |
| ECS | `ssh lzlu@39.102.52.1` |

## Project Structure

All projects/tools live under `scripts/` as independent subdirectories.
There is NOT a `projects/`, `tools/`, or `apps/` directory — it's always `scripts/<name>/`.

```
scripts/
├── docker/          # Docker work-server & container lifecycle
├── emacs/           # Emacs macOS install script
├── fileserver/      # File server (client + server + deploy)
├── mixapi/          # MIXAPI management
├── opencode/        # OpenCode install script
├── pesudo/          # Sudo replacement with audit
└── proxy/           # Proxy tools (fetch.sh, free.sh, cron)
```

New additions go into `scripts/<name>/` with its own README, scripts, and optionally a `register.sh`.

## Docker-in-Docker

The dev container runs Docker via host socket at `/var/run/docker.sock`.
Docker binds paths from the host filesystem, NOT the container filesystem.
Use `/tmp/` for paths that the host Docker daemon must access
(host maps `/home/lulizhi/.docker/tmp/` to container's `/tmp/`).

## Key Config Files

- `scripts/docker/data/ssh_keys.cfg` — public keys → authorized_keys for containers
- `scripts/docker/data/vpn.cfg` — env vars (CLASH_SUBSCRIPTION_URL, TAILSCALE_AUTH_KEY)
- `scripts/docker/home-config/bashrc/*.sh` — combined into .bashrc in order
- `scripts/docker/work-server.sh` — INSTANCES array defines port/image per instance

## Common Operations

### Launch a new instance
```bash
source /workspace/playground/scripts/docker/work-server.sh
work-server test-v1      # port 2223
IP=$(docker inspect $USER-work-server-test-v1 --format "{{.NetworkSettings.IPAddress}}")
ssh $IP                  # or ssh localhost -p 2223
```

### Create a test copy
```bash
rm -rf /tmp/playground-refactor
cd /workspace && git clone playground playground-refactor
# work in /tmp/playground-refactor, replace /workspace/playground when ready
```

## Script Registration

Each `scripts/*/` directory may contain a `register.sh` that registers tools
(PATH/alias/source) into the shell environment. The convention is:

```bash
bash scripts/install.sh              # 全量注册
bash scripts/pesudo/register.sh      # 单目录注册
bash scripts/register.sh --print     # 预览注册内容
```

- Each `register.sh` is **standalone** (detects rc, no shared library)
- Registration files are written to `~/.config/playground/registrations.d/*.sh`
- Your rc file sources the entire directory (one line, idempotent)
- `install.sh` orchestrates all `register.sh` in one pass

This replaces the old `set_alias.sh` / `install-path.sh` convention.

## Users & Groups

- Host/container UID: 6032, GID: 5005 (GroupIP)
- New containers need user created: `useradd -u 6032 -g 5005 -G sudo lulizhi`
- New users have locked accounts (`!` in shadow) — must `passwd -d lulizhi` after creation
