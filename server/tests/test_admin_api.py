"""阶段2：管理 SPA 用的超管全量接口（JWT 版 /api/admin/*）。"""
from __future__ import annotations

import io

from tests.helpers import API_ROOT, signed_body

SUPERADMIN = "superadmin"
SUPERADMIN_PASS = "test-superadmin-pass-123"
AGENT_PASS = "agent-pass-123"


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _admin_token(client) -> str:
    r = client.post("/api/auth/login", json={"username": SUPERADMIN, "password": SUPERADMIN_PASS})
    assert r.status_code == 200, r.text
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


def _agent_token(client, username: str) -> str:
    r = client.post("/api/auth/login", json={"username": username, "password": AGENT_PASS})
    assert r.status_code == 200, r.text
    return r.json()["data"]["access_token"]


def test_admin_overview(client):
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "OV-CH", "总览渠道")
    r = client.get("/api/admin/overview", headers=_auth(adm))
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["cardsTotal"] >= 4
    assert body["cardsLoginEnabled"] >= 1
    assert isinstance(body["channels"], list)
    assert any(c["id"] == ch_id for c in body["channels"])
    assert isinstance(body["noteChannels"], list)


def test_admin_cards_crud_and_pagination(client):
    adm = _admin_token(client)
    r = client.post(
        "/api/admin/cards",
        json={"kind": "login", "hours": 720, "count": 3, "note": "超管发卡"},
        headers=_auth(adm),
    )
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0
    codes = r.json()["data"]["cards"]
    assert len(codes) == 3

    # 分页列表 + 关键字过滤
    r = client.get("/api/admin/cards?q=超管发卡&page=1&page_size=2", headers=_auth(adm))
    body = r.json()["data"]
    assert body["total"] >= 3
    assert len(body["items"]) == 2
    assert body["items"][0]["note"] == "超管发卡"

    # 停用其中一张
    r = client.patch(f"/api/admin/cards/{codes[0]}", json={"enabled": False}, headers=_auth(adm))
    assert r.json()["code"] == 0
    assert r.json()["data"]["enabled"] == 0

    # 按 enabled 过滤
    r = client.get(f"/api/admin/cards?enabled=0&q={codes[0]}", headers=_auth(adm))
    items = r.json()["data"]["items"]
    assert any(i["code"] == codes[0] for i in items)

    # 删除
    r = client.delete(f"/api/admin/cards/{codes[0]}", headers=_auth(adm))
    assert r.json()["code"] == 0
    r = client.delete(f"/api/admin/cards/{codes[0]}", headers=_auth(adm))
    assert r.json()["code"] == 404


def test_admin_create_cards_with_channel(client):
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "CH-CARD", "发卡渠道")
    r = client.post(
        "/api/admin/cards",
        json={"kind": "login", "hours": 720, "count": 2, "channel_id": ch_id},
        headers=_auth(adm),
    )
    assert r.json()["code"] == 0
    codes = r.json()["data"]["cards"]
    r = client.get("/api/admin/cards?channel_id={}&page_size=10".format(ch_id), headers=_auth(adm))
    items = r.json()["data"]["items"]
    assert any(i["code"] in codes and i["channel_name"] == "发卡渠道" for i in items)

    # 指定不存在的渠道
    r = client.post(
        "/api/admin/cards",
        json={"kind": "login", "hours": 720, "count": 1, "channel_id": 99999},
        headers=_auth(adm),
    )
    assert r.status_code == 200
    assert r.json()["code"] == 400


def test_admin_cards_export(client):
    adm = _admin_token(client)
    r = client.post("/api/admin/cards", json={"kind": "login", "hours": 24, "count": 1}, headers=_auth(adm))
    code = r.json()["data"]["cards"][0]
    r = client.get("/api/admin/cards/export", headers=_auth(adm))
    assert r.status_code == 200
    assert r.headers.get("content-type", "").startswith("text/csv")
    assert code in r.text


