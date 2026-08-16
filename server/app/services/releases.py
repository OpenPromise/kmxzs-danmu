"""客户端配置 / 安装包版本服务。"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import HTTPException, Request

from ..core import config
from ..core.db import get_setting
from ..core.utils import fail, public_origin
from .signing import cached_signature

STARTED_AT = datetime.now(timezone.utc)


def _version_tuple(ver: str) -> tuple[int, int, int]:
    a, b, c = ver.split(".")
    return int(a), int(b), int(c)


def highest_release() -> tuple[str, Path] | None:
    """磁盘上版本号最高的安装包（所有旧客户端都指向这一份）。"""
    if not config.RELEASES_DIR.exists():
        return None
    best: tuple[tuple[int, int, int], Path, str] | None = None
    for p in config.RELEASES_DIR.glob("zbxzs-setup-*.exe"):
        m = re.fullmatch(r"zbxzs-setup-(\d+\.\d+\.\d+)\.exe", p.name, flags=re.I)
        if not m or not p.is_file():
            continue
        ver = m.group(1)
        key = (_version_tuple(ver), p, ver)
        if best is None or key[0] > best[0]:
            best = key
    if best:
        return best[2], best[1]
    latest = config.RELEASES_DIR / "latest.exe"
    if latest.is_file():
        return "", latest
    return None


def latest_download_url(request: Request | None, version: str) -> str:
    if request is not None:
        base = f"{public_origin(request)}/files/latest.exe"
    else:
        base = "/files/latest.exe"
    ver = (version or "").strip()
    if ver:
        return f"{base}?v={ver}"
    return base


def load_public_config(
    conn, request: Request | None = None
) -> dict[str, Any]:
    notice = get_setting(conn, "notice", "欢迎使用直播小助手")
    stored_ver = get_setting(conn, "client_version", "1.0.0")
    rel = highest_release()
    version = (rel[0] if rel and rel[0] else stored_ver)
    download = latest_download_url(request, version)
    size = 0
    if rel:
        try:
            size = int(rel[1].stat().st_size)
        except OSError:
            size = 0
    force = get_setting(conn, "force_update", "0") in ("1", "true", "True", "yes")
    min_version = get_setting(conn, "min_client_version", "1.0.0")

    # 安装包防投毒：下发给客户端用于校验下载内容。旧字段保持不变，老客户端忽略新字段。
    download_sha256 = ""
    download_sig = ""
    if rel:
        try:
            download_sha256, download_sig = cached_signature(rel[1])
        except Exception:
            download_sha256, download_sig = "", ""
    return {
        "notice": notice,
        "version": version,
        "download": download,
        "downloadSize": size,
        "downloadSha256": download_sha256,
        "downloadSig": download_sig,
        "force": force,
        "minVersion": min_version,
        "serverVersion": config.SERVER_VERSION,
        "seedDemo": config.SEED_DEMO,
    }


def release_safe_name(name: str) -> str:
    base = Path(name or "").name
    if not re.fullmatch(r"[A-Za-z0-9._+\-]+\.exe", base, flags=re.I):
        raise HTTPException(status_code=400, detail=fail(400, "只允许上传 .exe 安装包"))
    if base.startswith("."):
        raise HTTPException(status_code=400, detail=fail(400, "非法文件名"))
    return base
