"""过渡期旧后台（Basic + admin token，静态 index.html）。行为与响应结构保持不变。"""
from __future__ import annotations

import hashlib
import re
import secrets
import shutil
import time
from datetime import datetime, timezone
from typing import Any, Optional

from fastapi import APIRouter, File, Form, Header, HTTPException, Query, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse, Response

from ...core import config
from ...core.db import audit, db, get_setting, set_setting
from ...core.security import require_admin
from ...core.utils import client_ip, fail, ok, public_origin, to_iso, utcnow
from ...schemas.legacy import (
    AdminCreateCardBody,
    AdminExtendBody,
    AdminPatchCardBody,
    AdminSettingsBody,
)
from ...services.cards import add_hours
from ...services.releases import highest_release, latest_download_url, load_public_config

router = APIRouter()

ADMIN_PREFIX = config.ADMIN_PREFIX
STATIC_DIR = config.STATIC_DIR


@router.get(ADMIN_PREFIX)
def admin_redirect() -> RedirectResponse:
    return RedirectResponse(url=ADMIN_PREFIX + "/")


@router.get(ADMIN_PREFIX + "/")
def admin_index() -> HTMLResponse:
    index = STATIC_DIR / "index.html"
    if not index.exists():
        raise HTTPException(status_code=404, detail="admin ui missing")
    html = index.read_text(encoding="utf-8").replace("__ADMIN_BASE__", ADMIN_PREFIX)
    return HTMLResponse(html)


@router.get(ADMIN_PREFIX + "/overview")
def admin_overview(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
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
                "channels": [{"name": r["channel"], "count": r["c"]} for r in notes],
            }
        )


@router.get(ADMIN_PREFIX + "/cards")
def admin_list_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    sql = """
        SELECT c.code, c.kind, c.hours, c.max_devices, c.enabled, c.note, c.created_at,
               a.expires_at AS account_expires_at,
               (SELECT COUNT(*) FROM devices d WHERE d.card=c.code) AS device_count,
               (SELECT 1 FROM topup_used t WHERE t.code=c.code) AS topup_used
        FROM cards c
        LEFT JOIN accounts a ON a.card=c.code
        WHERE 1=1
    """
    args: list[Any] = []
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


@router.get(ADMIN_PREFIX + "/cards/export")
def admin_export_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    x_admin_token: Optional[str] = Header(default=None),
) -> Response:
    require_admin(request, x_admin_token)
    sql = "SELECT code, kind, hours, max_devices, enabled, note, created_at FROM cards WHERE 1=1"
    args: list[Any] = []
    if kind in ("login", "topup"):
        sql += " AND kind=?"
        args.append(kind)
    if enabled is not None:
        sql += " AND enabled=?"
        args.append(int(enabled))
    if q:
        sql += " AND (code LIKE ? OR IFNULL(note,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    sql += " ORDER BY created_at DESC"
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        audit(conn, action="export_cards", actor="admin", detail={"count": len(rows)}, ip=client_ip(request))
    lines = ["code,kind,hours,max_devices,enabled,note,created_at"]
    for r in rows:
        note = (r["note"] or "").replace('"', '""')
        lines.append(
            f'{r["code"]},{r["kind"]},{r["hours"]},{r["max_devices"]},{r["enabled"]},"{note}",{r["created_at"]}'
        )
    content = "\n".join(lines) + "\n"
    return Response(
        content=content,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="kmxzs-cards.csv"'},
    )


