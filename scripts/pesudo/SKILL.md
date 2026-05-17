---
name: pesudo-sudo-auth
description: >-
  Guide the model to use `pesudo` instead of `sudo` when needing root privileges.
  `pesudo` sends an OTP via WeChat for authorization, preventing the LLM agent
  from ever seeing the sudo password in plaintext.
---

# Pesudo — Secure sudo replacement

## Background
When needing to execute commands that require root privileges (e.g., `apt install`, `systemctl`, editing `/etc/hosts`), use `pesudo` instead of `sudo`. The system will request authorization via WeChat — the LLM agent never handles the sudo password.

## Usage

```bash
# Instead of: sudo apt install nginx
pesudo apt install nginx

# Instead of: sudo systemctl restart docker
pesudo systemctl restart docker

# Instead of: sudo vim /etc/hosts
pesudo vim /etc/hosts

# Instead of: sudo bash script.sh
pesudo bash script.sh
```

## Constraints

1. **Never attempt to obtain or record the sudo password** — pesudo handles authentication automatically.
2. **Never output the OTP code in the terminal** — the OTP is delivered via WeChat to the user's phone.
3. **If pesudo is not found** — check if the alias is installed: `which pesudo`
4. **If "not registered" is shown** — tell the user to register first: `pesudo-register [user@host]` from any machine in the tailnet.
5. **Never manually enter or echo sudo passwords** — always use `pesudo`.
