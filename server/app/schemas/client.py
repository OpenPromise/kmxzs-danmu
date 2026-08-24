"""客户端请求体（老客户端 1.0.x 格式，字段顺序/兼容性不可变）。"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel


class SignedEmptyBody(BaseModel):
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class LoginBody(BaseModel):
    card: Optional[str] = None
    kami: Optional[str] = None
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    # 阶段3：客户端升级后携带旧指纹，服务端做一次静默迁移，避免老用户被设备数上限卡住
    legacy_device_id: Optional[str] = None
    legacyDeviceId: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class DeviceUnbindBody(BaseModel):
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class TopupBody(BaseModel):
    kami: Optional[str] = None
    card: Optional[str] = None
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None
