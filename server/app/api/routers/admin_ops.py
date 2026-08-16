"""阶段2：超管全量管理接口（JWT 版，供管理 SPA 使用）。

与过渡期 /zbpanel/*（Basic + token）逻辑一致，但：
  - 走 JWT 鉴权（require_superadmin）
  - 审计 actor 记录真实用户名
  - 卡密/日志支持分页，卡密支持按渠道过滤
老客户端 /api/user/1009/flutter/1.0.2/* 与 /zbpanel/* 行为完全不受影响。
"""
from __future__ import annotations

import hashlib
import re
import secrets
import shutil
import time
from datetime import datetime, timezone
from typing import Any, Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import Response

from ...core import config
from ...core.db import audit, db, get_setting, set_setting
from ...core.deps import require_superadmin
from ...core.utils import client_ip, fail, ok, public_origin, to_iso, utcnow
from ...schemas.admin import (
    AdminOpsCreateCardBody,
    AdminOpsExtendBody,
    AdminOpsPatchCardBody,
    AdminOpsSettingsBody,
)
from ...services.cards import add_hours
from ...services.releases import highest_release, latest_download_url, load_public_config, release_safe_name

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


def _page_args(page: Optional[int], page_size: Optional[int]) -> tuple[int, int]:
    p = max(1, int(page or 1))
    ps = max(1, min(int(page_size or 20), 200))
    return p, ps


# ---------------------------------------------------------------------------
# 数据总览
# ---------------------------------------------------------------------------
@router.get("/overview")
def admin_overview(request: Request, user=Depends(require_superadmin)) -> dict[str, Any]:
    with db() as conn:
        cards_total = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()["c"]
        cards_login = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE kind='login' AND enabled=1"
        ).fetchone()["c"]
        cards_topup = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE kind='topup' AND enabled=1"
        ).fetchone()["c"]
        accounts = conn.execute("SELECT COUNT(*) AS c FROM accounts").fetchone()["c"]
        devices = conn.execute("SELECT COUNT(*) AS c FROM devices").fetchone()["c"]
        sessions = conn.execute("SELECT COUNT(*) AS c FROM sessions").fetchone()["c"]
        used_topup = conn.execute("SELECT COUNT(*) AS c FROM topup_used").fetchone()["c"]
        users = conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"]
        resellers = conn.execute(
            "SELECT COUNT(*) AS c FROM users WHERE role='reseller' AND enabled=1"
        ).fetchone()["c"]
        channels = conn.execute(
            """
            SELECT ch.id, ch.code, ch.name, ch.status, ch.owner_user_id,
                   (SELECT COUNT(*) FROM cards c WHERE c.channel_id=ch.id) AS card_count,
                   (SELECT COUNT(*) FROM users u WHERE u.channel_id=ch.id AND u.enabled=1) AS agent_count
            FROM channels ch
            ORDER BY ch.id ASC
            """
        ).fetchall()
        notes = conn.execute(
            """
            SELECT IFNULL(NULLIF(TRIM(note), ''), '(无备注)') AS channel, COUNT(*) AS c
            FROM cards
            GROUP BY channel
            ORDER BY c DESC
            LIMIT 20
            """
        ).fetchall()
        return ok(
            {
                "cardsTotal": cards_total,
                "cardsLoginEnabled": cards_login,
                "cardsTopupEnabled": cards_topup,
                "accounts": accounts,
                "devices": devices,
                "sessions": sessions,
                "topupUsed": used_topup,
                "users": users,
                "resellers": resellers,
                "channels": [dict(r) for r in channels],
                "noteChannels": [{"name": r["channel"], "count": r["c"]} for r in notes],
            }
        )


# ---------------------------------------------------------------------------
# 卡密
# ---------------------------------------------------------------------------
def _cards_sql_and_args(
    kind: Optional[str], enabled: Optional[int], q: Optional[str], channel_id: Optional[int]
) -> tuple[str, list[Any]]:
    sql = """
        SELECT c.code, c.kind, c.hours, c.max_devices, c.enabled, c.note, c.created_at,
               c.channel_id, ch.name AS channel_name,
               a.expires_at AS account_expires_at,
               (SELECT COUNT(*) FROM devices d WHERE d.card=c.code) AS device_count,
               (SELECT 1 FROM topup_used t WHERE t.code=c.code) AS topup_used
        FROM cards c
        LEFT JOIN accounts a ON a.card=c.code
        LEFT JOIN channels ch ON ch.id=c.channel_id
        WHERE 1=1
    """
    args: list[Any] = []
    if kind in ("login", "topup"):
        sql += " AND c.kind=?"
        args.append(kind)
    if enabled is not None:
        sql += " AND c.enabled=?"
        args.append(int(enabled))
    if channel_id:
        sql += " AND c.channel_id=?"
        args.append(int(channel_id))
    if q:
        sql += " AND (c.code LIKE ? OR IFNULL(c.note,'') LIKE ? OR IFNULL(ch.name,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%", f"%{q}%"])
    return sql, args


