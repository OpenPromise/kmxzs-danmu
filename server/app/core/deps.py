"""FastAPI 依赖注入：客户端会话鉴权、JWT 用户鉴权、角色控制。"""
from __future__ import annotations

import sqlite3
from typing import Optional

from fastapi import Depends, Header, HTTPException

from .security import decode_token
from .utils import fail, parse_dt, utcnow


# ---------------------------------------------------------------------------
# 客户端（卡密）会话
# ---------------------------------------------------------------------------
def get_session(conn: sqlite3.Connection, token: Optional[str]) -> Optional[sqlite3.Row]:
    if not token:
        return None
    token = token.removeprefix("Bearer ").strip()
    row = conn.execute("SELECT * FROM sessions WHERE token=?", (token,)).fetchone()
    if not row:
        return None
    exp = parse_dt(row["expires_at"])
    if exp and exp < utcnow():
        conn.execute("DELETE FROM sessions WHERE token=?", (token,))
        return None
    return row


def auth_card(request, conn: sqlite3.Connection) -> sqlite3.Row:
    auth = request.headers.get("Authorization")
    token = request.headers.get("token") or auth
    session = get_session(conn, token)
    if not session:
        raise HTTPException(status_code=401, detail=fail(401, "未登录或 token 失效"))

    card = str(session["card"])
    row = conn.execute("SELECT * FROM cards WHERE code=?", (card,)).fetchone()
    if row is None or int(row["enabled"]) != 1:
        conn.execute("DELETE FROM sessions WHERE card=?", (card,))
        raise HTTPException(status_code=401, detail=fail(401, "卡密已停用"))

    acc = conn.execute("SELECT * FROM accounts WHERE card=?", (card,)).fetchone()
    if acc is None:
        raise HTTPException(status_code=401, detail=fail(401, "账号不存在"))
    exp = parse_dt(acc["expires_at"])
    if exp and exp < utcnow():
        conn.execute("DELETE FROM sessions WHERE card=?", (card,))
        raise HTTPException(status_code=401, detail=fail(401, "账号已过期，请充值"))

    device_id = str(session["device_id"] or "")
    if device_id:
        bound = conn.execute(
            "SELECT 1 FROM devices WHERE card=? AND device_id=?",
            (card, device_id),
        ).fetchone()
        if bound is None:
            conn.execute("DELETE FROM sessions WHERE token=?", (session["token"],))
            raise HTTPException(status_code=401, detail=fail(401, "设备未绑定或已解绑"))
    return session


# ---------------------------------------------------------------------------
# 阶段1：管理端 / 分销代理 JWT
# ---------------------------------------------------------------------------
def get_current_user(
    authorization: Optional[str] = Header(default=None),
) -> sqlite3.Row:
    """解析 Bearer access token，返回 users 行；校验启用状态。"""
    token = (authorization or "").strip()
    if token.lower().startswith("bearer "):
        token = token[7:].strip()
    payload = decode_token(token)
    if not payload or payload.get("type") != "access":
        raise HTTPException(status_code=401, detail=fail(401, "未登录或 token 失效"))
    from .db import db

    with db() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE id=?", (int(payload["sub"]),)
        ).fetchone()
        if row is None or int(row["enabled"]) != 1:
            raise HTTPException(status_code=401, detail=fail(401, "账号已停用"))
        return row


def require_superadmin(user=Depends(get_current_user)) -> sqlite3.Row:
    if user["role"] != "superadmin":
        raise HTTPException(status_code=403, detail=fail(403, "需要超管权限"))
    return user


def require_reseller(user=Depends(get_current_user)) -> sqlite3.Row:
    if user["role"] != "reseller":
        raise HTTPException(status_code=403, detail=fail(403, "需要代理权限"))
    if not user["channel_id"]:
        raise HTTPException(status_code=403, detail=fail(403, "代理未绑定渠道"))
    from .db import db

    with db() as conn:
        ch = conn.execute(
            "SELECT status FROM channels WHERE id=?", (user["channel_id"],)
        ).fetchone()
        if not ch or int(ch["status"]) != 1:
            raise HTTPException(status_code=403, detail=fail(403, "渠道已停用"))
    return user
