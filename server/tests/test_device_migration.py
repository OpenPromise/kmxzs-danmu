"""阶段3：客户端升级指纹后，服务端对同卡旧指纹设备做静默迁移，不踢老用户。"""
from __future__ import annotations

from tests.helpers import API_ROOT, signed_body

LEGACY_DEVICE = "win-old-pc-4"
NEW_DEVICE = "win-abcd1234efgh5678ijkl9012mnop3456"


def _login(client, *, card="KMXZS-DEMO-30D", device_id=LEGACY_DEVICE, legacy=None):
    payload = {"card": card, "deviceId": device_id}
    if legacy is not None:
        payload["legacyDeviceId"] = legacy
    return client.post(
        f"{API_ROOT}/login",
        json=signed_body(payload, path=f"{API_ROOT}/login", device_id=device_id),
    )


def test_login_migrates_legacy_device(client):
    # 第一步：老客户端先用旧指纹绑定
    r = _login(client, device_id=LEGACY_DEVICE)
    assert r.status_code == 200
    assert r.json()["code"] == 0
    token = r.json()["data"]["token"]
    headers = {"token": token, "Authorization": f"Bearer {token}"}

    devices = client.post(
        f"{API_ROOT}/device/list",
        json=signed_body({}, path=f"{API_ROOT}/device/list", device_id=LEGACY_DEVICE),
        headers=headers,
    ).json()["data"]
    assert len(devices) == 1
    assert devices[0]["deviceId"] == LEGACY_DEVICE

    # 第二步：升级后的客户端携带新指纹 + 旧指纹登录，应当静默迁移而不是提示设备上限
    r = _login(client, device_id=NEW_DEVICE, legacy=LEGACY_DEVICE)
    assert r.status_code == 200
    assert r.json()["code"] == 0
    assert r.json()["data"]["deviceId"] == NEW_DEVICE
    token2 = r.json()["data"]["token"]
    headers2 = {"token": token2, "Authorization": f"Bearer {token2}"}

    # 迁移后设备数仍为 1，且已经是新指纹
    devices = client.post(
        f"{API_ROOT}/device/list",
        json=signed_body({}, path=f"{API_ROOT}/device/list", device_id=NEW_DEVICE),
        headers=headers2,
    ).json()["data"]
    assert len(devices) == 1
    assert devices[0]["deviceId"] == NEW_DEVICE


def test_login_without_legacy_still_binds_new_device(client):
    # 全新用户直接使用新指纹登录，不携带旧指纹也正常
    r = _login(client, card="KMXZS-DEMO-7D", device_id=NEW_DEVICE)
    assert r.status_code == 200
    assert r.json()["code"] == 0