def test_admin_accounts_extend(client):
    adm = _admin_token(client)
    r = client.post("/api/admin/cards", json={"kind": "login", "hours": 24, "count": 1}, headers=_auth(adm))
    code = r.json()["data"]["cards"][0]
    # 终端登录一次以创建账号
    r = client.post(f"{API_ROOT}/login", json=signed_body({"card": code}, path=f"{API_ROOT}/login"))
    assert r.json()["code"] == 0

    r = client.get("/api/admin/accounts?page_size=10", headers=_auth(adm))
    items = r.json()["data"]["items"]
    assert any(i["card"] == code for i in items)

    r = client.post(f"/api/admin/accounts/{code}/extend", json={"hours": 48}, headers=_auth(adm))
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0
    assert r.json()["data"]["card"] == code


def test_admin_devices_unbind(client):
    adm = _admin_token(client)
    r = client.post("/api/admin/cards", json={"kind": "login", "hours": 720, "max_devices": 2, "count": 1}, headers=_auth(adm))
    code = r.json()["data"]["cards"][0]
    # 两个设备登录
    for dev in ("dev-a", "dev-b"):
        r = client.post(
            f"{API_ROOT}/login",
            json=signed_body({"card": code}, path=f"{API_ROOT}/login", device_id=dev),
        )
        assert r.json()["code"] == 0, r.text

    r = client.get("/api/admin/devices?page_size=10", headers=_auth(adm))
    items = r.json()["data"]["items"]
    target = next(i for i in items if i["card"] == code)
    r = client.delete(f"/api/admin/devices/{target['id']}", headers=_auth(adm))
    assert r.json()["code"] == 0

    r = client.get("/api/admin/devices?page_size=10", headers=_auth(adm))
    items = r.json()["data"]["items"]
    assert not any(i["id"] == target["id"] for i in items)


def test_admin_logs_pagination(client):
    adm = _admin_token(client)
    client.post("/api/admin/cards", json={"kind": "topup", "hours": 24, "count": 1}, headers=_auth(adm))
    r = client.get("/api/admin/logs?page=1&page_size=5&action=admin_create_cards", headers=_auth(adm))
    body = r.json()["data"]
    assert body["total"] >= 1
    assert len(body["items"]) == 1
    assert body["items"][0]["action"] == "admin_create_cards"
    assert body["items"][0]["actor"] == SUPERADMIN


def test_admin_settings_roundtrip(client):
    adm = _admin_token(client)
    r = client.get("/api/admin/settings", headers=_auth(adm))
    assert r.status_code == 200, r.text
    assert r.json()["data"]["public"]["notice"]

    r = client.put(
        "/api/admin/settings",
        json={"notice": "欢迎使用直播小助手-测试", "force_update": True, "min_client_version": "1.0.1"},
        headers=_auth(adm),
    )
    assert r.json()["code"] == 0
    pub = r.json()["data"]
    assert pub["notice"] == "欢迎使用直播小助手-测试"
    assert pub["force"] is True
    assert pub["minVersion"] == "1.0.1"


def test_admin_releases_upload_list(client):
    adm = _admin_token(client)
    exe = bytearray(b"MZ") + b"\x00" * 2048
    files = {"file": ("setup.exe", io.BytesIO(bytes(exe)), "application/octet-stream")}
    r = client.post(
        "/api/admin/releases",
        data={"version": "1.2.0", "force_update": "1"},
        files=files,
        headers=_auth(adm),
    )
    assert r.status_code == 200, r.text
    assert r.json()["data"]["version"] == "1.2.0"

    r = client.get("/api/admin/releases", headers=_auth(adm))
    assert r.json()["code"] == 0
    assert any(f["name"] == "zbxzs-setup-1.2.0.exe" for f in r.json()["data"]["files"])


def test_admin_api_rejects_reseller(client):
    adm = _admin_token(client)
    ch_id = _create_channel(client, adm, "RB-CH", "拒绝渠道")
    _create_agent(client, adm, "rbagent", ch_id, quota=10)
    ag = _agent_token(client, "rbagent")

    for method, url in [
        ("get", "/api/admin/overview"),
        ("get", "/api/admin/cards"),
        ("post", "/api/admin/cards"),
        ("get", "/api/admin/accounts"),
        ("get", "/api/admin/devices"),
        ("get", "/api/admin/logs"),
        ("get", "/api/admin/settings"),
        ("get", "/api/admin/releases"),
    ]:
        r = getattr(client, method)(url, headers=_auth(ag))
        assert r.status_code == 403, f"{method.upper()} {url} -> {r.status_code}"
