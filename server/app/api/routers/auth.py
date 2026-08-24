"""阶段1：JWT 登录 / 刷新 / 登出（superadmin 与 reseller 共用）。"""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Request

from ...core import config
from ...core.db import db
from ...core.deps import get_current_user
from ...core.security import rate_limit
from ...core.utils import client_ip, ok
from ...schemas.auth import LoginRequest, LogoutRequest, RefreshRequest
from ...services.auth import login, logout, refresh

router = APIRouter(prefix="/api/auth")


@router.post("/login")
def auth_login(request: Request, body: LoginRequest) -> dict[str, Any]:
    ip = client_ip(request)
    rate_limit(f"auth-login:{ip}", config.LOGIN_RATE_LIMIT, config.LOGIN_RATE_WINDOW)
    return login(body.username, body.password)


@router.post("/refresh")
def auth_refresh(request: Request, body: RefreshRequest) -> dict[str, Any]:
    ip = client_ip(request)
    rate_limit(f"auth-refresh:{ip}", config.LOGIN_RATE_LIMIT, config.LOGIN_RATE_WINDOW)
    return refresh(body.refresh_token)


@router.post("/logout")
def auth_logout(request: Request, body: LogoutRequest) -> dict[str, Any]:
    return logout(body.refresh_token)


@router.get("/me")
def auth_me(user=Depends(get_current_user)) -> dict[str, Any]:
    with db() as conn:
        from ...services.auth import quota_used
        used = quota_used(conn, user["channel_id"])
        return ok(
            {
                "id": user["id"],
                "username": user["username"],
                "role": user["role"],
                "channel_id": user["channel_id"],
                "card_quota": int(user["card_quota"] or 0),
                "enabled": bool(int(user["enabled"] or 1) == 1),
                "quota_used": used,
                "created_at": user["created_at"],
            }
        )
