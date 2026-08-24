"""阶段1：新增 users/channels 与持久化安全表，cards 增加 channel_id

Revision ID: 0002
Revises: 0001
Create Date: 2026-08-16

在已有数据的生产库上可安全执行（幂等）：先 stamp 0001 再 upgrade head。
"""
from __future__ import annotations

from alembic import op
from sqlalchemy import text

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

_NEW_STATEMENTS = [
    """
    CREATE TABLE IF NOT EXISTS channels (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      owner_user_id INTEGER,
      status INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'reseller',
      channel_id INTEGER REFERENCES channels(id),
      card_quota INTEGER NOT NULL DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS rate_limits (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      key TEXT NOT NULL,
      hit_at REAL NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS nonce_seen (
      nonce TEXT PRIMARY KEY,
      seen_at REAL NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS user_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      refresh_jti TEXT NOT NULL UNIQUE,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
]


def _column_names(conn, table: str) -> set[str]:
    return {row[1] for row in conn.execute(text(f"PRAGMA table_info({table})")).fetchall()}


def upgrade() -> None:
    for stmt in _NEW_STATEMENTS:
        op.execute(stmt)
    conn = op.get_bind()
    if "channel_id" not in _column_names(conn, "cards"):
        op.execute(
            "ALTER TABLE cards ADD COLUMN channel_id INTEGER REFERENCES channels(id)"
        )
    op.execute("CREATE INDEX IF NOT EXISTS idx_cards_channel_id ON cards(channel_id)")
    op.execute("CREATE INDEX IF NOT EXISTS idx_rate_limits_key_time ON rate_limits(key, hit_at)")
    op.execute("CREATE INDEX IF NOT EXISTS idx_user_sessions_user ON user_sessions(user_id)")


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS user_sessions")
    op.execute("DROP TABLE IF EXISTS nonce_seen")
    op.execute("DROP TABLE IF EXISTS rate_limits")
    op.execute("DROP TABLE IF EXISTS users")
    op.execute("DROP TABLE IF EXISTS channels")
    # SQLite 删除列需重建表，成本高且易出错；downgrade 保守保留 cards.channel_id 列（数据无损）
