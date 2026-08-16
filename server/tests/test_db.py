"""SQLite WAL、阶段1 新表与持久化安全表。"""
from __future__ import annotations

from app.core import config
from app.core.db import db

REQUIRED_TABLES = {"cards", "accounts", "devices", "sessions", "topup_used", "audit_logs", "app_settings"}
RBAC_TABLES = {"users", "channels", "rate_limits", "nonce_seen", "user_sessions"}


def test_wal_enabled(client):
    with db() as conn:
        mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert str(mode).lower() == "wal"


def test_all_tables_present(client):
    with db() as conn:
        tables = {r["name"] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    assert REQUIRED_TABLES <= tables
    assert RBAC_TABLES <= tables


def test_cards_has_channel_id(client):
    with db() as conn:
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(cards)").fetchall()}
    assert "channel_id" in cols


def test_superadmin_created_on_startup(client):
    with db() as conn:
        row = conn.execute("SELECT username, role, enabled FROM users WHERE role='superadmin'").fetchone()
    assert row is not None
    assert row["username"] == "superadmin"
    assert int(row["enabled"]) == 1


def test_demo_cards_seeded(client):
    with db() as conn:
        total = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()["c"]
    assert total >= 4
