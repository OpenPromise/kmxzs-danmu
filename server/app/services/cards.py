"""卡密 / 账号核心业务逻辑。"""
from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta
from typing import Any, Optional

from ..core.config import DEFAULT_MAX_DEVICES
from ..core.utils import parse_dt, to_iso, utcnow


def ensure_account(conn: sqlite3.Connection, card: str, hours: int) -> datetime:
    now = utcnow()
    acc = conn.execute("SELECT * FROM accounts WHERE card=?", (card,)).fetchone()
    if acc is None:
        expires = now + timedelta(hours=hours)
        conn.execute(
            """
            INSERT INTO accounts(card, expires_at, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            (card, to_iso(expires), to_iso(now), to_iso(now)),
        )
        return expires

    expires = parse_dt(acc["expires_at"]) or now
    conn.execute(
        "UPDATE accounts SET updated_at=? WHERE card=?",
        (to_iso(now), card),
    )
    return expires


def add_hours(conn: sqlite3.Connection, card: str, hours: int) -> datetime:
    now = utcnow()
    acc = conn.execute("SELECT * FROM accounts WHERE card=?", (card,)).fetchone()
    base = now
    if acc is not None:
        old = parse_dt(acc["expires_at"])
        if old and old > now:
            base = old
    expires = base + timedelta(hours=hours)
    if acc is None:
        conn.execute(
            """
            INSERT INTO accounts(card, expires_at, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            (card, to_iso(expires), to_iso(now), to_iso(now)),
        )
    else:
        conn.execute(
            "UPDATE accounts SET expires_at=?, updated_at=? WHERE card=?",
            (to_iso(expires), to_iso(now), card),
        )
    return expires


def account_profile(
    conn: sqlite3.Connection, card: str, device_id: Optional[str] = None
) -> dict[str, Any]:
    acc = conn.execute("SELECT * FROM accounts WHERE card=?", (card,)).fetchone()
    card_row = conn.execute("SELECT * FROM cards WHERE code=?", (card,)).fetchone()
    device_count = conn.execute(
        "SELECT COUNT(*) AS c FROM devices WHERE card=?", (card,)
    ).fetchone()["c"]
    expires = parse_dt(acc["expires_at"]) if acc else None
    remaining = 0
    if expires:
        remaining = max(0, int((expires - utcnow()).total_seconds() // 3600))
    return {
        "card": card,
        "expires": to_iso(expires) if expires else None,
        "expire": to_iso(expires) if expires else None,
        "remainingHours": remaining,
        "deviceId": device_id,
        "deviceCount": int(device_count),
        "maxDevices": int(card_row["max_devices"]) if card_row else DEFAULT_MAX_DEVICES,
        "enabled": bool(card_row and int(card_row["enabled"]) == 1),
    }
