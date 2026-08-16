"""过渡期旧后台（Basic + admin token + 静态 index.html）保持可用。"""
from __future__ import annotations

ADMIN_USER = "zbxzs"
ADMIN_PASS = "test-admin-pass-123"
AUTH = (ADMIN_USER, ADMIN_PASS)


def test_admin_requires_auth(client):
    r = client.get("/zbpanel/overview")
    assert r.status_code == 401


def test_admin_overview_via_basic(client):
    r = client.get("/zbpanel/overview", auth=AUTH)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["code"] == 0
    assert body["data"]["cardsTotal"] >= 4


def test_admin_index_html(client):
    r = client.get("/zbpanel/", auth=AUTH)
    assert r.status_code == 200
    assert "<html" in r.text.lower()


def test_admin_create_cards_via_basic(client):
    r = client.post(
        "/zbpanel/cards",
        json={"kind": "login", "hours": 720, "count": 2, "note": "测试卡"},
        auth=AUTH,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["code"] == 0
    assert len(body["data"]["cards"]) == 2


def test_admin_logs_via_basic(client):
    r = client.get("/zbpanel/logs", auth=AUTH)
    assert r.status_code == 200
    assert r.json()["code"] == 0
