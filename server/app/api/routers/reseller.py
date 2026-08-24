"""阶段1：分销代理基础版。只能管理自己渠道下的卡密/账号/设备，发卡受 card_quota 限制。"""
from __future__ import annotations

import hashlib
import secrets
import time
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Request

from ...core.db import audit, db
from ...core.deps import require_reseller
from ...core.utils import client_ip, fail, ok, to_iso, utcnow
from ...schemas.auth import ResellerCreateCardBody, ResellerPatchCardBody
from ...services.auth import quota_used

router = APIRouter(prefix="/api/reseller", dependencies=[Depends(require_reseller)])


def _channel_id(user) -> int:
    return int(user["channel_id"])


def _audit(conn, user, action, request, *, target=None, detail=None, ok_flag=True) -> None:
    detail = dict(detail or {})
    detail.setdefault("role", user["role"])
    detail.setdefault("channel_id", user["channel_id"])
    audit(
        conn,
        action=action,
        actor=str(user["username"]),
        target=target,
        detail=detail,
        ip=client_ip(request),
        ok_flag=ok_flag,
    )


@router.get("/overview")
def reseller_overview(request: Request, user=Depends(require_reseller)) -> dict[str, Any]:
    channel_id = _channel_id(user)
    with db() as conn:
        cards_total = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE channel_id=?", (channel_id,)
        ).fetchone()["c"]
        cards_login = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE channel_id=? AND kind='login' AND enabled=1",
            (channel_id,),
        ).fetchone()["c"]
        cards_topup = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE channel_id=? AND kind='topup' AND enabled=1",
            (channel_id,),
        ).fetchone()["c"]
        accounts = conn.execute(
            "SELECT COUNT(*) AS c FROM accounts a JOIN cards c ON c.code=a.card WHERE c.channel_id=?",
            (channel_id,),
        ).fetchone()["c"]
        devices = conn.execute(
            "SELECT COUNT(*) AS c FROM devices d JOIN cards c ON c.code=d.card WHERE c.channel_id=?",
            (channel_id,),
        ).fetchone()["c"]
        used = quota_used(conn, channel_id)
        return ok(
            {
                "cardsTotal": cards_total,
                "cardsLoginEnabled": cards_login,
                "cardsTopupEnabled": cards_topup,
                "accounts": accounts,
                "devices": devices,
                "quota": int(user["card_quota"] or 0),
                "quota_used": used,
            }
        )


@router.get("/cards")
def reseller_list_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    channel_id = _channel_id(user)
    sql = """
        SELECT c.code, c.kind, c.hours, c.max_devices, c.enabled, c.note, c.created_at,
               a.expires_at AS account_expires_at,
               (SELECT COUNT(*) FROM devices d WHERE d.card=c.code) AS device_count,
               (SELECT 1 FROM topup_used t WHERE t.code=c.code) AS topup_used
        FROM cards c
        LEFT JOIN accounts a ON a.card=c.code
        WHERE c.channel_id=?
    """
    args: list[Any] = [channel_id]
    if kind in ("login", "topup"):
        sql += " AND c.kind=?"
        args.append(kind)
    if enabled is not None:
        sql += " AND c.enabled=?"
        args.append(int(enabled))
    if q:
        sql += " AND (c.code LIKE ? OR IFNULL(c.note,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    sql += " ORDER BY c.created_at DESC"
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        return ok([dict(r) for r in rows])


@router.get("/cards/export")
def reseller_export_cards(
    request: Request,
    user=Depends(require_reseller),
) -> Any:
    channel_id = _channel_id(user)
    with db() as conn:
        rows = conn.execute(
            "SELECT code, kind, hours, max_devices, enabled, note, created_at FROM cards WHERE channel_id=? ORDER BY created_at DESC",
            (channel_id,),
        ).fetchall()
        _audit(conn, user, "reseller_export_cards", request, detail={"count": len(rows)})
    lines = ["code,kind,hours,max_devices,enabled,note,created_at"]
    for r in rows:
        note = (r["note"] or "").replace('"', '""')
        lines.append(
            f'{r["code"]},{r["kind"]},{r["hours"]},{r["max_devices"]},{r["enabled"]},"{note}",{r["created_at"]}'
        )
    from fastapi.responses import Response
    return Response(
        content="\n".join(lines) + "\n",
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="kmxzs-reseller-cards.csv"'},
    )


