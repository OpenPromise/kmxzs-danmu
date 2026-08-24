"""安全核心：HMAC 客户端签名、SQLite 持久化 nonce/限流、Basic 后台认证、JWT + argon2。"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
import threading
import time
from typing import Any, Mapping, Optional

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import HTTPException, Request

from . import config
from .db import db
from .utils import client_ip, fail

# 并发保护：SQLite 写操作本身串行，但"读-判断-写"窗口仍需要锁避免同窗口放行两个请求
_rate_lock = threading.Lock()
_nonce_lock = threading.Lock()

_password_hasher = PasswordHasher()


# ---------------------------------------------------------------------------
# 密钥强度 / 后台凭据解析
# ---------------------------------------------------------------------------
def is_weak_api_secret(secret: str) -> bool:
    s = (secret or "").strip()
    if s in config.WEAK_API_SECRETS:
        return True
    if len(s) < 16:
        return True
    if s.startswith("请替换"):
        return True
    return False


def resolve_admin_token() -> str:
    env_token = (os.getenv("KMXZS_ADMIN_TOKEN") or "").strip()
    if env_token and env_token not in config.WEAK_TOKENS:
        return env_token

    config.TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    if config.TOKEN_FILE.exists():
        saved = config.TOKEN_FILE.read_text(encoding="utf-8").strip()
        if saved and saved not in config.WEAK_TOKENS:
            return saved

    token = secrets.token_urlsafe(24)
    config.TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    return token


def resolve_admin_basic_pass() -> str:
    env = (os.getenv("KMXZS_ADMIN_PASSWORD") or "").strip()
    if env and env not in config.WEAK_TOKENS and len(env) >= 8:
        return env
    config.ADMIN_BASIC_FILE.parent.mkdir(parents=True, exist_ok=True)
    if config.ADMIN_BASIC_FILE.exists():
        saved = config.ADMIN_BASIC_FILE.read_text(encoding="utf-8").strip()
        if saved:
            return saved
    pwd = secrets.token_urlsafe(12)
    config.ADMIN_BASIC_FILE.write_text(pwd + "\n", encoding="utf-8")
    return pwd


def _check_admin_basic(request: Request) -> bool:
    if not config.ADMIN_BASIC_PASS:
        return False
    header = request.headers.get("Authorization") or ""
    if not header.lower().startswith("basic "):
        return False
    try:
        raw = base64.b64decode(header.split(" ", 1)[1].strip()).decode("utf-8")
    except Exception:
        return False
    user, _, pwd = raw.partition(":")
    user_ok = hmac.compare_digest(
        user.encode("utf-8").ljust(64, b"\0")[:64],
        config.ADMIN_BASIC_USER.encode("utf-8").ljust(64, b"\0")[:64],
    ) and len(user) == len(config.ADMIN_BASIC_USER)
    pwd_ok = hmac.compare_digest(
        pwd.encode("utf-8").ljust(128, b"\0")[:128],
        config.ADMIN_BASIC_PASS.encode("utf-8").ljust(128, b"\0")[:128],
    ) and len(pwd) == len(config.ADMIN_BASIC_PASS)
    return user_ok and pwd_ok


# ---------------------------------------------------------------------------
# 限流（SQLite 持久化 + TTL 清理）
# ---------------------------------------------------------------------------
def rate_limit(key: str, limit: int, window_sec: int) -> None:
    now = time.time()
    cutoff = now - window_sec
    with _rate_lock:
        with db() as conn:
            conn.execute(
                f"DELETE FROM {config.RATE_LIMIT_TABLE} WHERE hit_at < ?", (cutoff,)
            )
            row = conn.execute(
                f"SELECT COUNT(*) AS c FROM {config.RATE_LIMIT_TABLE} WHERE key=? AND hit_at > ?",
                (key, cutoff),
            ).fetchone()
            if int(row["c"]) >= limit:
                raise HTTPException(status_code=429, detail=fail(429, "请求过于频繁，请稍后再试"))
            conn.execute(
                f"INSERT INTO {config.RATE_LIMIT_TABLE}(key, hit_at) VALUES (?, ?)",
                (key, now),
            )


# ---------------------------------------------------------------------------
# 客户端 HMAC 签名
# ---------------------------------------------------------------------------
def canonical_body(data: Mapping[str, Any]) -> str:
    skip = {"sign", "timestamp", "nonce", "deviceId", "device_id",
            # 阶段3：legacyDeviceId 是设备指纹迁移的辅助字段，签名只覆盖主 deviceId
            "legacyDeviceId", "legacy_device_id"}
    parts: list[str] = []
    for k in sorted(data.keys()):
        if k in skip:
            continue
        v = data[k]
        if v is None:
            continue
        parts.append(f"{k}={v}")
    return "&".join(parts)


def make_sign(path: str, timestamp: int, nonce: str, device_id: str, data: Mapping[str, Any]) -> str:
    msg = f"{timestamp}\n{nonce}\n{device_id}\n{path}\n{canonical_body(data)}"
    return hmac.new(config.API_SECRET.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def remember_nonce(nonce: str) -> None:
    """记录一次性 nonce（SQLite 持久化 + TTL 清理），重放直接拒绝。"""
    now = time.time()
    cutoff = now - config.SIGN_MAX_SKEW_MS / 1000.0 - 60
    with _nonce_lock:
        with db() as conn:
            conn.execute(
                f"DELETE FROM {config.NONCE_TABLE} WHERE seen_at < ?", (cutoff,)
            )
            if conn.execute(
                f"SELECT 1 FROM {config.NONCE_TABLE} WHERE nonce=?", (nonce,)
            ).fetchone():
                raise HTTPException(status_code=401, detail=fail(401, "请求已失效，请重试"))
            conn.execute(
                f"INSERT INTO {config.NONCE_TABLE}(nonce, seen_at) VALUES (?, ?)",
                (nonce, now),
            )


def require_client_sign(path: str, data: Mapping[str, Any]) -> None:
    """校验客户端 HMAC；未配置密钥且非生产则跳过（本地联调）。"""
    if not config.REQUIRE_SIGN:
        return
    if not config.API_SECRET:
        raise HTTPException(status_code=500, detail=fail(500, "服务端未配置 KMXZS_API_SECRET"))

    ts = data.get("timestamp")
    nonce = str(data.get("nonce") or "").strip()
    device_id = str(data.get("deviceId") or data.get("device_id") or "").strip()
    sign = str(data.get("sign") or "").strip().lower()
    if ts is None or not nonce or not device_id or not sign:
        raise HTTPException(status_code=401, detail=fail(401, "缺少签名参数"))
    try:
        ts_i = int(ts)
    except (TypeError, ValueError):
        raise HTTPException(status_code=401, detail=fail(401, "时间戳无效")) from None

    now_ms = int(time.time() * 1000)
    if abs(now_ms - ts_i) > config.SIGN_MAX_SKEW_MS:
        raise HTTPException(status_code=401, detail=fail(401, "请求已过期，请校准系统时间"))

    remember_nonce(nonce)
    expect = make_sign(path, ts_i, nonce, device_id, data)
    if not secrets.compare_digest(expect, sign):
        raise HTTPException(status_code=401, detail=fail(401, "签名校验失败"))


# ---------------------------------------------------------------------------
# 过渡期后台鉴权（Basic 或 admin token）
# ---------------------------------------------------------------------------
def require_admin(request: Request, x_admin_token: Optional[str]) -> None:
    rate_limit(f"admin:{client_ip(request)}", config.ADMIN_RATE_LIMIT, config.ADMIN_RATE_WINDOW)
    if getattr(request.state, "admin_basic_ok", False):
        return
    provided = (x_admin_token or "").strip()
    expected = config.ADMIN_TOKEN or ""
    if not provided or len(provided) != len(expected):
        raise HTTPException(status_code=401, detail=fail(401, "admin token invalid"))
    if not secrets.compare_digest(provided, expected):
        raise HTTPException(status_code=401, detail=fail(401, "admin token invalid"))


# ---------------------------------------------------------------------------
# 阶段1：argon2 密码哈希
# ---------------------------------------------------------------------------
def hash_password(password: str) -> str:
    return _password_hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _password_hasher.verify(password_hash, password)
    except VerificationError:
        return False
    except Exception:
        return False


# ---------------------------------------------------------------------------
# 阶段1：JWT（access + refresh）
# ---------------------------------------------------------------------------
_jwt_secret_cache: Optional[str] = None
_jwt_secret_lock = threading.Lock()


def resolve_jwt_secret() -> str:
    """JWT 签名密钥：优先环境变量，其次持久化文件（跨重启稳定）。"""
    global _jwt_secret_cache
    if _jwt_secret_cache:
        return _jwt_secret_cache
    with _jwt_secret_lock:
        if _jwt_secret_cache:
            return _jwt_secret_cache
        env = (os.getenv("KMXZS_JWT_SECRET") or "").strip()
        if env and len(env) >= 16:
            _jwt_secret_cache = env
            return env
        config.JWT_SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
        if config.JWT_SECRET_FILE.exists():
            saved = config.JWT_SECRET_FILE.read_text(encoding="utf-8").strip()
            if saved and len(saved) >= 16:
                _jwt_secret_cache = saved
                return saved
        secret = secrets.token_urlsafe(48)
        config.JWT_SECRET_FILE.write_text(secret + "\n", encoding="utf-8")
        _jwt_secret_cache = secret
        return secret


def create_access_token(user_id: int, username: str, role: str, channel_id: Optional[int]) -> str:
    now = int(time.time())
    payload = {
        "sub": str(user_id),
        "username": username,
        "role": role,
        "channel_id": channel_id,
        "type": "access",
        "jti": secrets.token_urlsafe(16),
        "iat": now,
        "exp": now + config.ACCESS_TOKEN_MINUTES * 60,
    }
    import jwt as pyjwt
    return pyjwt.encode(payload, resolve_jwt_secret(), algorithm=config.JWT_ALG)


def create_refresh_token(user_id: int, jti: str) -> str:
    now = int(time.time())
    payload = {
        "sub": str(user_id),
        "type": "refresh",
        "jti": jti,
        "iat": now,
        "exp": now + config.REFRESH_TOKEN_DAYS * 86400,
    }
    import jwt as pyjwt
    return pyjwt.encode(payload, resolve_jwt_secret(), algorithm=config.JWT_ALG)


def decode_token(token: str) -> Optional[dict[str, Any]]:
    if not token:
        return None
    try:
        import jwt as pyjwt
        return pyjwt.decode(token, resolve_jwt_secret(), algorithms=[config.JWT_ALG])
    except Exception:
        return None
