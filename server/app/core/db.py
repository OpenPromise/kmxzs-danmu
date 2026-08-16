"""数据库连接与初始化（含 WAL、持久化的限流/nonce 表、RBAC 新表）。"""
from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from typing import Any, Generator, Optional

from . import config
from .utils import to_iso, utcnow


@contextmanager
def db() -> Generator[sqlite3.Connection, None, None]:
    """打开 SQLite 连接（WAL + 外键），正常退出时提交。"""
    config.DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(config.DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def audit(
    conn: sqlite3.Connection,
    *,
    action: str,
    actor: str = "system",
    target: Optional[str] = None,
    detail: Optional[dict[str, Any]] = None,
    ip: Optional[str] = None,
    ok_flag: bool = True,
) -> None:
    conn.execute(
        """
        INSERT INTO audit_logs(created_at, actor, action, target, detail, ip, ok)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            to_iso(utcnow()),
            actor,
            action,
            target,
            json.dumps(detail or {}, ensure_ascii=False),
            ip,
            1 if ok_flag else 0,
        ),
    )


def get_setting(conn: sqlite3.Connection, key: str, default: str = "") -> str:
    row = conn.execute("SELECT value FROM app_settings WHERE key=?", (key,)).fetchone()
    return str(row["value"]) if row else default


def set_setting(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        """
        INSERT INTO app_settings(key, value, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
        """,
        (key, value, to_iso(utcnow())),
    )


def _add_column_if_missing(conn: sqlite3.Connection, table: str, column_name: str, column_sql: str) -> None:
    cols = [r["name"] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()]
    if column_name not in cols:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column_sql}")


def _create_tables(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS cards (
          code TEXT PRIMARY KEY,
          kind TEXT NOT NULL DEFAULT 'login',
          hours INTEGER NOT NULL DEFAULT 720,
          max_devices INTEGER NOT NULL DEFAULT 1,
          expires_at TEXT,
          enabled INTEGER NOT NULL DEFAULT 1,
          note TEXT,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS accounts (
          card TEXT PRIMARY KEY,
          expires_at TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS devices (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          card TEXT NOT NULL,
          device_id TEXT NOT NULL,
          name TEXT,
          bound_at TEXT NOT NULL,
          UNIQUE(card, device_id)
        );

        CREATE TABLE IF NOT EXISTS sessions (
          token TEXT PRIMARY KEY,
          card TEXT NOT NULL,
          device_id TEXT,
          expires_at TEXT NOT NULL,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS topup_used (
          code TEXT PRIMARY KEY,
          used_by TEXT NOT NULL,
          used_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS audit_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at TEXT NOT NULL,
          actor TEXT NOT NULL,
          action TEXT NOT NULL,
          target TEXT,
          detail TEXT,
          ip TEXT,
          ok INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_devices_card ON devices(card);
        CREATE INDEX IF NOT EXISTS idx_sessions_card ON sessions(card);
        """
    )


def _create_rbac_tables(conn: sqlite3.Connection) -> None:
    conn.executescript(
        f"""
        CREATE TABLE IF NOT EXISTS channels (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          code TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          owner_user_id INTEGER,
          status INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT NOT NULL UNIQUE,
          password_hash TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT 'reseller',
          channel_id INTEGER REFERENCES channels(id),
          card_quota INTEGER NOT NULL DEFAULT 0,
          enabled INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS {config.RATE_LIMIT_TABLE} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          key TEXT NOT NULL,
          hit_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rate_limits_key_time ON {config.RATE_LIMIT_TABLE}(key, hit_at);

        CREATE TABLE IF NOT EXISTS {config.NONCE_TABLE} (
          nonce TEXT PRIMARY KEY,
          seen_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS {config.USER_SESSION_TABLE} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL,
          refresh_jti TEXT NOT NULL UNIQUE,
          expires_at TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_user_sessions_user ON {config.USER_SESSION_TABLE}(user_id);
        """
    )


def init_db() -> None:
    """初始化 schema（幂等）：现有生产表 + 阶段1 新增表 + cards.channel_id 列。"""
    with db() as conn:
        _create_tables(conn)
        _create_rbac_tables(conn)
        # cards.channel_id 外键（可空；旧数据保持 NULL）
        _add_column_if_missing(
            conn, "cards", "channel_id", "channel_id INTEGER REFERENCES channels(id)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_cards_channel_id ON cards(channel_id)"
        )

        # 默认客户端配置（面向终端用户文案，不含运维细节）
        default_notice = "欢迎使用直播小助手"
        defaults = {
            "notice": default_notice,
            "client_version": os.getenv("KMXZS_CLIENT_VERSION", "1.0.0"),
            "download_url": os.getenv("KMXZS_DOWNLOAD_URL", ""),
            "force_update": os.getenv("KMXZS_FORCE_UPDATE", "0"),
            "min_client_version": os.getenv("KMXZS_MIN_CLIENT_VERSION", "1.0.0"),
        }
        now = to_iso(utcnow())
        for k, v in defaults.items():
            if conn.execute("SELECT 1 FROM app_settings WHERE key=?", (k,)).fetchone() is None:
                conn.execute(
                    "INSERT INTO app_settings(key, value, updated_at) VALUES (?, ?, ?)",
                    (k, v, now),
                )

        # 迁移旧版公告文案
        notice_row = conn.execute(
            "SELECT value FROM app_settings WHERE key='notice'"
        ).fetchone()
        if notice_row and any(
            x in str(notice_row["value"])
            for x in (
                "Docker",
                "演示卡",
                "本地联调",
                "卡密服务已启用",
                "快码小助手",
            )
        ):
            set_setting(conn, "notice", default_notice)

        if config.SEED_DEMO:
            row = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()
            if int(row["c"]) == 0:
                now = to_iso(utcnow())
                seeds = [
                    ("KMXZS-DEMO-30D", "login", 24 * 30, config.DEFAULT_MAX_DEVICES, "演示登录卡 30 天"),
                    ("KMXZS-DEMO-7D", "login", 24 * 7, config.DEFAULT_MAX_DEVICES, "演示登录卡 7 天"),
                    ("KMXZS-TOPUP-24H", "topup", 24, 0, "演示充值卡 +24 小时"),
                    ("KMXZS-TOPUP-7D", "topup", 24 * 7, 0, "演示充值卡 +7 天"),
                ]
                for code, kind, hours, max_devices, note in seeds:
                    conn.execute(
                        """
                        INSERT INTO cards(code, kind, hours, max_devices, expires_at, enabled, note, created_at)
                        VALUES (?, ?, ?, ?, NULL, 1, ?, ?)
                        """,
                        (code, kind, hours, max_devices, note, now),
                    )
                audit(conn, action="seed_demo", detail={"count": len(seeds)})
