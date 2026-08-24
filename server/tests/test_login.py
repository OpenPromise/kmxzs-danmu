"""客户端登录、会话与限流。"""
from __future__ import annotations

from tests.helpers import API_ROOT, signed_body


def test_login_success(client):
    r = client.post(
        f"{API_ROOT}/login",
        json=signed_body({"card": "KMXZS-DEMO-30D"}, path=f"{API_ROOT}/login"),
    )
    assert r.status_code == 200
    body = r.json()
    assert body["code"] == 0
    assert body["message"] == "登录成功"
    assert body["data"]["token"]
    assert body["data"]["card"] == "KMXZS-DEMO-30D"
    assert body["data"]["remainingHours"] > 0
    assert body["data"]["deviceId"] == "win-test-pc"


def test_login_me_device_list_flow(client):
    body = signed_body({"card": "KMXZS-DEMO-30D"}, path=f"{API_ROOT}/login")
    r = client.post(f"{API_ROOT}/login", json=body)
    token = r.json()["data"]["token"]
    headers = {"token": token, "Authorization": f"Bearer {token}"}

    r = client.post(
        f"{API_ROOT}/me", json=signed_body({}, path=f"{API_ROOT}/me"), headers=headers
    )
    assert r.status_code == 200
    assert r.json()["data"]["card"] == "KMXZS-DEMO-30D"

    r = client.post(
        f"{API_ROOT}/device/list",
        json=signed_body({}, path=f"{API_ROOT}/device/list"),
        headers=headers,
    )
    assert r.status_code == 200
    devices = r.json()["data"]
    assert any(d["deviceId"] == "win-test-pc" for d in devices)


def test_login_invalid_card(client):
    r = client.post(
        f"{API_ROOT}/login",
        json=signed_body({"card": "NOPE-NOT-EXIST"}, path=f"{API_ROOT}/login"),
    )
    assert r.status_code == 200  # 业务失败以 code 区分，HTTP 仍 200
    assert r.json()["code"] == 401


def test_login_topup_card_rejected(client):
    r = client.post(
        f"{API_ROOT}/login",
        json=signed_body({"card": "KMXZS-TOPUP-24H"}, path=f"{API_ROOT}/login"),
    )
    assert r.status_code == 200
    assert r.json()["code"] == 400


def test_login_rate_limit(client):
    # KMXZS_LOGIN_RATE_LIMIT=5；第 6 次触发 429
    for _ in range(5):
        client.post(f"{API_ROOT}/login", json={"card": "X"})
    r = client.post(f"{API_ROOT}/login", json={"card": "X"})
    assert r.status_code == 429
