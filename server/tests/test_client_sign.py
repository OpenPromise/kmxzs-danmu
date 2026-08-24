"""客户端 HMAC 签名校验与 nonce 防重放。"""
from __future__ import annotations

import time

from tests.helpers import API_ROOT, signed_body


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_config_with_valid_sign(client):
    r = client.post(f"{API_ROOT}/config", json=signed_body({}, path=f"{API_ROOT}/config"))
    assert r.status_code == 200
    body = r.json()
    assert body["code"] == 0
    assert body["data"]["version"] == "1.0.0"
    assert body["data"]["minVersion"] == "1.0.0"


def test_config_missing_sign(client):
    r = client.post(f"{API_ROOT}/config", json={})
    assert r.status_code == 401
    assert r.json()["detail"]["code"] == 401


def test_config_wrong_sign(client):
    body = signed_body({}, path=f"{API_ROOT}/config")
    body["sign"] = "0" * 64
    r = client.post(f"{API_ROOT}/config", json=body)
    assert r.status_code == 401
    assert r.json()["detail"]["code"] == 401


def test_config_expired_timestamp(client):
    old = int(time.time() * 1000) - 3600_000  # 1 小时前，超出 5 分钟窗口
    body = signed_body({}, path=f"{API_ROOT}/config", timestamp=old)
    r = client.post(f"{API_ROOT}/config", json=body)
    assert r.status_code == 401
    assert r.json()["detail"]["code"] == 401


def test_config_nonce_replay(client):
    body = signed_body({}, path=f"{API_ROOT}/config")
    r1 = client.post(f"{API_ROOT}/config", json=body)
    assert r1.status_code == 200
    r2 = client.post(f"{API_ROOT}/config", json=body)
    assert r2.status_code == 401
    assert r2.json()["detail"]["code"] == 401
