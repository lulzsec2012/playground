"""Pesudo — pytest 测试配置"""

import os
import sys
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from cryptography.fernet import Fernet


def pytest_configure():
    os.environ.setdefault("PESUDO_MASTER_KEY", Fernet.generate_key().decode())
    os.environ.setdefault("PESUDO_STORE", "/tmp/pesudo_test_store.json")


@pytest.fixture(autouse=True)
def _reset_test_state():
    os.environ["PESUDO_MASTER_KEY"] = Fernet.generate_key().decode()
    os.environ["PESUDO_STORE"] = "/tmp/pesudo_test_store.json"
    for p in ["/tmp/pesudo_test_store.json"]:
        if os.path.exists(p):
            os.remove(p)
    yield
    import server.server as srv
    srv.otp_store.clear()
    for p in ["/tmp/pesudo_test_store.json"]:
        if os.path.exists(p):
            os.remove(p)


from server.server import app


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture
def registered_machine(client):
    machine_id = "test-box-1"
    resp = client.post("/v1/register", json={
        "machine_id": machine_id,
        "hostname": "test-box-1",
        "user": "tester",
        "tailscale_ip": "100.66.77.88",
        "encrypted_pass": "test-sudo-password-123",
        "aliyun_auth_token": "dev-test-token",
    })
    assert resp.status_code == 200, f"register failed: {resp.json()}"
    return machine_id
