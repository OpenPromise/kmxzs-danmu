"""阶段1：JWT 登录 / 渠道 / 代理管理请求体。"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    username: str
    password: str


class RefreshRequest(BaseModel):
    refresh_token: str


class LogoutRequest(BaseModel):
    refresh_token: str


class ChannelCreate(BaseModel):
    code: str
    name: str


class ChannelPatch(BaseModel):
    name: Optional[str] = None
    status: Optional[int] = Field(default=None, ge=0, le=1)


class UserCreate(BaseModel):
    username: str
    password: str
    role: str = Field(default="reseller", pattern="^(superadmin|reseller)$")
    channel_id: Optional[int] = None
    card_quota: int = Field(default=0, ge=0)


class UserPatch(BaseModel):
    password: Optional[str] = None
    channel_id: Optional[int] = None
    card_quota: Optional[int] = Field(default=None, ge=0)
    enabled: Optional[bool] = None


class ResellerCreateCardBody(BaseModel):
    code: Optional[str] = None
    kind: str = Field(default="login", pattern="^(login|topup)$")
    hours: int = Field(default=720, ge=1, le=24 * 3650)
    max_devices: int = Field(default=1, ge=0, le=50)
    note: Optional[str] = None
    count: int = Field(default=1, ge=1, le=200)


class ResellerPatchCardBody(BaseModel):
    enabled: Optional[bool] = None
    note: Optional[str] = None
    max_devices: Optional[int] = Field(default=None, ge=0, le=50)
    hours: Optional[int] = Field(default=None, ge=1, le=24 * 3650)