@router.get("/cards")
def admin_list_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    channel_id: Optional[int] = None,
    page: Optional[int] = Query(default=1, ge=1),
    page_size: Optional[int] = Query(default=20, ge=1, le=200),
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    sql, args = _cards_sql_and_args(kind, enabled, q, channel_id)
    p, ps = _page_args(page, page_size)
    with db() as conn:
        total = conn.execute("SELECT COUNT(*) AS c FROM cards c LEFT JOIN channels ch ON ch.id=c.channel_id WHERE 1=1" + sql.split("WHERE 1=1", 1)[1], args).fetchone()["c"]
        rows = conn.execute(sql + " ORDER BY c.created_at DESC, c.code DESC LIMIT ? OFFSET ?", args + [ps, (p - 1) * ps]).fetchall()
        return ok({"items": [dict(r) for r in rows], "total": int(total), "page": p, "page_size": ps})


@router.get("/cards/export")
def admin_export_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    channel_id: Optional[int] = None,
    user=Depends(require_superadmin),
) -> Response:
    sql = "SELECT code, kind, hours, max_devices, enabled, note, created_at, channel_id FROM cards WHERE 1=1"
    args: list[Any] = []
    if kind in ("login", "topup"):
        sql += " AND kind=?"
        args.append(kind)
    if enabled is not None:
        sql += " AND enabled=?"
        args.append(int(enabled))
    if channel_id:
        sql += " AND channel_id=?"
        args.append(int(channel_id))
    if q:
        sql += " AND (code LIKE ? OR IFNULL(note,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    sql += " ORDER BY created_at DESC"
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        _audit(conn, user, "admin_export_cards", request, detail={"count": len(rows)})
    lines = ["code,kind,hours,max_devices,enabled,note,channel_id,created_at"]
    for r in rows:
        note = (r["note"] or "").replace('"', '""')
        lines.append(
            f'{r["code"]},{r["kind"]},{r["hours"]},{r["max_devices"]},{r["enabled"]},"{note}",{r["channel_id"] or ""},{r["created_at"]}'
        )
    return Response(
        content="\n".join(lines) + "\n",
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="kmxzs-admin-cards.csv"'},
    )


@router.post("/cards")
def admin_create_cards(
    request: Request,
    body: AdminOpsCreateCardBody,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    created: list[str] = []
    now = to_iso(utcnow())
    with db() as conn:
        if body.channel_id is not None:
            ch = conn.execute(
                "SELECT 1 FROM channels WHERE id=? AND status=1", (body.channel_id,)
            ).fetchone()
            if not ch:
                return fail(400, "渠道不存在或已停用")
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
                (code, body.kind, body.hours, body.max_devices, body.note, now, body.channel_id),
            )
            created.append(code)
            body.code = None
        _audit(
            conn,
            user,
            "admin_create_cards",
            request,
            detail={"kind": body.kind, "count": len(created), "note": body.note, "channel_id": body.channel_id},
        )
    return ok({"cards": created}, "created")


