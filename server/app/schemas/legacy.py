"""过渡期旧后台（Basic + token）请求体。"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field

from ..core.config import DEFAULT_MAX_DEVICES


class AdminCreateCardBody(BaseModel):
    code: Optional[str] = None
    kind: str = Field(default="login", pattern="^(login|topup)$")
    hours: int = Field(default=720, ge=1, le=24 * 3650)
    max_devices: int = Field(default=DEFAULT_MAX_DEVICES, ge=0, le=50)
    note: Optional[str] = None
    count: int = Field(default=1, ge=1, le=200)


class AdminPatchCardBody(BaseModel):
    enabled: Optional[bool] = None
    note: Optional[str] = None
    max_devices: Optional[int] = Field(default=None, ge=0, le=50)
    hours: Optional[int] = Field(default=None, ge=1, le=24 * 3650)


class AdminExtendBody(BaseModel):
    hours: int = Field(default=24, ge=-24 * 365, le=24 * 3650)


class AdminSettingsBody(BaseModel):
    notice: Optional[str] = None
    client_version: Optional[str] = None
    download_url: Optional[str] = None
    force_update: Optional[bool] = None
    min_client_version: Optional[str] = None
