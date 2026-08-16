"""阶段2：管理 SPA 超管全量接口请求体（JWT 版，供 /api/admin 新端点使用）。"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field

from ..core.config import DEFAULT_MAX_DEVICES


class AdminOpsCreateCardBody(BaseModel):
    """超管发卡：与老后台一致，额外支持指定渠道 channel_id。"""
    code: Optional[str] = None
    kind: str = Field(default="login", pattern="^(login|topup)$")
    hours: int = Field(default=720, ge=1, le=24 * 3650)
    max_devices: int = Field(default=DEFAULT_MAX_DEVICES, ge=0, le=50)
    note: Optional[str] = None
    count: int = Field(default=1, ge=1, le=200)
    channel_id: Optional[int] = None


class AdminOpsPatchCardBody(BaseModel):
    enabled: Optional[bool] = None
    note: Optional[str] = None
    max_devices: Optional[int] = Field(default=None, ge=0, le=50)
    hours: Optional[int] = Field(default=None, ge=1, le=24 * 3650)


class AdminOpsExtendBody(BaseModel):
    hours: int = Field(default=24, ge=-24 * 365, le=24 * 3650)


class AdminOpsSettingsBody(BaseModel):
    notice: Optional[str] = None
    client_version: Optional[str] = None
    download_url: Optional[str] = None
    force_update: Optional[bool] = None
    min_client_version: Optional[str] = None