@router.post(ADMIN_PREFIX + "/cards")
def admin_create_cards(
    request: Request,
    body: AdminCreateCardBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    created: list[str] = []
    now = to_iso(utcnow())
    with db() as conn:
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
                INSERT INTO cards(code, kind, hours, max_devices, expires_at, enabled, note, created_at)
                VALUES (?, ?, ?, ?, NULL, 1, ?, ?)
                """,
                (code, body.kind, body.hours, body.max_devices, body.note, now),
            )
            created.append(code)
            body.code = None
        audit(
            conn,
            action="create_cards",
            actor="admin",
            detail={"kind": body.kind, "count": len(created), "note": body.note},
            ip=client_ip(request),
        )
    return ok({"cards": created}, "created")


@router.patch(ADMIN_PREFIX + "/cards/{code}")
def admin_patch_card(
    request: Request,
    code: str,
    body: AdminPatchCardBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
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
        audit(
            conn,
            action="patch_card",
            actor="admin",
            target=code,
            detail=body.model_dump(exclude_none=True),
            ip=client_ip(request),
        )
        return ok(dict(row), "updated")


@router.delete(ADMIN_PREFIX + "/cards/{code}")
def admin_delete_card(
    request: Request,
    code: str,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        conn.execute("DELETE FROM sessions WHERE card=?", (code,))
        conn.execute("DELETE FROM devices WHERE card=?", (code,))
        conn.execute("DELETE FROM accounts WHERE card=?", (code,))
        conn.execute("DELETE FROM topup_used WHERE code=?", (code,))
        cur = conn.execute("DELETE FROM cards WHERE code=?", (code,))
        if cur.rowcount == 0:
            return fail(404, "卡密不存在")
        audit(conn, action="delete_card", actor="admin", target=code, ip=client_ip(request))
    return ok({"code": code}, "deleted")


@router.get(ADMIN_PREFIX + "/accounts")
def admin_accounts(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT a.card, a.expires_at, a.created_at, a.updated_at,
                   (SELECT COUNT(*) FROM devices d WHERE d.card=a.card) AS device_count
            FROM accounts a
            ORDER BY a.updated_at DESC
            """
        ).fetchall()
        return ok([dict(r) for r in rows])


@router.post(ADMIN_PREFIX + "/accounts/{card}/extend")
def admin_extend_account(
    request: Request,
    card: str,
    body: AdminExtendBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
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
        audit(
            conn,
            action="extend_account",
            actor="admin",
            target=card,
            detail={"hours": body.hours},
            ip=client_ip(request),
        )
        return ok({"card": card, "expires": to_iso(expires)}, "extended")


@router.get(ADMIN_PREFIX + "/devices")
def admin_devices(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT id, card, device_id, name, bound_at
            FROM devices
            ORDER BY bound_at DESC
            """
        ).fetchall()
        return ok([dict(r) for r in rows])


@router.delete(ADMIN_PREFIX + "/devices/{device_row_id}")
def admin_delete_device(
    request: Request,
    device_row_id: int,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id=?", (device_row_id,)).fetchone()
        cur = conn.execute("DELETE FROM devices WHERE id=?", (device_row_id,))
        if cur.rowcount == 0:
            return fail(404, "设备不存在")
        audit(
            conn,
            action="admin_unbind_device",
            actor="admin",
            target=str(device_row_id),
            detail={"card": row["card"] if row else None, "device_id": row["device_id"] if row else None},
            ip=client_ip(request),
        )
    return ok({"id": device_row_id}, "deleted")


@router.get(ADMIN_PREFIX + "/logs")
def admin_logs(
    request: Request,
    limit: int = Query(default=100, ge=1, le=500),
    action: Optional[str] = None,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    sql = "SELECT id, created_at, actor, action, target, detail, ip, ok FROM audit_logs"
    args: list[Any] = []
    if action:
        sql += " WHERE action=?"
        args.append(action)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(limit)
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        return ok([dict(r) for r in rows])


@router.get(ADMIN_PREFIX + "/token-hint")
def admin_token_hint(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    return ok(
        {
            "configured": bool(config.ADMIN_TOKEN),
            "hint": "已通过后台账号认证",
        }
    )


@router.get(ADMIN_PREFIX + "/settings")
def admin_get_settings(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        rows = conn.execute(
            "SELECT key, value, updated_at FROM app_settings ORDER BY key ASC"
        ).fetchall()
        data = {r["key"]: {"value": r["value"], "updatedAt": r["updated_at"]} for r in rows}
        return ok({"settings": data, "public": load_public_config(conn, request)})


@router.put(ADMIN_PREFIX + "/settings")
def admin_put_settings(
    request: Request,
    body: AdminSettingsBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
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
        audit(
            conn,
            action="update_settings",
            actor="admin",
            detail=body.model_dump(exclude_none=True),
            ip=client_ip(request),
        )
        return ok(load_public_config(conn, request), "updated")


@router.get(ADMIN_PREFIX + "/releases")
def admin_list_releases(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
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


@router.post(ADMIN_PREFIX + "/releases")
async def admin_upload_release(
    request: Request,
    file: UploadFile = File(...),
    version: str = Form(default=""),
    force_update: str = Form(default="0"),
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
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
        audit(
            conn,
            action="upload_release",
            actor="admin",
            target=ver,
            detail={"size": size, "download": download},
            ip=client_ip(request),
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
