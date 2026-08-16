"""阶段1：JWT 认证、超管引导、渠道/代理管理、发卡配额。"""
from __future__ import annotations

import secrets
import sqlite3
from datetime import timedelta
from typing import Any, Optional

from fastapi import HTTPException

from ..core import config
from ..core.db import db
from ..core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    verify_password,
)
from ..core.utils import fail, ok, parse_dt, to_iso, utcnow


# ---------------------------------------------------------------------------
# 配额
# ---------------------------------------------------------------------------
def quota_used(conn: sqlite3.Connection, channel_id: Optional[int]) -> int:
    """已占用配额 = 渠道下启用的登录卡数量（含快照口径，代理建卡即占用）。"""
    if not channel_id:
        return 0
    row = conn.execute(
        "SELECT COUNT(*) AS c FROM cards WHERE channel_id=? AND kind='login' AND enabled=1",
        (channel_id,),
    ).fetchone()
    return int(row["c"])


# ---------------------------------------------------------------------------
# 超管引导
# ---------------------------------------------------------------------------
def ensure_superadmin() -> tuple[str, str]:
    """确保至少存在一个 superadmin；返回 (username, password)。"""
    with db() as conn:
        row = conn.execute(
            "SELECT username FROM users WHERE role='superadmin' ORDER BY id ASC LIMIT 1"
        ).fetchone()
        if row is not None:
            return str(row["username"]), ""
        username = config.SUPERADMIN_USER
        password = config.SUPERADMIN_PASSWORD
        if not password:
            password = secrets.token_urlsafe(16)
        config.SUPERADMIN_FILE.parent.mkdir(parents=True, exist_ok=True)
        config.SUPERADMIN_FILE.write_text(f"{username}\n{password}\n", encoding="utf-8")
        conn.execute(
            """
            INSERT INTO users(username, password_hash, role, channel_id, card_quota, enabled, created_at)
            VALUES (?, ?, 'superadmin', NULL, 0, 1, ?)
            """,
            (username, hash_password(password), to_iso(utcnow())),
        )
        return username, password


# ---------------------------------------------------------------------------
# 登录 / 刷新 / 登出
# ---------------------------------------------------------------------------
def _token_payload(conn: sqlite3.Connection, user: sqlite3.Row, access: str, refresh: str) -> dict[str, Any]:
    used = quota_used(conn, user["channel_id"])
    return {
        "access_token": access,
        "refresh_token": refresh,
        "token_type": "bearer",
        "user": {
            "id": user["id"],
            "username": user["username"],
            "role": user["role"],
            "channel_id": user["channel_id"],
            "card_quota": int(user["card_quota"] or 0),
            "enabled": bool(int(user["enabled"] or 1) == 1),
            "quota_used": used,
            "created_at": user["created_at"],
        },
    }


def _new_refresh_jti(conn: sqlite3.Connection, user_id: int) -> str:
    jti = secrets.token_urlsafe(24)
    exp = utcnow() + timedelta(days=config.REFRESH_TOKEN_DAYS)
    conn.execute(
        f"INSERT INTO {config.USER_SESSION_TABLE}(user_id, refresh_jti, expires_at, created_at) VALUES (?, ?, ?, ?)",
        (user_id, jti, to_iso(exp), to_iso(utcnow())),
    )
    return jti


def login(username: str, password: str) -> dict[str, Any]:
    with db() as conn:
        user = conn.execute(
            "SELECT * FROM users WHERE username=?", (username,)
        ).fetchone()
        if (
            user is None
            or int(user["enabled"]) != 1
            or not verify_password(user["password_hash"], password)
        ):
            raise HTTPException(status_code=401, detail=fail(401, "用户名或密码错误"))
        jti = _new_refresh_jti(conn, int(user["id"]))
        access = create_access_token(
            int(user["id"]), user["username"], user["role"], user["channel_id"]
        )
        refresh = create_refresh_token(int(user["id"]), jti)
        return ok(_token_payload(conn, user, access, refresh), "登录成功")


