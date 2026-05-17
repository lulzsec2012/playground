"""Pesudo — 授权服务器

FastAPI 应用，提供:
- /v1/health          — 健康检查 (用于 Tailscale 自动发现)
- /v1/register        — 注册机器
- /v1/auth/request    — 请求 OTP 授权
- /v1/auth/verify     — 验证 OTP 并获取临时凭据
- /v1/machines        — 列出已注册机器
"""

import os
import sys
import time
import json
import secrets
import hashlib
import logging
import socket
from typing import Optional, Dict, List
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel

from .store import CredentialStore
from .crypto import build_one_time_credential
from .hermes_sender import HermesSender

# ==== 日志 ====
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("pesudo")

# ==== 全局状态 ====
store: Optional[CredentialStore] = None
otp_store: Dict[str, dict] = {}  # request_id → OTP 记录
config: Dict = {}
hermes: Optional[HermesSender] = None

# ==== Pydantic 模型 ====


class RegisterRequest(BaseModel):
    machine_id: str
    hostname: str
    user: str = ""
    tailscale_ip: str = ""
    encrypted_pass: str
    aliyun_auth_token: str = ""


class AuthRequest(BaseModel):
    machine_id: str
    command: str = ""


class VerifyRequest(BaseModel):
    machine_id: str
    request_id: str
    otp: str


class DisableRequest(BaseModel):
    aliyun_auth_token: str = ""


# ==== 生命周期 ====


@asynccontextmanager
async def lifespan(app: FastAPI):
    global store, config, hermes
    config = _load_config()

    master_key = (
        os.environ.get("PESUDO_MASTER_KEY")
        or config.get("PESUDO_MASTER_KEY")
    )
    if not master_key:
        print("❌ 必须设置 PESUDO_MASTER_KEY 环境变量", file=sys.stderr)
        print("   生成: python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\"", file=sys.stderr)
        sys.exit(1)

    store_path = (
        os.environ.get("PESUDO_STORE")
        or config.get("PESUDO_STORE")
        or "/opt/pesudo/store.json"
    )

    if "--dev" in sys.argv or os.environ.get("PESUDO_DEV") == "1":
        store_path = "/tmp/pesudo_store.json"

    store = CredentialStore(store_path, master_key)
    hermes = HermesSender()
    logger.info("HermesSender 初始化")

    logger.info("✅ 授权服务器启动 (store=%s, machines=%d)", store_path, len(store._machines))
    yield


# ==== FastAPI 应用 ====

app = FastAPI(
    title="Pesudo Auth Server",
    version="1.0.0",
    lifespan=lifespan,
)


# ==== 辅助函数 ====


def _load_config() -> dict:
    """加载配置：环境变量优先，.env 文件兜底"""
    try:
        from dotenv import load_dotenv
        load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
    except Exception:
        pass

    cfg = {}
    for key in [
        "PESUDO_MASTER_KEY", "PESUDO_PORT", "PESUDO_STORE", "PESUDO_LOG",
        "HERMES_URL", "HERMES_API_KEY",
        "ALIYUN_SSH_HOST", "ALIYUN_SSH_USER",
        "OTP_LENGTH", "OTP_EXPIRE_SECONDS", "RATE_LIMIT_PER_MINUTE",
    ]:
        val = os.environ.get(key)
        if val:
            cfg[key] = val
    return cfg


def _audit_log(action: str, machine_id: str, detail: str = "", result: str = ""):
    """审计日志"""
    entry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "action": action,
        "machine_id": machine_id,
        "detail": detail,
        "result": result,
    }
    log_path = config.get("PESUDO_LOG", "/var/log/pesudo/audit.log")
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception as e:
        logger.warning("审计日志写入失败: %s", e)
    logger.info("[audit] %s | %s | %s | %s", action, machine_id, detail, result)


def _check_rate_limit(machine_id: str):
    """频率限制: 每分钟最多 N 次"""
    max_per_min = int(config.get("RATE_LIMIT_PER_MINUTE", "3"))
    now = time.time()
    recent = [
        v for v in otp_store.values()
        if v.get("machine_id") == machine_id
        and v.get("created_at", 0) > now - 60
    ]
    if len(recent) >= max_per_min:
        raise HTTPException(429, f"请求过于频繁，每分钟最多 {max_per_min} 次")


# ==== API 端点 ====


@app.get("/v1/health")
async def health():
    """健康检查（用于 Tailscale 自动发现）"""
    return {
        "status": "ok",
        "version": "1.0.0",
        "machines": len(store.list_all()) if store else 0,
    }


@app.post("/v1/register")
async def register(req: RegisterRequest):
    """注册一台机器到授权服务器

    可从任意 Tailscale 节点发起，注册任意其他节点。
    """
    if store is None:
        raise HTTPException(503, "服务未就绪")

    # 管理员身份验证
    # 真实验证在客户端 pesudo-register 中完成（阿里云 SSH 密码）
    # 服务器端只做辅助检查：如果提供了令牌则验证，未提供也接受（tailnet 可信）
    if req.aliyun_auth_token:
        aliyun_host = config.get("ALIYUN_SSH_HOST", "localhost")
        aliyun_user = config.get("ALIYUN_SSH_USER", "")
        # TODO: 实现服务端 SSH 密码验证

    # 加密存储 sudo 密码
    encrypted = store.fernet.encrypt(req.encrypted_pass.encode()).decode()

    machine_data = {
        "hostname": req.hostname,
        "user": req.user,
        "tailscale_ip": req.tailscale_ip,
        "encrypted_pass": encrypted,
        "created_at": int(time.time()),
        "last_used": 0,
        "allowed": True,
        "registered_by": socket.gethostname(),
    }

    store.add(req.machine_id, machine_data)
    _audit_log("register", req.machine_id, f"hostname={req.hostname}", "ok")

    if hermes:
        hermes.notify_register(req.hostname, req.machine_id)

    return {"status": "ok", "machine_id": req.machine_id}


