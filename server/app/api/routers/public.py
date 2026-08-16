"""公共只读接口：/health、/、/files/*（HTTP 过渡入口的白名单也涵盖这些）。"""
from __future__ import annotations

import time
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

from ...core import config
from ...core.db import db
from ...core.security import rate_limit
from ...core.utils import client_ip, to_iso, utcnow
from ...services.health import deep_health
from ...services.releases import STARTED_AT, highest_release, load_public_config, release_safe_name

router = APIRouter()


@router.get("/health")
def health(deep: int = 0) -> dict[str, Any]:
    """存活探针。默认轻量（老客户端在用）；?deep=1 追加 DB 读写与磁盘余量探测。"""
    uptime = int((utcnow() - STARTED_AT).total_seconds())
    now_ms = int(time.time() * 1000)
    if config.PRODUCTION:
        result: dict[str, Any] = {
            "ok": True,
            "service": "kmxzs-card-server",
            "version": config.SERVER_VERSION,
            "uptimeSec": uptime,
            "serverTimeMs": now_ms,
        }
    else:
        with db() as conn:
            cards = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()["c"]
            accounts = conn.execute("SELECT COUNT(*) AS c FROM accounts").fetchone()["c"]
            cfg = load_public_config(conn)
        result = {
            "ok": True,
            "service": "kmxzs-card-server",
            "version": config.SERVER_VERSION,
            "time": to_iso(utcnow()),
            "serverTimeMs": now_ms,
            "uptimeSec": uptime,
            "seedDemo": config.SEED_DEMO,
            "cards": cards,
            "accounts": accounts,
            "clientVersion": cfg["version"],
            "notice": cfg["notice"],
        }
    if deep:
        result["deep"] = deep_health()
    return result


@router.get("/")
def root() -> dict[str, Any]:
    return {"ok": True, "service": "kmxzs-card-server"}


@router.get("/files/{name}")
def download_release(request: Request, name: str) -> FileResponse:
    rate_limit(f"files:{client_ip(request)}", 30, 60)
    if name == "latest.exe":
        rel = highest_release()
        path = rel[1] if rel else (config.RELEASES_DIR / "latest.exe")
    else:
        release_safe_name(name)
        path = config.RELEASES_DIR / name
    if not path.is_file() or not path.resolve().is_relative_to(config.RELEASES_DIR.resolve()):
        raise HTTPException(status_code=404, detail="file not found")
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename="快马小助手-setup.exe" if name == "latest.exe" else path.name,
        headers={"Cache-Control": "no-store"},
    )
