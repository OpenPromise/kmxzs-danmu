"""安装包上传 / 下载 / 客户端配置联动。"""
from __future__ import annotations

import io

from tests.helpers import API_ROOT, signed_body

ADMIN_USER = "zbxzs"
ADMIN_PASS = "test-admin-pass-123"


def _fake_exe() -> bytes:
    # 最小合法 PE：MZ 头 + 填充到 >1KB
    data = bytearray(b"MZ")
    data += b"\x00" * 2048
    return bytes(data)


def test_upload_release_and_config(client):
    exe = _fake_exe()
    files = {"file": ("zbxzs-setup-1.0.4.exe", io.BytesIO(exe), "application/octet-stream")}
    r = client.post(
        "/zbpanel/releases",
        data={"version": "1.0.4", "force_update": "1"},
        files=files,
        auth=(ADMIN_USER, ADMIN_PASS),
    )
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["code"] == 0
    assert data["data"]["version"] == "1.0.4"
    assert data["data"]["size"] == len(exe)

    # /config 反映新版本与强更标记
    r = client.post(f"{API_ROOT}/config", json=signed_body({}, path=f"{API_ROOT}/config"))
    cfg = r.json()["data"]
    assert cfg["version"] == "1.0.4"
    assert cfg["force"] is True
    assert cfg["downloadSize"] == len(exe)
    assert cfg["download"].endswith("/files/latest.exe?v=1.0.4")

    # 下载 latest.exe 内容一致
    r = client.get("/files/latest.exe")
    assert r.status_code == 200
    assert r.content == exe
    assert r.headers.get("content-disposition", "").find("setup.exe") != -1


def test_upload_rejects_non_exe(client):
    r = client.post(
        "/zbpanel/releases",
        data={"version": "1.0.5"},
        files={"file": ("evil.txt", io.BytesIO(b"hello world"), "text/plain")},
        auth=(ADMIN_USER, ADMIN_PASS),
    )
    assert r.status_code == 400


def test_upload_requires_auth(client):
    exe = _fake_exe()
    r = client.post(
        "/zbpanel/releases",
        data={"version": "1.0.4"},
        files={"file": ("a.exe", io.BytesIO(exe), "application/octet-stream")},
    )
    assert r.status_code in (401, 403)
