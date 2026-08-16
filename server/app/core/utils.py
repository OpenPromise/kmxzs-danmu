"""通用工具：时间、统一响应、请求来源。"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping, Optional

from fastapi import Request
from pydantic import BaseModel

from . import config


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def to_iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat()


def parse_dt(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    return datetime.fromisoformat(value)


def ok(data: Any = None, message: str = "ok", code: int = 0) -> dict[str, Any]:
    return {"code": code, "message": message, "msg": message, "data": data}


def fail(code: int, message: str) -> dict[str, Any]:
    return {"code": code, "message": message, "msg": message, "data": None}


def body_dict(model: BaseModel | Mapping[str, Any] | None) -> dict[str, Any]:
    if model is None:
        return {}
    if isinstance(model, BaseModel):
        return model.model_dump()
    return dict(model)


def client_ip(request: Request) -> str:
    """仅在明确信任反代时才读 X-Forwarded-For，避免客户端伪造绕过限流。"""
    if config.TRUST_PROXY:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "unknown"


def public_origin(request: Request) -> str:
    """对外公开的 origin（http(s)://host），用于拼下载地址。"""
    host = (request.headers.get("host") or "").strip()
    if config.TRUST_PROXY:
        host = (request.headers.get("x-forwarded-host") or host).split(",")[0].strip()
    proto = request.url.scheme or "http"
    if config.TRUST_PROXY:
        proto = (request.headers.get("x-forwarded-proto") or proto).split(",")[0].strip()
    if not host:
        host = "127.0.0.1:18080"
    return f"{proto}://{host}".rstrip("/")


def effective_scheme(request: Request) -> str:
    """请求实际使用的传输层协议（考虑可信反代头）。"""
    if config.TRUST_PROXY:
        proto = request.headers.get("x-forwarded-proto")
        if proto:
            return proto.split(",")[0].strip().lower()
    return (request.url.scheme or "http").lower()
