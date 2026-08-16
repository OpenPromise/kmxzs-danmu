"""阶段1：JWT 认证、RBAC、渠道/代理、配额与数据隔离。"""
from __future__ import annotations

from tests.helpers import API_ROOT, signed_body

SUPERADMIN = "superadmin"
SUPERADMIN_PASS = "test-superadmin-pass-123"
AGENT_PASS = "agent-pass-123"


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _admin_token(client) -> str:
    r = client.post("/api/auth/login", json={"username": SUPERADMIN, "password": SUPERADMIN_PASS})
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0
    return r.json()["data"]["access_token"]


def _create_channel(client, adm: str, code: str, name: str) -> int:
    r = client.post("/api/admin/channels", json={"code": code, "name": name}, headers=_auth(adm))
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0
    return int(r.json()["data"]["id"])


def _create_agent(client, adm: str, username: str, channel_id: int, quota: int) -> None:
    r = client.post(
        "/api/admin/users",
        json={"username": username, "password": AGENT_PASS, "channel_id": channel_id, "card_quota": quota},
        headers=_auth(adm),
    )
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0


def _agent_token(client, username: str) -> str:
    r = client.post("/api/auth/login", json={"username": username, "password": AGENT_PASS})
    assert r.status_code == 200, r.text
    return r.json()["data"]["access_token"]


def test_superadmin_login_and_bootstrap(client):
    # 未登录访问受保护接口 → 401
    r = client.get("/api/admin/users")
    assert r.status_code == 401
    r = client.get("/api/reseller/overview")
    assert r.status_code == 401

    adm = _admin_token(client)
    r = client.get("/api/auth/me", headers=_auth(adm))
    assert r.status_code == 200
    me = r.json()["data"]
    assert me["role"] == "superadmin"
    assert me["username"] == SUPERADMIN


def test_channel_and_agent_crud(client):
    adm = _admin_token(client)

    r = client.post("/api/admin/channels", json={"code": "", "name": ""}, headers=_auth(adm))
    assert r.status_code == 400
    assert r.json()["detail"]["code"] == 400

    ch_id = _create_channel(client, adm, "CH-1", "渠道一")
    r = client.patch(f"/api/admin/channels/{ch_id}", json={"name": "渠道一改名"}, headers=_auth(adm))
    assert r.json()["code"] == 0
    assert r.json()["data"]["name"] == "渠道一改名"

    r = client.get("/api/admin/channels", headers=_auth(adm))
    assert len(r.json()["data"]) == 1

    # 密码过短拒绝
    r = client.post(
        "/api/admin/users",
        json={"username": "bad", "password": "short", "channel_id": ch_id, "card_quota": 10},
        headers=_auth(adm),
    )
    assert r.status_code == 400
    assert r.json()["detail"]["code"] == 400

    _create_agent(client, adm, "agent1", ch_id, quota=5)
    r = client.patch("/api/admin/users/2", json={"card_quota": 8}, headers=_auth(adm))
    assert r.json()["code"] == 0
    assert r.json()["data"]["card_quota"] == 8

    r = client.get("/api/admin/users", headers=_auth(adm))
    users = r.json()["data"]
    assert any(u["username"] == "agent1" and u["quota_used"] == 0 for u in users)


def test_reseller_quota_limit(client):
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "CH-Q", "配额渠道")
    _create_agent(client, adm, "qagent", ch_id, quota=3)
    ag = _agent_token(client, "qagent")

    r = client.post("/api/reseller/cards", json={"kind": "login", "hours": 720, "count": 3}, headers=_auth(ag))
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0
    assert r.json()["data"]["quota_used"] == 3

    r = client.post("/api/reseller/cards", json={"kind": "login", "hours": 720, "count": 1}, headers=_auth(ag))
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == 403


def test_reseller_data_isolation(client):
    adm = _admin_token(client)
    ch_a = _create_channel(client, adm, "CH-A", "代理A")
    ch_b = _create_channel(client, adm, "CH-B", "代理B")
    _create_agent(client, adm, "agent-a", ch_a, quota=10)
    _create_agent(client, adm, "agent-b", ch_b, quota=10)
    ag_a = _agent_token(client, "agent-a")
    ag_b = _agent_token(client, "agent-b")

    r = client.post("/api/reseller/cards", json={"kind": "login", "hours": 720, "count": 2}, headers=_auth(ag_a))
    assert r.json()["code"] == 0
    cards_a = r.json()["data"]["cards"]

    # B 看不到 A 的卡
    r = client.get("/api/reseller/cards", headers=_auth(ag_b))
    assert r.status_code == 200
    codes_b = {c["code"] for c in r.json()["data"]}
    assert codes_b.isdisjoint(cards_a)

    # B 不能删除 / 修改 A 的卡
    r = client.delete(f"/api/reseller/cards/{cards_a[0]}", headers=_auth(ag_b))
    assert r.json()["code"] == 404
    r = client.patch(f"/api/reseller/cards/{cards_a[0]}", json={"note": "hack"}, headers=_auth(ag_b))
    assert r.json()["code"] == 404

    # A 可以删除自己的卡
    r = client.delete(f"/api/reseller/cards/{cards_a[0]}", headers=_auth(ag_a))
    assert r.json()["code"] == 0

    # B 的 overview 不含 A 数据
    r = client.get("/api/reseller/overview", headers=_auth(ag_b))
    ov = r.json()["data"]
    assert ov["cardsTotal"] == 0


