# Project Knowledge

## Server Access

| Name | SSH Command |
|------|-------------|
| Dev container | `ssh lulizhi@100.122.161.91` (or `ssh lulizhi@10.10.18.210 -p 2222`) |
| Host | `ssh lulizhi@100.117.18.87` (or `ssh lulizhi@10.10.18.210`) |
| ECS | `ssh lzlu@39.102.52.1` |

## Docker-in-Docker

The dev container runs Docker via host socket at `/var/run/docker.sock`.
Docker binds paths from the host filesystem, NOT the container filesystem.
Use `/tmp/` for paths that the host Docker daemon must access
(host maps `/home/lulizhi/.docker/tmp/` to container's `/tmp/`).

## Key Config Files

- `data/ssh_keys.cfg` — public keys → authorized_keys for containers
- `data/vpn.cfg` — env vars (CLASH_SUBSCRIPTION_URL, TAILSCALE_AUTH_KEY)
- `home-config/bashrc/*.sh` — combined into .bashrc in order
- `run.sh` — INSTANCES array defines port/image per instance

## Common Operations

### Launch a new instance
```bash
source /workspace/playground/run.sh
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

## Users & Groups

- Host/container UID: 6032, GID: 5005 (GroupIP)
- New containers need user created: `useradd -u 6032 -g 5005 -G sudo lulizhi`
- New users have locked accounts (`!` in shadow) — must `passwd -d lulizhi` after creation
