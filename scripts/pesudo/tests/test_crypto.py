"""Pesudo — 动态凭据加密测试 (Phase 3)"""

import pytest
from server.crypto import build_one_time_credential, decrypt_credential


class TestOneTimeCredential:

    def test_build_and_decrypt(self):
        """基本加解密流程"""
        cred = build_one_time_credential("my-password", "req-001")
        password = decrypt_credential(
            cred["ciphertext"],
            cred["session_key"],
            "req-001"
        )
        assert password == "my-password"

    def test_each_call_different(self):
        """相同密码和 request_id 每次调用生成不同密文"""
        cred1 = build_one_time_credential("same-pass", "req-001")
        cred2 = build_one_time_credential("same-pass", "req-001")

        # 密文不同（random nonce + session_key）
        assert cred1["ciphertext"] != cred2["ciphertext"]
        # session_key 不同
        assert cred1["session_key"] != cred2["session_key"]

    def test_wrong_request_id(self):
        """AAD 绑定: 错误的 request_id 解密失败"""
        cred = build_one_time_credential("my-pass", "req-001")
        with pytest.raises(Exception):
            decrypt_credential(
                cred["ciphertext"],
                cred["session_key"],
                "req-002"
            )

    def test_tampered_ciphertext(self):
        """篡改密文: AES-GCM 认证标签验证失败"""
        cred = build_one_time_credential("my-pass", "req-001")
        tampered = list(cred["ciphertext"])
        tampered[10] = "f" if tampered[10] == "0" else "0"
        tampered_hex = "".join(tampered)

        with pytest.raises(Exception):
            decrypt_credential(
                tampered_hex,
                cred["session_key"],
                "req-001"
            )

    def test_expired(self):
        """过期凭据拒绝解密"""
        import time as t
        cred = build_one_time_credential("my-pass", "req-001", ttl=-1)
        t.sleep(0.01)  # 确保过期

        with pytest.raises(ValueError, match="过期"):
            decrypt_credential(
                cred["ciphertext"],
                cred["session_key"],
                "req-001"
            )

    def test_different_passwords_same_request(self):
        """同一 request_id 不同密码 → 密文不同"""
        cred1 = build_one_time_credential("pass-A", "req-001")
        cred2 = build_one_time_credential("pass-B", "req-001")
        assert cred1["ciphertext"] != cred2["ciphertext"]