def test_reseller_cannot_use_admin_api(client):
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "CH-R", "渠道R")
    _create_agent(client, adm, "ragent", ch_id, quota=10)
    ag = _agent_token(client, "ragent")

    for method, url in [
        ("get", "/api/admin/users"),
        ("post", "/api/admin/channels"),
        ("get", "/api/admin/channels"),
    ]:
        r = getattr(client, method)(url, headers=_auth(ag))
        assert r.status_code == 403


def test_channel_disable_blocks_reseller(client):
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "CH-D", "渠道D")
    _create_agent(client, adm, "dagent", ch_id, quota=10)
    ag = _agent_token(client, "dagent")

    r = client.get("/api/reseller/overview", headers=_auth(ag))
    assert r.status_code == 200

    r = client.patch(f"/api/admin/channels/{ch_id}", json={"status": 0}, headers=_auth(adm))
    assert r.json()["code"] == 0

    r = client.get("/api/reseller/overview", headers=_auth(ag))
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == 403


def test_refresh_token_rotation(client):
    r = client.post("/api/auth/login", json={"username": SUPERADMIN, "password": SUPERADMIN_PASS})
    refresh = r.json()["data"]["refresh_token"]
    old_access = r.json()["data"]["access_token"]

    r = client.post("/api/auth/refresh", json={"refresh_token": refresh})
    assert r.status_code == 200, r.text
    data = r.json()["data"]
    assert data["access_token"] != old_access
    new_refresh = data["refresh_token"]

    # 旧 refresh token 已轮换失效
    r = client.post("/api/auth/refresh", json={"refresh_token": refresh})
    assert r.status_code == 401

    # 新 refresh 可用
    r = client.post("/api/auth/refresh", json={"refresh_token": new_refresh})
    assert r.status_code == 200

    # 登出后失效
    r = client.post("/api/auth/logout", json={"refresh_token": new_refresh})
    assert r.status_code == 200


def test_reseller_device_unbind_isolated(client):
    adm = _admin_token(client)
    ch_a = _create_channel(client, adm, "CH-UA", "解绑A")
    ch_b = _create_channel(client, adm, "CH-UB", "解绑B")
    _create_agent(client, adm, "agent-ua", ch_a, quota=5)
    _create_agent(client, adm, "agent-ub", ch_b, quota=5)
    ag_a = _agent_token(client, "agent-ua")
    ag_b = _agent_token(client, "agent-ub")

    r = client.post("/api/reseller/cards", json={"kind": "login", "hours": 720, "max_devices": 2, "count": 1}, headers=_auth(ag_a))
    code = r.json()["data"]["cards"][0]
    r = client.post(f"{API_ROOT}/login", json=signed_body({"card": code}, path=f"{API_ROOT}/login", device_id="dev-x"))
    assert r.json()["code"] == 0

    r = client.get("/api/reseller/devices", headers=_auth(ag_a))
    devs = r.json()["data"]
    assert len(devs) == 1
    did = devs[0]["id"]

    # B 不能解绑 A 的设备
    r = client.delete(f"/api/reseller/devices/{did}", headers=_auth(ag_b))
    assert r.json()["code"] == 404

    # A 可以解绑自己的设备
    r = client.delete(f"/api/reseller/devices/{did}", headers=_auth(ag_a))
    assert r.json()["code"] == 0
    r = client.get("/api/reseller/devices", headers=_auth(ag_a))
    assert r.json()["data"] == []


def test_reseller_client_card_login_with_channel_card(client):
    """代理发的卡，终端客户端可正常登录（验证 channel_id 卡片走通客户端流程）。"""
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "CH-L", "发卡渠道")
    _create_agent(client, adm, "lagent", ch_id, quota=2)
    ag = _agent_token(client, "lagent")
    r = client.post("/api/reseller/cards", json={"kind": "login", "hours": 720, "count": 1}, headers=_auth(ag))
    code = r.json()["data"]["cards"][0]

    r = client.post(f"{API_ROOT}/login", json=signed_body({"card": code}, path=f"{API_ROOT}/login"))
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0