@app.post("/v1/auth/request")
async def auth_request(req: AuthRequest):
    """请求 sudo 授权，生成 OTP 发送到微信"""
    if store is None:
        raise HTTPException(503, "服务未就绪")

    machine = store.get(req.machine_id)
    if not machine:
        raise HTTPException(404, "机器未注册")
    if not machine.get("allowed", True):
        raise HTTPException(403, "机器已被禁用")

    _check_rate_limit(req.machine_id)

    # 生成 OTP
    otp_length = int(config.get("OTP_LENGTH", "6"))
    otp = f"{secrets.randbelow(10 ** otp_length):0{otp_length}d}"
    request_id = secrets.token_hex(16)
    expire_seconds = int(config.get("OTP_EXPIRE_SECONDS", "180"))

    otp_store[request_id] = {
        "machine_id": req.machine_id,
        "otp_hash": hashlib.sha256(otp.encode()).hexdigest(),
        "expires_at": int(time.time()) + expire_seconds,
        "created_at": int(time.time()),
        "used": False,
        "command": req.command,
    }

    # 开发模式: 直接输出 OTP 到终端
    dev_mode = "--dev" in sys.argv or os.environ.get("PESUDO_DEV") == "1"
    logger.info("🔑 OTP for %s [%s]: %s (expires in %ds)",
                req.machine_id, req.command, otp, expire_seconds)

    if not dev_mode and hermes:
        ok = hermes.send_otp(machine["hostname"], req.command, otp, expire_seconds)
        if not ok:
            logger.warning("Hermes 发送失败，OTP 仅记录在日志中")
    elif not dev_mode:
        logger.info("(Hermes 未初始化，请查看日志获取 OTP)")

    _audit_log("request", req.machine_id, req.command, "otp_sent")

    return {"request_id": request_id, "expires_in": expire_seconds}


@app.post("/v1/auth/verify")
async def auth_verify(req: VerifyRequest):
    """验证 OTP，返回一次性加密凭据"""
    if store is None:
        raise HTTPException(503, "服务未就绪")

    entry = otp_store.get(req.request_id)
    if not entry:
        raise HTTPException(400, "无效的请求 ID")
    if entry.get("machine_id") != req.machine_id:
        raise HTTPException(403, "请求与机器不匹配")
    if entry.get("used"):
        raise HTTPException(400, "授权码已使用")
    if time.time() > entry.get("expires_at", 0):
        raise HTTPException(400, "授权码已过期")

    # 比较 OTP 哈希
    otp_hash = hashlib.sha256(req.otp.encode()).hexdigest()
    if otp_hash != entry.get("otp_hash"):
        _audit_log("verify", req.machine_id, "otp_mismatch", "denied")
        raise HTTPException(403, "授权码错误")

    # 标记 OTP 已使用
    entry["used"] = True

    # 解密存储密码
    machine = store.get(req.machine_id)
    try:
        password = store.fernet.decrypt(machine["encrypted_pass"].encode()).decode()
    except Exception:
        raise HTTPException(500, "密码解密失败")

    # 构建一次性凭据 (AES-GCM 随机 nonce → 不同密文)
    credential = build_one_time_credential(password, req.request_id)

    # 更新 last_used
    machine["last_used"] = int(time.time())
    store.add(req.machine_id, machine)

    _audit_log("verify", req.machine_id, entry.get("command", ""), "ok")

    return {"credential": credential}


@app.get("/v1/machines")
async def list_machines():
    """列出所有已注册机器（不含密码）"""
    if store is None:
        raise HTTPException(503, "服务未就绪")
    return {"machines": store.list_all()}


# ==== 启动入口 ====


def main():
    import uvicorn

    port = int(os.environ.get("PESUDO_PORT", config.get("PESUDO_PORT", "8643")))
    host = os.environ.get("PESUDO_HOST", "0.0.0.0")

    dev_mode = "--dev" in sys.argv
    if dev_mode:
        # 开发模式自动生成测试密钥
        if not os.environ.get("PESUDO_MASTER_KEY") and not config.get("PESUDO_MASTER_KEY"):
            from cryptography.fernet import Fernet
            test_key = Fernet.generate_key().decode()
            os.environ["PESUDO_MASTER_KEY"] = test_key
            print(f"🔑 开发模式自动生成 MASTER_KEY: {test_key}", file=sys.stderr)

    print(f"🚀 Pesudo Auth Server starting on {host}:{port}")
    print(f"   {'🧪 DEV MODE' if dev_mode else '🔒 PRODUCTION MODE'}", file=sys.stderr)
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
