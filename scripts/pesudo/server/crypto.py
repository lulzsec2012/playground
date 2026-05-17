"""Pesudo — 动态凭据加密

实现一次性凭据协议:
- 每次调用 build_one_time_credential() 生成不同的密文
- 使用 AES-GCM 随机 nonce + 随机 session_key
- AAD 绑定 request_id，防止重放

TODO: Phase 3 完整实现
"""

import secrets
import json
import time
import binascii
from typing import Dict
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def build_one_time_credential(
    password: str,
    request_id: str,
    ttl: int = 30
) -> dict:
    """生成一次性加密凭据

    每次调用产生不同的密文:
    - session_key: 随机 32 字节 AES-256 密钥
    - nonce: 随机 12 字节
    - AAD: "pesudo:v1:{request_id}"

    返回:
        ciphertext: nonce + ciphertext 的 hex 编码
        session_key: 一次性密钥 hex
        expires_at: 过期时间戳
    """
    session_key = AESGCM.generate_key(bit_length=256)
    aesgcm = AESGCM(session_key)
    nonce = secrets.token_bytes(12)

    payload = {
        "password": password,
        "request_id": request_id,
        "expires_at": int(time.time()) + ttl
    }

    aad = f"pesudo:v1:{request_id}".encode()
    ciphertext = aesgcm.encrypt(nonce, json.dumps(payload).encode(), aad)

    return {
        "ciphertext": (nonce + ciphertext).hex(),
        "session_key": session_key.hex(),
        "expires_at": int(time.time()) + ttl
    }


def decrypt_credential(
    ciphertext_hex: str,
    session_key_hex: str,
    request_id: str
) -> str:
    """解密凭据，返回密码明文

    验证:
    - 密文完整性 (AES-GCM 认证标签)
    - request_id 匹配
    - 未过期
    """
    import binascii
    data = binascii.unhexlify(ciphertext_hex)
    key = binascii.unhexlify(session_key_hex)
    nonce, ct = data[:12], data[12:]

    aesgcm = AESGCM(key)
    aad = f"pesudo:v1:{request_id}".encode()
    plaintext = aesgcm.decrypt(nonce, ct, aad)

    payload = json.loads(plaintext)

    if int(time.time()) > payload["expires_at"]:
        raise ValueError("凭据已过期")
    if payload["request_id"] != request_id:
        raise ValueError("request_id 不匹配")

    return str(payload["password"])
