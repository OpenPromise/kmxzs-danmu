"""测试辅助：模拟老客户端的 HMAC 签名请求。"""
from __future__ import annotations

import hashlib
import hmac
import time
import uuid
from typing import Any, Mapping, Optional

API_SECRET = "test-api-secret-0123456789abcdef0123456789abcdef"
API_ROOT = "/api/user/1009/flutter/1.0.2"
DEVICE_ID = "win-test-pc"


def sign(secret: str, path: str, timestamp: int, nonce: str, device_id: str, data: Mapping[str, Any]) -> str:
    skip = {"sign", "timestamp", "nonce", "deviceId", "device_id",
            "legacyDeviceId", "legacy_device_id"}
    parts: list[str] = []
    for k in sorted(data.keys()):
        if k in skip or data[k] is None:
            continue
        parts.append(f"{k}={data[k]}")
    msg = f"{timestamp}\n{nonce}\n{device_id}\n{path}\n{'&'.join(parts)}"
    return hmac.new(secret.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def signed_body(
    payload: Optional[Mapping[str, Any]] = None,
    *,
    path: str,
    device_id: str = DEVICE_ID,
    timestamp: Optional[int] = None,
    nonce: Optional[str] = None,
    secret: str = API_SECRET,
) -> dict[str, Any]:
    ts = timestamp if timestamp is not None else int(time.time() * 1000)
    n = nonce or uuid.uuid4().hex
    body = dict(payload or {})
    full: dict[str, Any] = dict(body)
    full["deviceId"] = device_id
    full["timestamp"] = ts
    full["nonce"] = n
    if secret:
        full["sign"] = sign(secret, path, ts, n, device_id, body)
    return full
