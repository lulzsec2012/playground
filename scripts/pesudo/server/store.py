"""Pesudo — 加密凭据库

使用 Fernet (AES-256-GCM) 加密存储所有注册机器的 sudo 密码。
"""

import json
import os
from typing import Optional, List
from cryptography.fernet import Fernet


class CredentialStore:
    """加密的机器凭据库，持久化到 JSON 文件

    存储结构:
    {
        "machine_id": {
            "hostname": "dev-box-2",
            "user": "ubuntu",
            "tailscale_ip": "100.x.x.x",
            "encrypted_pass": "<Fernet 加密的密码>",
            "created_at": 1715760000,
            "last_used": 1715763600,
            "allowed": true,
            "registered_by": "dev-box-1"
        }
    }
    """

    def __init__(self, path: str, master_key: str):
        self.path = path
        self.fernet = Fernet(master_key.encode() if isinstance(master_key, str) else master_key)
        self._machines = self._load()

    def _load(self) -> dict:
        """读取并解密存储文件"""
        if not os.path.exists(self.path):
            return {}
        try:
            with open(self.path) as f:
                encrypted = f.read().strip()
            if not encrypted:
                return {}
            decrypted = self.fernet.decrypt(encrypted.encode())
            return json.loads(decrypted)
        except Exception as e:
            raise RuntimeError(f"凭据库解密失败: {e}")

    def _save(self):
        """加密并写入存储文件"""
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        plain = json.dumps(self._machines, ensure_ascii=False, indent=2)
        encrypted = self.fernet.encrypt(plain.encode()).decode()
        with open(self.path, "w") as f:
            f.write(encrypted)
            f.write("\n")
        os.chmod(self.path, 0o600)

    def add(self, machine_id: str, data: dict):
        """添加或更新机器凭据"""
        self._machines[machine_id] = data
        self._save()

    def get(self, machine_id: str) -> Optional[dict]:
        """获取机器凭据"""
        return self._machines.get(machine_id)

    def disable(self, machine_id: str):
        """禁用机器"""
        if machine_id in self._machines:
            self._machines[machine_id]["allowed"] = False
            self._save()

    def enable(self, machine_id: str):
        """启用机器"""
        if machine_id in self._machines:
            self._machines[machine_id]["allowed"] = True
            self._save()

    def remove(self, machine_id: str):
        """删除机器"""
        self._machines.pop(machine_id, None)
        self._save()

    def list_all(self) -> List[dict]:
        """列出所有机器（不包含密码）"""
        result = []
        for mid, data in self._machines.items():
            result.append({
                "machine_id": mid,
                "hostname": data.get("hostname"),
                "user": data.get("user"),
                "tailscale_ip": data.get("tailscale_ip"),
                "allowed": data.get("allowed", True),
                "created_at": data.get("created_at"),
                "last_used": data.get("last_used"),
            })
        return result

