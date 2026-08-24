"""/health 深度探针：默认结构不变，?deep=1 返回 DB 可读写与磁盘余量。"""
from __future__ import annotations


def test_health_default_structure(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    # 老客户端依赖的字段必须原样保留
    assert "service" in body and "version" in body and "serverTimeMs" in body
    # 默认不带 deep 探针（轻量）
    assert "deep" not in body


def test_health_deep_probe(client):
    r = client.get("/health?deep=1")
    assert r.status_code == 200
    body = r.json()
    assert "deep" in body
    deep = body["deep"]
    assert deep["db"]["readable"] is True
    assert deep["db"]["writable"] is True
    assert deep["db"]["integrity"] == "ok"
    assert deep["disk"]["path"]
    assert deep["disk"]["totalBytes"] > 0
    assert deep["disk"]["freeBytes"] > 0
    assert 0 < deep["disk"]["freePercent"] <= 100
    # 默认字段仍保留
    assert body["ok"] is True
