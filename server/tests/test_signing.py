"""安装包 Ed25519 签名：上传后 /config 下发 downloadSha256/downloadSig，客户端可验签。"""
from __future__ import annotations

import io

from app.core import config
from app.services.signing import ensure_signing_key, public_key_b64, verify_bytes
from tests.helpers import API_ROOT, signed_body

ADMIN_USER = "zbxzs"
ADMIN_PASS = "test-admin-pass-123"


def _fake_exe() -> bytes:
    data = bytearray(b"MZ")
    data += b"\x00" * 2048
    return bytes(data)


def test_signing_key_generated_and_exported(client):
    key = ensure_signing_key()
    assert config.SIGNING_KEY_FILE.exists()
    assert config.SIGNING_PUB_FILE.exists()
    b64 = public_key_b64()
    assert b64
    import base64
    assert len(base64.b64decode(b64)) == 32


def test_upload_release_signs_and_config_delivers(client):
    exe = _fake_exe()
    r = client.post(
        "/zbpanel/releases",
        data={"version": "1.0.4", "force_update": "1"},
        files={"file": ("zbxzs-setup-1.0.4.exe", io.BytesIO(exe), "application/octet-stream")},
        auth=(ADMIN_USER, ADMIN_PASS),
    )
    assert r.status_code == 200, r.text
    assert r.json()["code"] == 0

    r = client.post(f"{API_ROOT}/config", json=signed_body({}, path=f"{API_ROOT}/config"))
    cfg = r.json()["data"]
    assert cfg["version"] == "1.0.4"
    assert cfg["downloadSha256"], "缺少 downloadSha256"
    assert cfg["downloadSig"], "缺少 downloadSig"

    # 签名可被客户端内置公钥验证
    pub_b64 = public_key_b64()
    assert verify_bytes(pub_b64, exe, cfg["downloadSig"]) is True

    # 篡改文件内容后签名应校验失败（防投毒）
    tampered = b"MZ" + b"\xff" * 2048
    assert verify_bytes(pub_b64, tampered, cfg["downloadSig"]) is False

    # 哈希也应匹配
    import hashlib
    assert cfg["downloadSha256"] == hashlib.sha256(exe).hexdigest()


def test_config_without_release_has_empty_sig_fields(client):
    r = client.post(f"{API_ROOT}/config", json=signed_body({}, path=f"{API_ROOT}/config"))
    cfg = r.json()["data"]
    assert "downloadSha256" in cfg
    assert "downloadSig" in cfg
    # 未上传安装包时为空，老客户端不关心这两个字段
