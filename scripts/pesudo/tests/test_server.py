"""Pesudo — 服务器 API 测试 (Phase 1 & 2)"""

import time
import hashlib
import pytest
from fastapi.testclient import TestClient


class TestHealth:
    """Phase 1: /v1/health"""

    def test_health_returns_ok(self, client):
        resp = client.get("/v1/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["version"] == "1.0.0"

    def test_health_reports_machine_count(self, client, registered_machine):
        resp = client.get("/v1/health")
        assert resp.json()["machines"] >= 1


class TestRegister:
    """Phase 2: /v1/register"""

    def test_register_success(self, client):
        resp = client.post("/v1/register", json={
            "machine_id": "box-alpha",
            "hostname": "box-alpha.tailnet",
            "user": "admin",
            "tailscale_ip": "100.1.2.3",
            "encrypted_pass": "my-sudo-pass",
            "aliyun_auth_token": "test-token",
        })
        assert resp.status_code == 200
        assert resp.json()["machine_id"] == "box-alpha"

    def test_register_duplicate_overwrites(self, client, registered_machine):
        """重复注册同一 machine_id 应覆盖"""
        resp = client.post("/v1/register", json={
            "machine_id": registered_machine,
            "hostname": "test-box-updated",
            "encrypted_pass": "new-password",
            "aliyun_auth_token": "test-token",
        })
        assert resp.status_code == 200

    def test_list_machines(self, client, registered_machine):
        resp = client.get("/v1/machines")
        assert resp.status_code == 200
        machines = resp.json()["machines"]
        assert any(m["machine_id"] == registered_machine for m in machines)


class TestAuthRequest:
    """Phase 2: /v1/auth/request"""

    def test_request_success(self, client, registered_machine):
        resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "request_id" in data
        assert data["expires_in"] == 180

    def test_request_unregistered_machine(self, client):
        resp = client.post("/v1/auth/request", json={
            "machine_id": "non-existent",
            "command": "whoami",
        })
        assert resp.status_code == 404
        assert "未注册" in resp.json()["detail"]

    def test_request_disabled_machine(self, client, registered_machine):
        # 禁用机器
        from server.server import store
        store.disable(registered_machine)

        resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        assert resp.status_code == 403
        assert "禁用" in resp.json()["detail"]

    def test_rate_limit(self, client, registered_machine):
        # 设置低频率限制
        import server.server as srv
        srv.config["RATE_LIMIT_PER_MINUTE"] = "2"

        # 前 2 次应成功
        assert client.post("/v1/auth/request", json={
            "machine_id": registered_machine, "command": "cmd1",
        }).status_code == 200

        assert client.post("/v1/auth/request", json={
            "machine_id": registered_machine, "command": "cmd2",
        }).status_code == 200

        # 第 3 次应被限
        resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine, "command": "cmd3",
        })
        assert resp.status_code == 429


class TestAuthVerify:
    """Phase 2: /v1/auth/verify"""

    def _get_otp_from_log(self, request_id):
        """从 otp_store 获取 OTP（仅测试用）"""
        from server.server import otp_store
        entry = otp_store.get(request_id)
        if not entry:
            return None
        # 测试模式: 暴力枚举 000000-999999 匹配哈希
        otp_hash = entry["otp_hash"]
        for i in range(1000000):
            if hashlib.sha256(f"{i:06d}".encode()).hexdigest() == otp_hash:
                return f"{i:06d}"
        return None

    def test_verify_success(self, client, registered_machine):
        # 先请求
        req_resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        request_id = req_resp.json()["request_id"]

        # 破解 OTP 用于测试
        otp = self._get_otp_from_log(request_id)
        assert otp is not None, "OTP 不在存储中"

        # 验证
        resp = client.post("/v1/auth/verify", json={
            "machine_id": registered_machine,
            "request_id": request_id,
            "otp": otp,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "credential" in data
        assert "ciphertext" in data["credential"]
        assert "session_key" in data["credential"]
        assert "expires_at" in data["credential"]

    def test_verify_wrong_otp(self, client, registered_machine):
        req_resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        request_id = req_resp.json()["request_id"]

        resp = client.post("/v1/auth/verify", json={
            "machine_id": registered_machine,
            "request_id": request_id,
            "otp": "000000",
        })
        assert resp.status_code == 403

    def test_verify_reused_otp(self, client, registered_machine):
        """同一 OTP 不能使用两次"""
        req_resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        request_id = req_resp.json()["request_id"]
        otp = self._get_otp_from_log(request_id)

        # 第一次验证 — 成功
        assert client.post("/v1/auth/verify", json={
            "machine_id": registered_machine,
            "request_id": request_id,
            "otp": otp,
        }).status_code == 200

        # 第二次验证 — 拒绝
        resp = client.post("/v1/auth/verify", json={
            "machine_id": registered_machine,
            "request_id": request_id,
            "otp": otp,
        })
        assert resp.status_code == 400
        assert "已使用" in resp.json()["detail"]

    def test_verify_expired_otp(self, client, registered_machine):
        """过期 OTP 应被拒绝"""
        req_resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        request_id = req_resp.json()["request_id"]

        # 篡改过期时间
        from server.server import otp_store
        otp_store[request_id]["expires_at"] = int(time.time()) - 1

        otp = self._get_otp_from_log(request_id)
        resp = client.post("/v1/auth/verify", json={
            "machine_id": registered_machine,
            "request_id": request_id,
            "otp": otp,
        })
        assert resp.status_code == 400
        assert "过期" in resp.json()["detail"]

    def test_verify_invalid_request_id(self, client, registered_machine):
        resp = client.post("/v1/auth/verify", json={
            "machine_id": registered_machine,
            "request_id": "non-existent",
            "otp": "123456",
        })
        assert resp.status_code == 400

    def test_verify_machine_mismatch(self, client, registered_machine):
        """request_id 与 machine_id 不匹配"""
        req_resp = client.post("/v1/auth/request", json={
            "machine_id": registered_machine,
            "command": "whoami",
        })
        request_id = req_resp.json()["request_id"]

        resp = client.post("/v1/auth/verify", json={
            "machine_id": "wrong-machine",
            "request_id": request_id,
            "otp": "123456",
        })
        assert resp.status_code == 403
