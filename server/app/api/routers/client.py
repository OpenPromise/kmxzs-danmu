"""客户端 API（老客户端 1.0.x 硬编码路径与响应结构，绝不能改）。"""
from __future__ import annotations

import secrets
import uuid
from typing import Any

from fastapi import APIRouter, Request

from ...core import config as cfg
from ...core.db import audit, db
from ...core.deps import auth_card
from ...core.security import rate_limit, require_client_sign
from ...core.utils import body_dict, client_ip, fail, ok, parse_dt, to_iso, utcnow
from ...schemas.client import DeviceUnbindBody, LoginBody, SignedEmptyBody, TopupBody
from ...services.cards import account_profile, add_hours, ensure_account
from ...services.releases import load_public_config

router = APIRouter(prefix=cfg.API_ROOT)


@router.post("/login")
def login(request: Request, body: LoginBody) -> dict[str, Any]:
    ip = client_ip(request)
    rate_limit(f"login:{ip}", cfg.LOGIN_RATE_LIMIT, cfg.LOGIN_RATE_WINDOW)
    require_client_sign(f"{cfg.API_ROOT}/login", body_dict(body))

    code = (body.card or body.kami or "").strip()
    device_id = (body.deviceId or body.device_id or "").strip() or f"unknown-{uuid.uuid4().hex[:8]}"
    # 阶段3：客户端升级后同时携带旧指纹，供同机静默迁移（不占设备数、不踢老设备）
    legacy_device_id = (body.legacyDeviceId or body.legacy_device_id or "").strip()
    if not code:
        return fail(400, "请输入卡密")

    with db() as conn:
        card = conn.execute("SELECT * FROM cards WHERE code=?", (code,)).fetchone()
        if card is None or int(card["enabled"]) != 1:
            audit(conn, action="login_fail", actor=code or "-", target=code, detail={"reason": "invalid"}, ip=ip, ok_flag=False)
            return fail(401, "卡密无效")
        if card["kind"] != "login":
            audit(conn, action="login_fail", actor=code, target=code, detail={"reason": "not_login_card"}, ip=ip, ok_flag=False)
            return fail(400, "这是充值卡，请在客户端「卡密充值」使用")

        card_exp = parse_dt(card["expires_at"])
        if card_exp and card_exp < utcnow():
            audit(conn, action="login_fail", actor=code, target=code, detail={"reason": "card_expired"}, ip=ip, ok_flag=False)
            return fail(401, "卡密已过期")

        expires = ensure_account(conn, code, int(card["hours"]))
        if expires < utcnow():
            audit(conn, action="login_fail", actor=code, target=code, detail={"reason": "account_expired"}, ip=ip, ok_flag=False)
            return fail(401, "账号已过期，请充值")

        devices = conn.execute(
            "SELECT * FROM devices WHERE card=? ORDER BY id ASC", (code,)
        ).fetchall()
        bound = next((d for d in devices if d["device_id"] == device_id), None)
        max_devices = int(card["max_devices"] or cfg.DEFAULT_MAX_DEVICES)
        if bound is None and legacy_device_id:
            # 静默迁移：新指纹未绑定但旧指纹已绑定（老客户端升级），更新为同机新指纹，
            # 不新增设备行、不触发设备数上限，用户无感知。
            legacy_bound = next(
                (d for d in devices if d["device_id"] == legacy_device_id), None
            )
            if legacy_bound is not None:
                conn.execute(
                    "UPDATE devices SET device_id=?, name=?, bound_at=? WHERE id=?",
                    (device_id, device_id, to_iso(utcnow()), legacy_bound["id"]),
                )
                bound = legacy_bound
                audit(
                    conn,
                    action="device_fingerprint_migrate",
                    actor=code,
                    target=code,
                    detail={"from": legacy_device_id, "to": device_id},
                    ip=ip,
                )
        if bound is None:
            if len(devices) >= max_devices:
                audit(
                    conn,
                    action="login_fail",
                    actor=code,
                    target=code,
                    detail={"reason": "device_limit", "deviceId": device_id},
                    ip=ip,
                    ok_flag=False,
                )
                return fail(403, f"设备数已达上限({max_devices})，请先解绑")
            conn.execute(
                """
                INSERT INTO devices(card, device_id, name, bound_at)
                VALUES (?, ?, ?, ?)
                """,
                (code, device_id, device_id, to_iso(utcnow())),
            )

        # 同设备只保留最新会话，降低盗用面
        conn.execute("DELETE FROM sessions WHERE card=? AND device_id=?", (code, device_id))
        token = secrets.token_urlsafe(32)
        conn.execute(
            """
            INSERT INTO sessions(token, card, device_id, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (token, code, device_id, to_iso(expires), to_iso(utcnow())),
        )
        profile = account_profile(conn, code, device_id)
        audit(
            conn,
            action="login_ok",
            actor=code,
            target=code,
            detail={"deviceId": device_id},
            ip=ip,
        )
        return ok(
            {
                "token": token,
                **profile,
            },
            message="登录成功",
        )


@router.post("/config")
def config(request: Request, body: SignedEmptyBody = SignedEmptyBody()) -> dict[str, Any]:
    require_client_sign(f"{cfg.API_ROOT}/config", body_dict(body))
    with db() as conn:
        return ok(load_public_config(conn, request))


@router.post("/me")
def me(request: Request, body: SignedEmptyBody = SignedEmptyBody()) -> dict[str, Any]:
    require_client_sign(f"{cfg.API_ROOT}/me", body_dict(body))
    with db() as conn:
        session = auth_card(request, conn)
        profile = account_profile(conn, str(session["card"]), session["device_id"])
        return ok(profile)


@router.post("/device/list")
def device_list(request: Request, body: SignedEmptyBody = SignedEmptyBody()) -> dict[str, Any]:
    require_client_sign(f"{cfg.API_ROOT}/device/list", body_dict(body))
    with db() as conn:
        session = auth_card(request, conn)
        card = str(session["card"])
        rows = conn.execute(
            "SELECT device_id, name, bound_at FROM devices WHERE card=? ORDER BY id ASC",
            (card,),
        ).fetchall()
        data = [
            {
                "deviceId": r["device_id"],
                "device_id": r["device_id"],
                "name": r["name"] or r["device_id"],
                "boundAt": r["bound_at"],
            }
            for r in rows
        ]
        return ok(data)


@router.post("/device/unbind")
def device_unbind(request: Request, body: DeviceUnbindBody) -> dict[str, Any]:
    require_client_sign(f"{cfg.API_ROOT}/device/unbind", body_dict(body))
    device_id = (body.deviceId or body.device_id or "").strip()
    if not device_id:
        return fail(400, "缺少 deviceId")

    with db() as conn:
        session = auth_card(request, conn)
        card = str(session["card"])
        cur = conn.execute(
            "DELETE FROM devices WHERE card=? AND device_id=?",
            (card, device_id),
        )
        if cur.rowcount == 0:
            return fail(404, "设备不存在")

        add_hours(conn, card, -cfg.UNBIND_PENALTY_HOURS)
        audit(
            conn,
            action="unbind_device",
            actor=card,
            target=device_id,
            detail={"penaltyHours": cfg.UNBIND_PENALTY_HOURS},
            ip=client_ip(request),
        )
        return ok(
            {
                "deviceId": device_id,
                "penaltyHours": cfg.UNBIND_PENALTY_HOURS,
                **account_profile(conn, card, session["device_id"]),
            },
            "解绑成功",
        )


@router.post("/topup")
def topup(request: Request, body: TopupBody) -> dict[str, Any]:
    ip = client_ip(request)
    rate_limit(f"topup:{ip}", cfg.LOGIN_RATE_LIMIT, cfg.LOGIN_RATE_WINDOW)
    require_client_sign(f"{cfg.API_ROOT}/topup", body_dict(body))
    kami = (body.kami or body.card or "").strip()
    if not kami:
        return fail(400, "请输入充值卡密")

    with db() as conn:
        session = auth_card(request, conn)
        card = str(session["card"])
        top = conn.execute("SELECT * FROM cards WHERE code=?", (kami,)).fetchone()
        if top is None or int(top["enabled"]) != 1:
            audit(conn, action="topup_fail", actor=card, target=kami, detail={"reason": "invalid"}, ip=ip, ok_flag=False)
            return fail(404, "充值卡密无效")
        if top["kind"] != "topup":
            audit(conn, action="topup_fail", actor=card, target=kami, detail={"reason": "not_topup"}, ip=ip, ok_flag=False)
            return fail(400, "这不是充值卡")

        used = conn.execute("SELECT 1 FROM topup_used WHERE code=?", (kami,)).fetchone()
        if used is not None:
            audit(conn, action="topup_fail", actor=card, target=kami, detail={"reason": "used"}, ip=ip, ok_flag=False)
            return fail(409, "充值卡已使用")

        expires = add_hours(conn, card, int(top["hours"]))
        conn.execute(
            "INSERT INTO topup_used(code, used_by, used_at) VALUES (?, ?, ?)",
            (kami, card, to_iso(utcnow())),
        )
        conn.execute("UPDATE cards SET enabled=0 WHERE code=?", (kami,))
        # 同步延长当前会话
        conn.execute(
            "UPDATE sessions SET expires_at=? WHERE card=?",
            (to_iso(expires), card),
        )
        profile = account_profile(conn, card, session["device_id"])
        audit(
            conn,
            action="topup_ok",
            actor=card,
            target=kami,
            detail={"addedHours": int(top["hours"])},
            ip=ip,
        )
        return ok({**profile, "addedHours": int(top["hours"])}, "充值成功")


@router.post("/kwailive/account")
def report_account(request: Request, payload: dict[str, Any]) -> dict[str, Any]:
    require_client_sign(f"{cfg.API_ROOT}/kwailive/account", payload)
    with db() as conn:
        session = auth_card(request, conn)
        audit(
            conn,
            action="report_account",
            actor=str(session["card"]),
            detail={"keys": list(payload.keys())[:20]},
            ip=client_ip(request),
        )
    return ok({"accepted": True})
