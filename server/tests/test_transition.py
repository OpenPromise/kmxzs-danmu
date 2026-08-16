"""阶段0：HTTP 过渡入口白名单（明文 HTTP 仅放行 /config、/files/*、/health）。"""
from __future__ import annotations

import app.core.config as cfg
from tests.helpers import API_ROOT, signed_body


def test_http_transition_whitelist(client):
    old = cfg.HTTP_TRANSITION
    cfg.HTTP_TRANSITION = True
    try:
        # 白名单放行
        r = client.get("/health")
        assert r.status_code == 200

        r = client.post(f"{API_ROOT}/config", json=signed_body({}, path=f"{API_ROOT}/config"))
        assert r.status_code == 200
        assert r.json()["code"] == 0

        # 其余接口在明文 HTTP 上拒绝（推动老客户端升级 HTTPS）
        r = client.post(f"{API_ROOT}/login", json={"card": "KMXZS-DEMO-30D"})
        assert r.status_code == 403
        assert r.json()["code"] == 403

        r = client.get("/zbpanel/")
        assert r.status_code == 403

        r = client.post("/api/auth/login", json={"username": "superadmin", "password": "x"})
        assert r.status_code == 403
    finally:
        cfg.HTTP_TRANSITION = old


def test_http_transition_disabled_by_default(client):
    assert cfg.HTTP_TRANSITION is False
    r = client.post(f"{API_ROOT}/login", json={"card": "KMXZS-DEMO-30D"})
    # 未开启过渡保护时，登录缺失签名返回 401（而不是 403 过渡拒绝）
    assert r.status_code == 401
