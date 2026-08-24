"""阶段1：超管接口 — 渠道与代理管理。"""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Request

from ...core.db import audit, db
from ...core.deps import require_superadmin
from ...core.security import hash_password
from ...core.utils import client_ip, fail, ok
from ...schemas.auth import ChannelCreate, ChannelPatch, UserCreate, UserPatch
from ...services.auth import create_channel, create_user, quota_used

router = APIRouter(prefix="/api/admin", dependencies=[Depends(require_superadmin)])


def _audit(conn, user, action, request, *, target=None, detail=None) -> None:
    detail = dict(detail or {})
    detail.setdefault("role", user["role"])
    audit(
        conn,
        action=action,
        actor=str(user["username"]),
        target=target,
        detail=detail,
        ip=client_ip(request),
    )


# ---------------------------------------------------------------------------
# 渠道
# ---------------------------------------------------------------------------
@router.get("/channels")
def admin_list_channels(request: Request, user=Depends(require_superadmin)) -> dict[str, Any]:
    with db() as conn:
        rows = conn.execute(
            """
            SELECT ch.id, ch.code, ch.name, ch.owner_user_id, ch.status, ch.created_at,
                   (SELECT COUNT(*) FROM cards c WHERE c.channel_id=ch.id) AS card_count,
                   (SELECT COUNT(*) FROM users u WHERE u.channel_id=ch.id AND u.enabled=1) AS agent_count
            FROM channels ch
            ORDER BY ch.id ASC
            """
        ).fetchall()
        return ok([dict(r) for r in rows])


@router.post("/channels")
def admin_create_channel(
    request: Request,
    body: ChannelCreate,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    result = create_channel(body.code, body.name)
    with db() as conn:
        _audit(conn, user, "admin_create_channel", request, target=str(result["id"]), detail=result)
    return ok(result, "created")


@router.patch("/channels/{channel_id}")
def admin_patch_channel(
    request: Request,
    channel_id: int,
    body: ChannelPatch,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    fields: list[str] = []
    args: list[Any] = []
    if body.name is not None:
        fields.append("name=?")
        args.append(body.name)
    if body.status is not None:
        fields.append("status=?")
        args.append(1 if body.status else 0)
    if not fields:
        return fail(400, "没有可更新字段")
    args.append(channel_id)
    with db() as conn:
        cur = conn.execute(f"UPDATE channels SET {', '.join(fields)} WHERE id=?", args)
        if cur.rowcount == 0:
            return fail(404, "渠道不存在")
        row = conn.execute("SELECT * FROM channels WHERE id=?", (channel_id,)).fetchone()
        _audit(
            conn,
            user,
            "admin_patch_channel",
            request,
            target=str(channel_id),
            detail=body.model_dump(exclude_none=True),
        )
        return ok(dict(row), "updated")


# ---------------------------------------------------------------------------
# 用户 / 代理
# ---------------------------------------------------------------------------
@router.get("/users")
def admin_list_users(request: Request, user=Depends(require_superadmin)) -> dict[str, Any]:
    with db() as conn:
        rows = conn.execute(
            """
            SELECT u.id, u.username, u.role, u.channel_id, u.card_quota, u.enabled, u.created_at,
                   ch.name AS channel_name
            FROM users u LEFT JOIN channels ch ON ch.id=u.channel_id
            ORDER BY u.id ASC
            """
        ).fetchall()
        data = []
        for r in rows:
            d = dict(r)
            d["quota_used"] = quota_used(conn, r["channel_id"])
            data.append(d)
        return ok(data)


@router.post("/users")
def admin_create_user(
    request: Request,
    body: UserCreate,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    result = create_user(body.username, body.password, body.channel_id, body.card_quota, body.role)
    with db() as conn:
        _audit(conn, user, "admin_create_user", request, target=str(result["id"]), detail=result)
    return ok(result, "created")


@router.patch("/users/{user_id}")
def admin_patch_user(
    request: Request,
    user_id: int,
    body: UserPatch,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    fields: list[str] = []
    args: list[Any] = []
    if body.password is not None:
        fields.append("password_hash=?")
        args.append(hash_password(body.password))
    if body.channel_id is not None:
        with db() as conn:
            ch = conn.execute(
                "SELECT 1 FROM channels WHERE id=? AND status=1", (body.channel_id,)
            ).fetchone()
        if not ch:
            return fail(400, "渠道不存在或已停用")
        fields.append("channel_id=?")
        args.append(body.channel_id)
    if body.card_quota is not None:
        fields.append("card_quota=?")
        args.append(max(0, body.card_quota))
    if body.enabled is not None:
        with db() as conn:
            target = conn.execute("SELECT role FROM users WHERE id=?", (user_id,)).fetchone()
        if target and target["role"] == "superadmin" and body.enabled is False:
            return fail(400, "不能停用超管账号")
        fields.append("enabled=?")
        args.append(1 if body.enabled else 0)
    if not fields:
        return fail(400, "没有可更新字段")
    args.append(user_id)
    with db() as conn:
        cur = conn.execute(f"UPDATE users SET {', '.join(fields)} WHERE id=?", args)
        if cur.rowcount == 0:
            return fail(404, "用户不存在")
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        _audit(
            conn,
            user,
            "admin_patch_user",
            request,
            target=str(user_id),
            detail=body.model_dump(exclude_none=True),
        )
        return ok(dict(row), "updated")