@router.patch("/cards/{code}")
def admin_patch_card(
    request: Request,
    code: str,
    body: AdminOpsPatchCardBody,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
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
        cur = conn.execute(f"UPDATE cards SET {', '.join(fields)} WHERE code=?", args)
        if cur.rowcount == 0:
            return fail(404, "卡密不存在")
        row = conn.execute("SELECT * FROM cards WHERE code=?", (code,)).fetchone()
        _audit(
            conn,
            user,
            "admin_patch_card",
            request,
            target=code,
            detail=body.model_dump(exclude_none=True),
        )
        return ok(dict(row), "updated")


@router.delete("/cards/{code}")
def admin_delete_card(
    request: Request,
    code: str,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    with db() as conn:
        conn.execute("DELETE FROM sessions WHERE card=?", (code,))
        conn.execute("DELETE FROM devices WHERE card=?", (code,))
        conn.execute("DELETE FROM accounts WHERE card=?", (code,))
        conn.execute("DELETE FROM topup_used WHERE code=?", (code,))
        cur = conn.execute("DELETE FROM cards WHERE code=?", (code,))
        if cur.rowcount == 0:
            return fail(404, "卡密不存在")
        _audit(conn, user, "admin_delete_card", request, target=code)
    return ok({"code": code}, "deleted")


# ---------------------------------------------------------------------------
# 账号
# ---------------------------------------------------------------------------
@router.get("/accounts")
def admin_accounts(
    request: Request,
    q: Optional[str] = None,
    page: Optional[int] = Query(default=1, ge=1),
    page_size: Optional[int] = Query(default=20, ge=1, le=200),
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    p, ps = _page_args(page, page_size)
    sql = """
        SELECT a.card, a.expires_at, a.created_at, a.updated_at,
               (SELECT COUNT(*) FROM devices d WHERE d.card=a.card) AS device_count,
               ch.name AS channel_name
        FROM accounts a
        LEFT JOIN cards c ON c.code=a.card
        LEFT JOIN channels ch ON ch.id=c.channel_id
        WHERE 1=1
    """
    args: list[Any] = []
    if q:
        sql += " AND (a.card LIKE ? OR IFNULL(ch.name,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    with db() as conn:
        total = conn.execute("SELECT COUNT(*) AS c FROM accounts a LEFT JOIN cards c ON c.code=a.card LEFT JOIN channels ch ON ch.id=c.channel_id WHERE 1=1" + sql.split("WHERE 1=1", 1)[1], args).fetchone()["c"]
        rows = conn.execute(sql + " ORDER BY a.updated_at DESC LIMIT ? OFFSET ?", args + [ps, (p - 1) * ps]).fetchall()
        return ok({"items": [dict(r) for r in rows], "total": int(total), "page": p, "page_size": ps})


@router.post("/accounts/{card}/extend")
def admin_extend_account(
    request: Request,
    card: str,
    body: AdminOpsExtendBody,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    with db() as conn:
        exists = conn.execute("SELECT 1 FROM accounts WHERE card=?", (card,)).fetchone()
        card_exists = conn.execute("SELECT 1 FROM cards WHERE code=?", (card,)).fetchone()
        if exists is None and card_exists is None:
            return fail(404, "账号/卡密不存在")
        expires = add_hours(conn, card, body.hours)
        conn.execute(
            "UPDATE sessions SET expires_at=? WHERE card=?",
            (to_iso(expires), card),
        )
        _audit(
            conn,
            user,
            "admin_extend_account",
            request,
            target=card,
            detail={"hours": body.hours},
        )
        return ok({"card": card, "expires": to_iso(expires)}, "extended")


# ---------------------------------------------------------------------------
# 设备
# ---------------------------------------------------------------------------
@router.get("/devices")
def admin_devices(
    request: Request,
    q: Optional[str] = None,
    page: Optional[int] = Query(default=1, ge=1),
    page_size: Optional[int] = Query(default=20, ge=1, le=200),
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    p, ps = _page_args(page, page_size)
    sql = """
        SELECT d.id, d.card, d.device_id, d.name, d.bound_at,
               ch.name AS channel_name
        FROM devices d
        LEFT JOIN cards c ON c.code=d.card
        LEFT JOIN channels ch ON ch.id=c.channel_id
        WHERE 1=1
    """
    args: list[Any] = []
    if q:
        sql += " AND (d.device_id LIKE ? OR d.card LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    with db() as conn:
        total = conn.execute("SELECT COUNT(*) AS c FROM devices d LEFT JOIN cards c ON c.code=d.card LEFT JOIN channels ch ON ch.id=c.channel_id WHERE 1=1" + sql.split("WHERE 1=1", 1)[1], args).fetchone()["c"]
        rows = conn.execute(sql + " ORDER BY d.bound_at DESC LIMIT ? OFFSET ?", args + [ps, (p - 1) * ps]).fetchall()
        return ok({"items": [dict(r) for r in rows], "total": int(total), "page": p, "page_size": ps})


@router.delete("/devices/{device_row_id}")
def admin_delete_device(
    request: Request,
    device_row_id: int,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    with db() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id=?", (device_row_id,)).fetchone()
        cur = conn.execute("DELETE FROM devices WHERE id=?", (device_row_id,))
        if cur.rowcount == 0:
            return fail(404, "设备不存在")
        _audit(
            conn,
            user,
            "admin_unbind_device",
            request,
            target=str(device_row_id),
            detail={"card": row["card"] if row else None, "device_id": row["device_id"] if row else None},
        )
    return ok({"id": device_row_id}, "deleted")


# ---------------------------------------------------------------------------
# 审计日志
# ---------------------------------------------------------------------------
@router.get("/logs")
def admin_logs(
    request: Request,
    page: Optional[int] = Query(default=1, ge=1),
    page_size: Optional[int] = Query(default=20, ge=1, le=200),
    action: Optional[str] = None,
    actor: Optional[str] = None,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    p, ps = _page_args(page, page_size)
    where = "WHERE 1=1"
    args: list[Any] = []
    if action:
        where += " AND action=?"
        args.append(action)
    if actor:
        where += " AND actor=?"
        args.append(actor)
    with db() as conn:
        total = conn.execute(f"SELECT COUNT(*) AS c FROM audit_logs {where}", args).fetchone()["c"]
        rows = conn.execute(
            f"SELECT id, created_at, actor, action, target, detail, ip, ok FROM audit_logs {where} ORDER BY id DESC LIMIT ? OFFSET ?",
            args + [ps, (p - 1) * ps],
        ).fetchall()
        return ok({"items": [dict(r) for r in rows], "total": int(total), "page": p, "page_size": ps})


# ---------------------------------------------------------------------------
# 客户端配置
# ---------------------------------------------------------------------------
@router.get("/settings")
def admin_get_settings(request: Request, user=Depends(require_superadmin)) -> dict[str, Any]:
    with db() as conn:
        rows = conn.execute(
            "SELECT key, value, updated_at FROM app_settings ORDER BY key ASC"
        ).fetchall()
        data = {r["key"]: {"value": r["value"], "updatedAt": r["updated_at"]} for r in rows}
        return ok({"settings": data, "public": load_public_config(conn, request)})


@router.put("/settings")
def admin_put_settings(
    request: Request,
    body: AdminOpsSettingsBody,
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    with db() as conn:
        if body.notice is not None:
            set_setting(conn, "notice", body.notice)
        if body.client_version is not None:
            set_setting(conn, "client_version", body.client_version.strip())
        rel = highest_release()
        advertised = (rel[0] if rel else None) or (
            body.client_version or get_setting(conn, "client_version", "1.0.0")
        )
        set_setting(conn, "download_url", latest_download_url(request, advertised))
        if body.force_update is not None:
            set_setting(conn, "force_update", "1" if body.force_update else "0")
        if body.min_client_version is not None:
            set_setting(conn, "min_client_version", body.min_client_version.strip())
        _audit(conn, user, "admin_update_settings", request, detail=body.model_dump(exclude_none=True))
        return ok(load_public_config(conn, request), "updated")


# ---------------------------------------------------------------------------
# 安装包发布
# ---------------------------------------------------------------------------
@router.get("/releases")
def admin_list_releases(request: Request, user=Depends(require_superadmin)) -> dict[str, Any]:
    config.RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    items = []
    for p in sorted(config.RELEASES_DIR.glob("*.exe"), key=lambda x: x.stat().st_mtime, reverse=True):
        st = p.stat()
        items.append(
            {
                "name": p.name,
                "size": st.st_size,
                "updatedAt": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat(),
                "url": f"{public_origin(request)}/files/{p.name}",
            }
        )
    return ok({"files": items, "latestUrl": f"{public_origin(request)}/files/latest.exe"})


@router.post("/releases")
async def admin_upload_release(
    request: Request,
    file: UploadFile = File(...),
    version: str = Form(default=""),
    force_update: str = Form(default="0"),
    user=Depends(require_superadmin),
) -> dict[str, Any]:
    ver = (version or "").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
        raise HTTPException(status_code=400, detail=fail(400, "请填写版本号，例如 1.0.1"))
    raw_name = file.filename or "setup.exe"
    if not raw_name.lower().endswith(".exe"):
        raise HTTPException(status_code=400, detail=fail(400, "只允许 .exe 安装包"))

    config.RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    tmp = config.RELEASES_DIR / f".tmp-{secrets.token_hex(8)}.exe"
    size = 0
    try:
        with tmp.open("wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > config.MAX_RELEASE_BYTES:
                    raise HTTPException(status_code=413, detail=fail(413, "安装包过大"))
                out.write(chunk)
        if size < 1024:
            raise HTTPException(status_code=400, detail=fail(400, "文件太小，不像安装包"))
        with tmp.open("rb") as fh:
            magic = fh.read(2)
        if magic != b"MZ":
            raise HTTPException(status_code=400, detail=fail(400, "不是有效的 Windows 可执行文件"))
        versioned = config.RELEASES_DIR / f"zbxzs-setup-{ver}.exe"
        shutil.move(str(tmp), str(versioned))
        rel = highest_release()
        latest = config.RELEASES_DIR / "latest.exe"
        shutil.copy2(rel[1] if rel else versioned, latest)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)
        await file.close()

    rel = highest_release()
    advertised = rel[0] if rel else ver
    download = latest_download_url(request, advertised)
    with db() as conn:
        set_setting(conn, "client_version", advertised)
        set_setting(conn, "download_url", download)
        if force_update in ("1", "true", "True", "yes"):
            set_setting(conn, "force_update", "1")
        _audit(
            conn,
            user,
            "admin_upload_release",
            request,
            target=ver,
            detail={"size": size, "download": download},
        )
        pub = load_public_config(conn, request)
    return ok(
        {
            "version": advertised,
            "size": size,
            "download": download,
            "public": pub,
        },
        "uploaded",
    )
