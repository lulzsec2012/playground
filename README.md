# Playground

Containerized development environments for AI/compiler work.

## Structure

```
├── scripts/
│   ├── docker/
│   │   ├── work-server.sh         Multi-instance container runner (source me)
│   │   ├── generate-home-config.sh  Generate container $HOME config
│   │   ├── home-config/           Template files for container home directories
│   │   │   ├── bashrc/            .bashrc fragments (sourced in order)
│   │   │   ├── profile            .profile template
│   │   │   ├── gitconfig          Git config template
│   │   │   ├── pip/pip.conf       pip with Aliyun mirror
│   │   │   └── ssh/config         SSH client config
│   │   ├── data/                  Private data (gitignored — keys, VPN cfg, etc.)
│   │   │   └── ssh_keys.cfg       Public keys → authorized_keys
│   │   ├── setup-docker-mirror.sh Docker daemon registry mirror config
│   │   └── setup-docker-proxy.sh  Docker daemon HTTP proxy config
│   ├── utils.sh                   Utility functions
│   ├── tailscale/                 Tailscale deployment tools
│   ├── proxy/                     Proxy configuration
│   ├── emacs/                     Emacs setup scripts
│   ├── hermes/                    Hermes toolkit
│   └── mixapi/                    MIXAPI toolkit
└── docker/                [git submodule] lulzsec2012/docker — Dockerfiles
```

## Usage

```bash
# Source the runner to get work-server commands
source scripts/docker/work-server.sh

# List available instances
work-server-ls

# Start default instance (port 2222)
work-server default

# Start test instance on port 2223
work-server test-v1

# Force regenerate config and restart
work-server test-v1 -f

# SSH into a running instance
ssh -p 2223 lulizhi@localhost

# Enter container directly
work-server-exec test-v1

# Stop/remove
work-server-stop test-v1
work-server-rm test-v1
```

## Instances

Each instance gets independent home config at `/tmp/.docker-instances/<name>/`,
auto-generated on first launch from `home-config/` templates + `data/`.

## Image

`lulzsec2012/work-cuda-dev:cuda13.2-ubuntu24.04`

Built from `lulzsec2012/docker` repo via GitHub Actions.
