"""深度健康检查：DB 可读写 + 磁盘剩余空间，供 /health?deep=1 使用。

默认 /health 保持轻量（老客户端每 10 分钟轮询），运维监控可加 deep=1
做一次真实读写与磁盘余量探测。
"""
from __future__ import annotations

import shutil
from typing import Any

from ..core import config
from ..core.db import db, get_setting, set_setting
from ..core.utils import to_iso, utcnow

_PROBE_KEY = "health_probe"


def deep_health() -> dict[str, Any]:
    """探测 DB 读/写与磁盘剩余空间，任何异常都折叠进返回结构而非抛出。"""
    probe_value = to_iso(utcnow())
    db_result: dict[str, Any] = {
        "readable": False,
        "writable": False,
        "integrity": "unknown",
    }
    try:
        with db() as conn:
            db_result["readable"] = conn.execute("SELECT 1").fetchone() is not None
            set_setting(conn, _PROBE_KEY, probe_value)
            db_result["writable"] = get_setting(conn, _PROBE_KEY, "") == probe_value
            integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
            db_result["integrity"] = integrity if integrity == "ok" else f"corrupt:{integrity}"
    except Exception as e:  # noqa: BLE001 - 探针必须返回信息而不是把 /health 打挂
        db_result["error"] = f"{type(e).__name__}: {e}"

    disk_result: dict[str, Any] = {"path": str(config.DB_PATH.parent)}
    try:
        usage = shutil.disk_usage(config.DB_PATH.parent)
        disk_result["totalBytes"] = usage.total
        disk_result["freeBytes"] = usage.free
        disk_result["freePercent"] = (
            round(usage.free / usage.total * 100, 2) if usage.total else 0.0
        )
    except Exception as e:  # noqa: BLE001
        disk_result["error"] = f"{type(e).__name__}: {e}"

    return {"db": db_result, "disk": disk_result}