def refresh(refresh_token: str) -> dict[str, Any]:
    payload = decode_token(refresh_token)
    if not payload or payload.get("type") != "refresh" or not payload.get("jti"):
        raise HTTPException(status_code=401, detail=fail(401, "刷新令牌无效"))
    jti = str(payload["jti"])
    with db() as conn:
        row = conn.execute(
            f"SELECT * FROM {config.USER_SESSION_TABLE} WHERE refresh_jti=?", (jti,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=401, detail=fail(401, "刷新令牌已失效"))
        exp = parse_dt(row["expires_at"])
        if exp and exp < utcnow():
            conn.execute(
                f"DELETE FROM {config.USER_SESSION_TABLE} WHERE refresh_jti=?", (jti,)
            )
            raise HTTPException(status_code=401, detail=fail(401, "刷新令牌已过期"))
        user = conn.execute(
            "SELECT * FROM users WHERE id=?", (row["user_id"],)
        ).fetchone()
        if user is None or int(user["enabled"]) != 1:
            raise HTTPException(status_code=401, detail=fail(401, "账号已停用"))
        # 轮换刷新令牌
        conn.execute(
            f"DELETE FROM {config.USER_SESSION_TABLE} WHERE refresh_jti=?", (jti,)
        )
        new_jti = _new_refresh_jti(conn, int(user["id"]))
        access = create_access_token(
            int(user["id"]), user["username"], user["role"], user["channel_id"]
        )
        refresh = create_refresh_token(int(user["id"]), new_jti)
        return ok(_token_payload(conn, user, access, refresh), "刷新成功")


def logout(refresh_token: str) -> dict[str, Any]:
    payload = decode_token(refresh_token)
    if payload and payload.get("type") == "refresh" and payload.get("jti"):
        with db() as conn:
            conn.execute(
                f"DELETE FROM {config.USER_SESSION_TABLE} WHERE refresh_jti=?",
                (payload["jti"],),
            )
    return ok({"loggedOut": True})


# ---------------------------------------------------------------------------
# 渠道 / 代理管理（超管）
# ---------------------------------------------------------------------------
def create_channel(code: str, name: str) -> dict[str, Any]:
    code = (code or "").strip()
    name = (name or "").strip()
    if not code or not name:
        raise HTTPException(status_code=400, detail=fail(400, "渠道编码与名称不能为空"))
    with db() as conn:
        if conn.execute("SELECT 1 FROM channels WHERE code=?", (code,)).fetchone():
            raise HTTPException(status_code=409, detail=fail(409, "渠道编码已存在"))
        cur = conn.execute(
            "INSERT INTO channels(code, name, owner_user_id, status, created_at) VALUES (?, ?, NULL, 1, ?)",
            (code, name, to_iso(utcnow())),
        )
        return {"id": cur.lastrowid, "code": code, "name": name, "status": 1}


def create_user(
    username: str,
    password: str,
    channel_id: Optional[int] = None,
    card_quota: int = 0,
    role: str = "reseller",
) -> dict[str, Any]:
    username = (username or "").strip()
    if len(username) < 3:
        raise HTTPException(status_code=400, detail=fail(400, "用户名至少 3 个字符"))
    if len(password or "") < 8:
        raise HTTPException(status_code=400, detail=fail(400, "密码至少 8 个字符"))
    if role not in ("superadmin", "reseller"):
        raise HTTPException(status_code=400, detail=fail(400, "角色不合法"))
    with db() as conn:
        if conn.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
            raise HTTPException(status_code=409, detail=fail(409, "用户名已存在"))
        if channel_id:
            ch = conn.execute(
                "SELECT 1 FROM channels WHERE id=? AND status=1", (channel_id,)
            ).fetchone()
            if not ch:
                raise HTTPException(status_code=400, detail=fail(400, "渠道不存在或已停用"))
        cur = conn.execute(
            """
            INSERT INTO users(username, password_hash, role, channel_id, card_quota, enabled, created_at)
            VALUES (?, ?, ?, ?, ?, 1, ?)
            """,
            (username, hash_password(password), role, channel_id, max(0, int(card_quota)), to_iso(utcnow())),
        )
        return {
            "id": cur.lastrowid,
            "username": username,
            "role": role,
            "channel_id": channel_id,
            "card_quota": max(0, int(card_quota)),
            "enabled": True,
        }