@router.post("/cards")
def reseller_create_cards(
    request: Request,
    body: ResellerCreateCardBody,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    channel_id = _channel_id(user)
    created: list[str] = []
    now = to_iso(utcnow())
    with db() as conn:
        used = quota_used(conn, channel_id)
        quota = int(user["card_quota"] or 0)
        if body.kind == "login" and used + body.count > quota:
            raise HTTPException(
                status_code=403,
                detail=fail(403, f"发卡配额不足（已用 {used}/{quota}，本次需 {body.count}）"),
            )
        for _ in range(body.count):
            code = body.code
            if not code:
                suffix = hashlib.sha1(
                    f"{time.time_ns()}-{secrets.token_hex(4)}".encode()
                ).hexdigest()[:10].upper()
                prefix = "KMXZS-LOGIN" if body.kind == "login" else "KMXZS-TOPUP"
                code = f"{prefix}-{suffix}"
            exists = conn.execute("SELECT 1 FROM cards WHERE code=?", (code,)).fetchone()
            if exists:
                raise HTTPException(status_code=409, detail=fail(409, f"卡密已存在: {code}"))
            conn.execute(
                """
                INSERT INTO cards(code, kind, hours, max_devices, expires_at, enabled, note, created_at, channel_id)
                VALUES (?, ?, ?, ?, NULL, 1, ?, ?, ?)
                """,
                (code, body.kind, body.hours, body.max_devices, body.note, now, channel_id),
            )
            created.append(code)
            body.code = None
        _audit(
            conn,
            user,
            "reseller_create_cards",
            request,
            detail={"kind": body.kind, "count": len(created), "note": body.note},
        )
        new_used = quota_used(conn, channel_id)
    return ok(
        {"cards": created, "quota": quota, "quota_used": new_used},
        "created",
    )


def _own_card(conn, code: str, channel_id: int):
    row = conn.execute("SELECT * FROM cards WHERE code=?", (code,)).fetchone()
    if row is None or int(row["channel_id"] or 0) != channel_id:
        return None
    return row


@router.patch("/cards/{code}")
def reseller_patch_card(
    request: Request,
    code: str,
    body: ResellerPatchCardBody,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    channel_id = _channel_id(user)
    fields: list[str] = []
    args: list[Any] = []
    if body.enabled is not None:
        fields.append("enabled=?")
        args.append(1 if body.enabled else 0)
    if body.note is not None:
        fields.append("note=?")
        args.append(body.note)
    if body.max_devices is not None:
        fields.append("max_devices=?")
        args.append(body.max_devices)
    if body.hours is not None:
        fields.append("hours=?")
        args.append(body.hours)
    if not fields:
        return fail(400, "没有可更新字段")
    args.append(code)
    with db() as conn:
        if _own_card(conn, code, channel_id) is None:
            return fail(404, "卡密不存在")
        cur = conn.execute(
            f"UPDATE cards SET {', '.join(fields)} WHERE code=? AND channel_id=?",
            args + [channel_id],
        )
        if cur.rowcount == 0:
            return fail(404, "卡密不存在")
        row = conn.execute("SELECT * FROM cards WHERE code=?", (code,)).fetchone()
        _audit(
            conn,
            user,
            "reseller_patch_card",
            request,
            target=code,
            detail=body.model_dump(exclude_none=True),
        )
        return ok(dict(row), "updated")


@router.delete("/cards/{code}")
def reseller_delete_card(
    request: Request,
    code: str,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    channel_id = _channel_id(user)
    with db() as conn:
        if _own_card(conn, code, channel_id) is None:
            return fail(404, "卡密不存在")
        conn.execute("DELETE FROM sessions WHERE card=?", (code,))
        conn.execute("DELETE FROM devices WHERE card=?", (code,))
        conn.execute("DELETE FROM accounts WHERE card=?", (code,))
        conn.execute("DELETE FROM topup_used WHERE code=?", (code,))
        conn.execute("DELETE FROM cards WHERE code=? AND channel_id=?", (code, channel_id))
        _audit(conn, user, "reseller_delete_card", request, target=code)
    return ok({"code": code}, "deleted")


@router.get("/accounts")
def reseller_accounts(
    request: Request,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    channel_id = _channel_id(user)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT a.card, a.expires_at, a.created_at, a.updated_at,
                   (SELECT COUNT(*) FROM devices d WHERE d.card=a.card) AS device_count
            FROM accounts a JOIN cards c ON c.code=a.card
            WHERE c.channel_id=?
            ORDER BY a.updated_at DESC
            """,
            (channel_id,),
        ).fetchall()
        return ok([dict(r) for r in rows])


@router.get("/devices")
def reseller_devices(
    request: Request,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    channel_id = _channel_id(user)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT d.id, d.card, d.device_id, d.name, d.bound_at
            FROM devices d JOIN cards c ON c.code=d.card
            WHERE c.channel_id=?
            ORDER BY d.bound_at DESC
            """,
            (channel_id,),
        ).fetchall()
        return ok([dict(r) for r in rows])


@router.delete("/devices/{device_row_id}")
def reseller_delete_device(
    request: Request,
    device_row_id: int,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    """代理解绑自己渠道下的设备（必须归属自己渠道的卡密）。"""
    channel_id = _channel_id(user)
    with db() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id=?", (device_row_id,)).fetchone()
        if row is None:
            return fail(404, "设备不存在")
        card = conn.execute(
            "SELECT channel_id FROM cards WHERE code=?", (row["card"],)
        ).fetchone()
        if card is None or int(card["channel_id"] or 0) != channel_id:
            return fail(404, "设备不存在")
        conn.execute("DELETE FROM devices WHERE id=?", (device_row_id,))
        _audit(
            conn,
            user,
            "reseller_unbind_device",
            request,
            target=str(device_row_id),
            detail={"card": row["card"], "device_id": row["device_id"]},
        )
    return ok({"id": device_row_id}, "deleted")


@router.get("/logs")
def reseller_logs(
    request: Request,
    limit: int = 100,
    user=Depends(require_reseller),
) -> dict[str, Any]:
    limit = max(1, min(int(limit or 100), 500))
    with db() as conn:
        rows = conn.execute(
            "SELECT id, created_at, actor, action, target, detail, ip, ok FROM audit_logs WHERE actor=? ORDER BY id DESC LIMIT ?",
            (user["username"], limit),
        ).fetchall()
        return ok([dict(r) for r in rows])
