from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sqlite3
import threading
import time
import uuid
from collections import defaultdict, deque
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Deque, Generator, Mapping, Optional

from fastapi import FastAPI, File, Form, Header, HTTPException, Query, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

API_ROOT = "/api/user/1009/flutter/1.0.2"
DB_PATH = Path(os.getenv("KMXZS_DB", "/data/kmxzs.db"))
TOKEN_FILE = Path(os.getenv("KMXZS_ADMIN_TOKEN_FILE", "/data/admin_token.txt"))
WEAK_TOKENS = {"kmxzs-admin-local", "admin", "password", "123456", ""}
WEAK_API_SECRETS = {
    "",
    "请替换为openssl_rand_hex_32的结果",
    "请替换为至少32位随机字符串",
    "change-me",
    "secret",
    "test-secret-for-config-check-only-32ch",
}
DEFAULT_MAX_DEVICES = int(os.getenv("KMXZS_MAX_DEVICES", "1"))
UNBIND_PENALTY_HOURS = int(os.getenv("KMXZS_UNBIND_PENALTY_HOURS", "12"))
SEED_DEMO = os.getenv("KMXZS_SEED_DEMO", "1") == "1"
PRODUCTION = os.getenv("KMXZS_PRODUCTION", "0") == "1"
API_SECRET = (os.getenv("KMXZS_API_SECRET") or "").strip()
TRUST_PROXY = os.getenv("KMXZS_TRUST_PROXY", "0") == "1"
REQUIRE_SIGN = (
    PRODUCTION
    or bool(API_SECRET)
    or os.getenv("KMXZS_REQUIRE_SIGN", "0") == "1"
)
SIGN_MAX_SKEW_MS = int(os.getenv("KMXZS_SIGN_MAX_SKEW_MS", "300000"))
LOGIN_RATE_LIMIT = int(os.getenv("KMXZS_LOGIN_RATE_LIMIT", "20"))
LOGIN_RATE_WINDOW = int(os.getenv("KMXZS_LOGIN_RATE_WINDOW", "900"))
ADMIN_RATE_LIMIT = int(os.getenv("KMXZS_ADMIN_RATE_LIMIT", "120"))
ADMIN_RATE_WINDOW = int(os.getenv("KMXZS_ADMIN_RATE_WINDOW", "60"))
_cors_default = "*" if not PRODUCTION else ""
CORS_ORIGINS = [
    o.strip()
    for o in os.getenv("KMXZS_CORS_ORIGINS", _cors_default).split(",")
    if o.strip()
]

def _normalize_admin_prefix(raw: str) -> str:
    p = (raw or "").strip()
    if not p.startswith("/"):
        p = "/" + p
    p = p.rstrip("/")
    reserved = {"", "/", "/health", "/docs", "/redoc", "/openapi.json"}
    if p in reserved or p.startswith(API_ROOT) or p.startswith("/api"):
        return "/zbpanel"
    return p


ADMIN_TOKEN = ""
ADMIN_PREFIX = _normalize_admin_prefix(os.getenv("KMXZS_ADMIN_PATH", "/zbpanel"))
ADMIN_BASIC_USER = (os.getenv("KMXZS_ADMIN_USER") or "zbxzs").strip() or "zbxzs"
ADMIN_BASIC_FILE = Path(os.getenv("KMXZS_ADMIN_BASIC_FILE", "/data/admin_basic.txt"))
ADMIN_BASIC_PASS = ""  # filled at startup
RELEASES_DIR = Path(os.getenv("KMXZS_RELEASES_DIR", "/data/releases"))
MAX_RELEASE_BYTES = int(os.getenv("KMXZS_MAX_RELEASE_BYTES", str(80 * 1024 * 1024)))

app = FastAPI(
    title="kmxzs-card-server",
    version="1.3.0",
    docs_url=None if PRODUCTION else "/docs",
    redoc_url=None if PRODUCTION else "/redoc",
    openapi_url=None if PRODUCTION else "/openapi.json",
)
if CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=CORS_ORIGINS if CORS_ORIGINS != ["*"] else ["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

_rate_lock = threading.Lock()
_rate_buckets: dict[str, Deque[float]] = defaultdict(deque)
_nonce_lock = threading.Lock()
_nonce_seen: dict[str, float] = {}


def _is_admin_path(path: str) -> bool:
    return path == ADMIN_PREFIX or path.startswith(ADMIN_PREFIX + "/")


@app.middleware("http")
async def protect_admin(request: Request, call_next):  # type: ignore[no-untyped-def]
    """后台必须先过账号密码；扫到端口没有密码进不去。"""
    if _is_admin_path(request.url.path) and (PRODUCTION or ADMIN_BASIC_PASS):
        if not _check_admin_basic(request):
            try:
                rate_limit(f"admin-basic:{client_ip(request)}", 30, 300)
            except HTTPException:
                return Response(
                    content="请求过于频繁",
                    status_code=429,
                    media_type="text/plain; charset=utf-8",
                )
            return Response(
                content="需要后台账号密码",
                status_code=401,
                headers={"WWW-Authenticate": 'Basic realm="zbxzs"'},
                media_type="text/plain; charset=utf-8",
            )
        request.state.admin_basic_ok = True
    return await call_next(request)



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


def client_ip(request: Request) -> str:
    # 仅在明确信任反代时才读 X-Forwarded-For，避免客户端伪造绕过限流
    if TRUST_PROXY:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "unknown"


def public_origin(request: Request) -> str:
    host = (request.headers.get("host") or "").strip()
    if TRUST_PROXY:
        host = (request.headers.get("x-forwarded-host") or host).split(",")[0].strip()
    proto = request.url.scheme or "http"
    if TRUST_PROXY:
        proto = (request.headers.get("x-forwarded-proto") or proto).split(",")[0].strip()
    if not host:
        host = "127.0.0.1:18080"
    return f"{proto}://{host}".rstrip("/")


def is_weak_api_secret(secret: str) -> bool:
    s = (secret or "").strip()
    if s in WEAK_API_SECRETS:
        return True
    if len(s) < 16:
        return True
    if s.startswith("请替换"):
        return True
    return False


def rate_limit(key: str, limit: int, window_sec: int) -> None:
    now = time.time()
    with _rate_lock:
        q = _rate_buckets[key]
        while q and now - q[0] > window_sec:
            q.popleft()
        if len(q) >= limit:
            raise HTTPException(status_code=429, detail=fail(429, "请求过于频繁，请稍后再试"))
        q.append(now)



def canonical_body(data: Mapping[str, Any]) -> str:
    skip = {"sign", "timestamp", "nonce", "deviceId", "device_id"}
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
    return hmac.new(API_SECRET.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def remember_nonce(nonce: str) -> None:
    now = time.time()
    with _nonce_lock:
        dead = [k for k, t in _nonce_seen.items() if now - t > SIGN_MAX_SKEW_MS / 1000.0 + 60]
        for k in dead:
            _nonce_seen.pop(k, None)
        if nonce in _nonce_seen:
            raise HTTPException(status_code=401, detail=fail(401, "请求已失效，请重试"))
        _nonce_seen[nonce] = now


def require_client_sign(path: str, data: Mapping[str, Any]) -> None:
    """校验客户端 HMAC；未配置密钥且非生产则跳过（本地联调）。"""
    if not REQUIRE_SIGN:
        return
    if not API_SECRET:
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
    if abs(now_ms - ts_i) > SIGN_MAX_SKEW_MS:
        raise HTTPException(status_code=401, detail=fail(401, "请求已过期，请校准系统时间"))

    remember_nonce(nonce)
    expect = make_sign(path, ts_i, nonce, device_id, data)
    if not secrets.compare_digest(expect, sign):
        raise HTTPException(status_code=401, detail=fail(401, "签名校验失败"))


def body_dict(model: BaseModel | Mapping[str, Any] | None) -> dict[str, Any]:
    if model is None:
        return {}
    if isinstance(model, BaseModel):
        return model.model_dump()
    return dict(model)


@contextmanager
def db() -> Generator[sqlite3.Connection, None, None]:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
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


def resolve_admin_token() -> str:
    env_token = (os.getenv("KMXZS_ADMIN_TOKEN") or "").strip()
    if env_token and env_token not in WEAK_TOKENS:
        return env_token

    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    if TOKEN_FILE.exists():
        saved = TOKEN_FILE.read_text(encoding="utf-8").strip()
        if saved and saved not in WEAK_TOKENS:
            return saved

    token = secrets.token_urlsafe(24)
    TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    return token


def resolve_admin_basic_pass() -> str:
    env = (os.getenv("KMXZS_ADMIN_PASSWORD") or "").strip()
    if env and env not in WEAK_TOKENS and len(env) >= 8:
        return env
    ADMIN_BASIC_FILE.parent.mkdir(parents=True, exist_ok=True)
    if ADMIN_BASIC_FILE.exists():
        saved = ADMIN_BASIC_FILE.read_text(encoding="utf-8").strip()
        if saved:
            return saved
    pwd = secrets.token_urlsafe(12)
    ADMIN_BASIC_FILE.write_text(pwd + "\n", encoding="utf-8")
    return pwd


def _check_admin_basic(request: Request) -> bool:
    if not ADMIN_BASIC_PASS:
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
        ADMIN_BASIC_USER.encode("utf-8").ljust(64, b"\0")[:64],
    ) and len(user) == len(ADMIN_BASIC_USER)
    pwd_ok = hmac.compare_digest(
        pwd.encode("utf-8").ljust(128, b"\0")[:128],
        ADMIN_BASIC_PASS.encode("utf-8").ljust(128, b"\0")[:128],
    ) and len(pwd) == len(ADMIN_BASIC_PASS)
    return user_ok and pwd_ok


def init_db() -> None:
    with db() as conn:
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
            exists = conn.execute("SELECT 1 FROM app_settings WHERE key=?", (k,)).fetchone()
            if exists is None:
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

        if SEED_DEMO:
            row = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()
            if int(row["c"]) == 0:
                now = to_iso(utcnow())
                seeds = [
                    ("KMXZS-DEMO-30D", "login", 24 * 30, DEFAULT_MAX_DEVICES, "演示登录卡 30 天"),
                    ("KMXZS-DEMO-7D", "login", 24 * 7, DEFAULT_MAX_DEVICES, "演示登录卡 7 天"),
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


@app.on_event("startup")
def on_startup() -> None:
    global ADMIN_TOKEN, ADMIN_BASIC_PASS
    if PRODUCTION:
        if SEED_DEMO:
            raise RuntimeError("生产环境禁止 KMXZS_SEED_DEMO=1")
        if not API_SECRET or is_weak_api_secret(API_SECRET):
            raise RuntimeError(
                "生产环境必须设置足够强的 KMXZS_API_SECRET（建议 openssl rand -hex 32）"
            )
        if not REQUIRE_SIGN:
            raise RuntimeError("生产环境必须开启签名校验")
    elif REQUIRE_SIGN and (not API_SECRET or is_weak_api_secret(API_SECRET)):
        raise RuntimeError("已要求签名但 KMXZS_API_SECRET 无效或过弱")

    init_db()
    RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    ADMIN_TOKEN = resolve_admin_token()
    ADMIN_BASIC_PASS = resolve_admin_basic_pass()
    print("=" * 60)
    print("kmxzs-card-server started")
    print(f"admin token file: {TOKEN_FILE}")
    print(f"admin path: {ADMIN_PREFIX}/")
    print(f"admin basic user: {ADMIN_BASIC_USER}")
    print(f"admin basic password file: {ADMIN_BASIC_FILE}")
    if PRODUCTION:
        print(f"admin token: {ADMIN_TOKEN[:4]}...{ADMIN_TOKEN[-4:]} (full token in file)")
        print("admin password: (see /data/admin_basic.txt)")
    else:
        print(f"admin token: {ADMIN_TOKEN}")
        print(f"admin password: {ADMIN_BASIC_PASS}")
    print(f"seed demo: {SEED_DEMO}")
    print(f"production: {PRODUCTION}")
    print(f"require sign: {REQUIRE_SIGN}")
    print(f"api secret configured: {bool(API_SECRET) and not is_weak_api_secret(API_SECRET)}")
    print(f"trust proxy: {TRUST_PROXY}")
    print("=" * 60)


class SignedEmptyBody(BaseModel):
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class LoginBody(BaseModel):
    card: Optional[str] = None
    kami: Optional[str] = None
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class DeviceUnbindBody(BaseModel):
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class TopupBody(BaseModel):
    kami: Optional[str] = None
    card: Optional[str] = None
    deviceId: Optional[str] = None
    device_id: Optional[str] = None
    timestamp: Optional[int] = None
    nonce: Optional[str] = None
    sign: Optional[str] = None


class AdminCreateCardBody(BaseModel):
    code: Optional[str] = None
    kind: str = Field(default="login", pattern="^(login|topup)$")
    hours: int = Field(default=720, ge=1, le=24 * 3650)
    max_devices: int = Field(default=DEFAULT_MAX_DEVICES, ge=0, le=50)
    note: Optional[str] = None
    count: int = Field(default=1, ge=1, le=200)


class AdminPatchCardBody(BaseModel):
    enabled: Optional[bool] = None
    note: Optional[str] = None
    max_devices: Optional[int] = Field(default=None, ge=0, le=50)
    hours: Optional[int] = Field(default=None, ge=1, le=24 * 3650)


class AdminExtendBody(BaseModel):
    hours: int = Field(default=24, ge=-24 * 365, le=24 * 3650)


STATIC_DIR = Path(__file__).resolve().parent / "static"


def require_admin(request: Request, x_admin_token: Optional[str]) -> None:
    rate_limit(f"admin:{client_ip(request)}", ADMIN_RATE_LIMIT, ADMIN_RATE_WINDOW)
    if getattr(request.state, "admin_basic_ok", False):
        return
    provided = (x_admin_token or "").strip()
    expected = ADMIN_TOKEN or ""
    if not provided or len(provided) != len(expected):
        raise HTTPException(status_code=401, detail=fail(401, "admin token invalid"))
    if not secrets.compare_digest(provided, expected):
        raise HTTPException(status_code=401, detail=fail(401, "admin token invalid"))


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


def auth_card(request: Request, conn: sqlite3.Connection) -> sqlite3.Row:
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


def account_profile(conn: sqlite3.Connection, card: str, device_id: Optional[str] = None) -> dict[str, Any]:
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


SERVER_VERSION = "1.3.0"
STARTED_AT = utcnow()


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


def _version_tuple(ver: str) -> tuple[int, int, int]:
    a, b, c = ver.split(".")
    return int(a), int(b), int(c)


def highest_release() -> tuple[str, Path] | None:
    """磁盘上版本号最高的安装包（所有旧客户端都指向这一份）。"""
    if not RELEASES_DIR.exists():
        return None
    best: tuple[tuple[int, int, int], Path, str] | None = None
    for p in RELEASES_DIR.glob("zbxzs-setup-*.exe"):
        m = re.fullmatch(r"zbxzs-setup-(\d+\.\d+\.\d+)\.exe", p.name, flags=re.I)
        if not m or not p.is_file():
            continue
        ver = m.group(1)
        key = (_version_tuple(ver), p, ver)
        if best is None or key[0] > best[0]:
            best = key
    if best:
        return best[2], best[1]
    latest = RELEASES_DIR / "latest.exe"
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
    conn: sqlite3.Connection, request: Request | None = None
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
    return {
        "notice": notice,
        "version": version,
        "download": download,
        "downloadSize": size,
        "force": force,
        "minVersion": min_version,
        "serverVersion": SERVER_VERSION,
        "seedDemo": SEED_DEMO,
    }


@app.get("/health")
def health() -> dict[str, Any]:
    uptime = int((utcnow() - STARTED_AT).total_seconds())
    now_ms = int(time.time() * 1000)
    if PRODUCTION:
        return {
            "ok": True,
            "service": "kmxzs-card-server",
            "version": SERVER_VERSION,
            "uptimeSec": uptime,
            "serverTimeMs": now_ms,
        }
    with db() as conn:
        cards = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()["c"]
        accounts = conn.execute("SELECT COUNT(*) AS c FROM accounts").fetchone()["c"]
        cfg = load_public_config(conn)
    return {
        "ok": True,
        "service": "kmxzs-card-server",
        "version": SERVER_VERSION,
        "time": to_iso(utcnow()),
        "serverTimeMs": now_ms,
        "uptimeSec": uptime,
        "seedDemo": SEED_DEMO,
        "cards": cards,
        "accounts": accounts,
        "clientVersion": cfg["version"],
        "notice": cfg["notice"],
    }


@app.post(f"{API_ROOT}/login")
def login(request: Request, body: LoginBody) -> dict[str, Any]:
    ip = client_ip(request)
    rate_limit(f"login:{ip}", LOGIN_RATE_LIMIT, LOGIN_RATE_WINDOW)
    require_client_sign(f"{API_ROOT}/login", body_dict(body))

    code = (body.card or body.kami or "").strip()
    device_id = (body.deviceId or body.device_id or "").strip() or f"unknown-{uuid.uuid4().hex[:8]}"
    if not code:
        return fail(400, "请输入卡密")

    with db() as conn:
        card = conn.execute("SELECT * FROM cards WHERE code=?", (code,)).fetchone()
        if card is None or int(card["enabled"]) != 1:
            audit(conn, action="login_fail", actor=code or "-", target=code, detail={"reason": "invalid"}, ip=ip, ok_flag=False)
            return fail(401, "卡密无效")
        if card["kind"] != "login":
            audit(conn, action="login_fail", actor=code, target=code, detail={"reason": "not_login_card"}, ip=ip, ok_flag=False)
            return fail(400, "这是充值卡，请在客户端「卡密充值」使用")

        card_exp = parse_dt(card["expires_at"])
        if card_exp and card_exp < utcnow():
            audit(conn, action="login_fail", actor=code, target=code, detail={"reason": "card_expired"}, ip=ip, ok_flag=False)
            return fail(401, "卡密已过期")

        expires = ensure_account(conn, code, int(card["hours"]))
        if expires < utcnow():
            audit(conn, action="login_fail", actor=code, target=code, detail={"reason": "account_expired"}, ip=ip, ok_flag=False)
            return fail(401, "账号已过期，请充值")

        devices = conn.execute(
            "SELECT * FROM devices WHERE card=? ORDER BY id ASC", (code,)
        ).fetchall()
        bound = next((d for d in devices if d["device_id"] == device_id), None)
        max_devices = int(card["max_devices"] or DEFAULT_MAX_DEVICES)
        if bound is None:
            if len(devices) >= max_devices:
                audit(
                    conn,
                    action="login_fail",
                    actor=code,
                    target=code,
                    detail={"reason": "device_limit", "deviceId": device_id},
                    ip=ip,
                    ok_flag=False,
                )
                return fail(403, f"设备数已达上限({max_devices})，请先解绑")
            conn.execute(
                """
                INSERT INTO devices(card, device_id, name, bound_at)
                VALUES (?, ?, ?, ?)
                """,
                (code, device_id, device_id, to_iso(utcnow())),
            )

        # 同设备只保留最新会话，降低盗用面
        conn.execute("DELETE FROM sessions WHERE card=? AND device_id=?", (code, device_id))
        token = secrets.token_urlsafe(32)
        conn.execute(
            """
            INSERT INTO sessions(token, card, device_id, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (token, code, device_id, to_iso(expires), to_iso(utcnow())),
        )
        profile = account_profile(conn, code, device_id)
        audit(
            conn,
            action="login_ok",
            actor=code,
            target=code,
            detail={"deviceId": device_id},
            ip=ip,
        )
        return ok(
            {
                "token": token,
                **profile,
            },
            message="登录成功",
        )


@app.post(f"{API_ROOT}/config")
def config(request: Request, body: SignedEmptyBody = SignedEmptyBody()) -> dict[str, Any]:
    require_client_sign(f"{API_ROOT}/config", body_dict(body))
    with db() as conn:
        return ok(load_public_config(conn, request))


class AdminSettingsBody(BaseModel):
    notice: Optional[str] = None
    client_version: Optional[str] = None
    download_url: Optional[str] = None
    force_update: Optional[bool] = None
    min_client_version: Optional[str] = None


@app.post(f"{API_ROOT}/me")
def me(request: Request, body: SignedEmptyBody = SignedEmptyBody()) -> dict[str, Any]:
    require_client_sign(f"{API_ROOT}/me", body_dict(body))
    with db() as conn:
        session = auth_card(request, conn)
        profile = account_profile(conn, str(session["card"]), session["device_id"])
        return ok(profile)


@app.post(f"{API_ROOT}/device/list")
def device_list(request: Request, body: SignedEmptyBody = SignedEmptyBody()) -> dict[str, Any]:
    require_client_sign(f"{API_ROOT}/device/list", body_dict(body))
    with db() as conn:
        session = auth_card(request, conn)
        card = str(session["card"])
        rows = conn.execute(
            "SELECT device_id, name, bound_at FROM devices WHERE card=? ORDER BY id ASC",
            (card,),
        ).fetchall()
        data = [
            {
                "deviceId": r["device_id"],
                "device_id": r["device_id"],
                "name": r["name"] or r["device_id"],
                "boundAt": r["bound_at"],
            }
            for r in rows
        ]
        return ok(data)


@app.post(f"{API_ROOT}/device/unbind")
def device_unbind(request: Request, body: DeviceUnbindBody) -> dict[str, Any]:
    require_client_sign(f"{API_ROOT}/device/unbind", body_dict(body))
    device_id = (body.deviceId or body.device_id or "").strip()
    if not device_id:
        return fail(400, "缺少 deviceId")

    with db() as conn:
        session = auth_card(request, conn)
        card = str(session["card"])
        cur = conn.execute(
            "DELETE FROM devices WHERE card=? AND device_id=?",
            (card, device_id),
        )
        if cur.rowcount == 0:
            return fail(404, "设备不存在")

        add_hours(conn, card, -UNBIND_PENALTY_HOURS)
        audit(
            conn,
            action="unbind_device",
            actor=card,
            target=device_id,
            detail={"penaltyHours": UNBIND_PENALTY_HOURS},
            ip=client_ip(request),
        )
        return ok(
            {
                "deviceId": device_id,
                "penaltyHours": UNBIND_PENALTY_HOURS,
                **account_profile(conn, card, session["device_id"]),
            },
            "解绑成功",
        )


@app.post(f"{API_ROOT}/topup")
def topup(request: Request, body: TopupBody) -> dict[str, Any]:
    ip = client_ip(request)
    rate_limit(f"topup:{ip}", LOGIN_RATE_LIMIT, LOGIN_RATE_WINDOW)
    require_client_sign(f"{API_ROOT}/topup", body_dict(body))
    kami = (body.kami or body.card or "").strip()
    if not kami:
        return fail(400, "请输入充值卡密")

    with db() as conn:
        session = auth_card(request, conn)
        card = str(session["card"])
        top = conn.execute("SELECT * FROM cards WHERE code=?", (kami,)).fetchone()
        if top is None or int(top["enabled"]) != 1:
            audit(conn, action="topup_fail", actor=card, target=kami, detail={"reason": "invalid"}, ip=ip, ok_flag=False)
            return fail(404, "充值卡密无效")
        if top["kind"] != "topup":
            audit(conn, action="topup_fail", actor=card, target=kami, detail={"reason": "not_topup"}, ip=ip, ok_flag=False)
            return fail(400, "这不是充值卡")

        used = conn.execute("SELECT 1 FROM topup_used WHERE code=?", (kami,)).fetchone()
        if used is not None:
            audit(conn, action="topup_fail", actor=card, target=kami, detail={"reason": "used"}, ip=ip, ok_flag=False)
            return fail(409, "充值卡已使用")

        expires = add_hours(conn, card, int(top["hours"]))
        conn.execute(
            "INSERT INTO topup_used(code, used_by, used_at) VALUES (?, ?, ?)",
            (kami, card, to_iso(utcnow())),
        )
        conn.execute("UPDATE cards SET enabled=0 WHERE code=?", (kami,))
        # 同步延长当前会话
        conn.execute(
            "UPDATE sessions SET expires_at=? WHERE card=?",
            (to_iso(expires), card),
        )
        profile = account_profile(conn, card, session["device_id"])
        audit(
            conn,
            action="topup_ok",
            actor=card,
            target=kami,
            detail={"addedHours": int(top["hours"])},
            ip=ip,
        )
        return ok({**profile, "addedHours": int(top["hours"])}, "充值成功")


@app.post(f"{API_ROOT}/kwailive/account")
def report_account(request: Request, payload: dict[str, Any]) -> dict[str, Any]:
    require_client_sign(f"{API_ROOT}/kwailive/account", payload)
    with db() as conn:
        session = auth_card(request, conn)
        audit(
            conn,
            action="report_account",
            actor=str(session["card"]),
            detail={"keys": list(payload.keys())[:20]},
            ip=client_ip(request),
        )
    return ok({"accepted": True})


@app.get("/")
def root() -> dict[str, Any]:
    return {"ok": True, "service": "kmxzs-card-server"}


@app.get(ADMIN_PREFIX)
def admin_redirect() -> RedirectResponse:
    return RedirectResponse(url=ADMIN_PREFIX + "/")


@app.get(ADMIN_PREFIX + "/")
def admin_index() -> HTMLResponse:
    index = STATIC_DIR / "index.html"
    if not index.exists():
        raise HTTPException(status_code=404, detail="admin ui missing")
    html = index.read_text(encoding="utf-8").replace("__ADMIN_BASE__", ADMIN_PREFIX)
    return HTMLResponse(html)


@app.get(ADMIN_PREFIX + "/overview")
def admin_overview(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        cards_total = conn.execute("SELECT COUNT(*) AS c FROM cards").fetchone()["c"]
        cards_login = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE kind='login' AND enabled=1"
        ).fetchone()["c"]
        cards_topup = conn.execute(
            "SELECT COUNT(*) AS c FROM cards WHERE kind='topup' AND enabled=1"
        ).fetchone()["c"]
        accounts = conn.execute("SELECT COUNT(*) AS c FROM accounts").fetchone()["c"]
        devices = conn.execute("SELECT COUNT(*) AS c FROM devices").fetchone()["c"]
        sessions = conn.execute("SELECT COUNT(*) AS c FROM sessions").fetchone()["c"]
        used_topup = conn.execute("SELECT COUNT(*) AS c FROM topup_used").fetchone()["c"]
        notes = conn.execute(
            """
            SELECT IFNULL(NULLIF(TRIM(note), ''), '(无备注)') AS channel, COUNT(*) AS c
            FROM cards
            GROUP BY channel
            ORDER BY c DESC
            LIMIT 20
            """
        ).fetchall()
        return ok(
            {
                "cardsTotal": cards_total,
                "cardsLoginEnabled": cards_login,
                "cardsTopupEnabled": cards_topup,
                "accounts": accounts,
                "devices": devices,
                "sessions": sessions,
                "topupUsed": used_topup,
                "channels": [{"name": r["channel"], "count": r["c"]} for r in notes],
            }
        )


@app.get(ADMIN_PREFIX + "/cards")
def admin_list_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    sql = """
        SELECT c.code, c.kind, c.hours, c.max_devices, c.enabled, c.note, c.created_at,
               a.expires_at AS account_expires_at,
               (SELECT COUNT(*) FROM devices d WHERE d.card=c.code) AS device_count,
               (SELECT 1 FROM topup_used t WHERE t.code=c.code) AS topup_used
        FROM cards c
        LEFT JOIN accounts a ON a.card=c.code
        WHERE 1=1
    """
    args: list[Any] = []
    if kind in ("login", "topup"):
        sql += " AND c.kind=?"
        args.append(kind)
    if enabled is not None:
        sql += " AND c.enabled=?"
        args.append(int(enabled))
    if q:
        sql += " AND (c.code LIKE ? OR IFNULL(c.note,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    sql += " ORDER BY c.created_at DESC"
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        return ok([dict(r) for r in rows])


@app.get(ADMIN_PREFIX + "/cards/export")
def admin_export_cards(
    request: Request,
    kind: Optional[str] = None,
    enabled: Optional[int] = None,
    q: Optional[str] = None,
    x_admin_token: Optional[str] = Header(default=None),
) -> Response:
    require_admin(request, x_admin_token)
    sql = "SELECT code, kind, hours, max_devices, enabled, note, created_at FROM cards WHERE 1=1"
    args: list[Any] = []
    if kind in ("login", "topup"):
        sql += " AND kind=?"
        args.append(kind)
    if enabled is not None:
        sql += " AND enabled=?"
        args.append(int(enabled))
    if q:
        sql += " AND (code LIKE ? OR IFNULL(note,'') LIKE ?)"
        args.extend([f"%{q}%", f"%{q}%"])
    sql += " ORDER BY created_at DESC"
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        audit(conn, action="export_cards", actor="admin", detail={"count": len(rows)}, ip=client_ip(request))
    lines = ["code,kind,hours,max_devices,enabled,note,created_at"]
    for r in rows:
        note = (r["note"] or "").replace('"', '""')
        lines.append(
            f'{r["code"]},{r["kind"]},{r["hours"]},{r["max_devices"]},{r["enabled"]},"{note}",{r["created_at"]}'
        )
    content = "\n".join(lines) + "\n"
    return Response(
        content=content,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="kmxzs-cards.csv"'},
    )


@app.post(ADMIN_PREFIX + "/cards")
def admin_create_cards(
    request: Request,
    body: AdminCreateCardBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    created: list[str] = []
    now = to_iso(utcnow())
    with db() as conn:
        for _ in range(body.count):
            code = body.code
            if not code:
                suffix = hashlib.sha1(
                    f"{time.time_ns()}-{secrets.token_hex(4)}".encode()
                ).hexdigest()[:10].upper()
                prefix = "KMXZS-LOGIN" if body.kind == "login" else "KMXZS-TOPUP"
                code = f"{prefix}-{suffix}"
            exists = conn.execute("SELECT 1 FROM cards WHERE code=?", (code,)).fetchone()
            if exists:
                raise HTTPException(status_code=409, detail=fail(409, f"卡密已存在: {code}"))
            conn.execute(
                """
                INSERT INTO cards(code, kind, hours, max_devices, expires_at, enabled, note, created_at)
                VALUES (?, ?, ?, ?, NULL, 1, ?, ?)
                """,
                (code, body.kind, body.hours, body.max_devices, body.note, now),
            )
            created.append(code)
            body.code = None
        audit(
            conn,
            action="create_cards",
            actor="admin",
            detail={"kind": body.kind, "count": len(created), "note": body.note},
            ip=client_ip(request),
        )
    return ok({"cards": created}, "created")


@app.patch(ADMIN_PREFIX + "/cards/{code}")
def admin_patch_card(
    request: Request,
    code: str,
    body: AdminPatchCardBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    fields: list[str] = []
    args: list[Any] = []
    if body.enabled is not None:
        fields.append("enabled=?")
        args.append(1 if body.enabled else 0)
    if body.note is not None:
        fields.append("note=?")
        args.append(body.note)
    if body.max_devices is not None:
        fields.append("max_devices=?")
        args.append(body.max_devices)
    if body.hours is not None:
        fields.append("hours=?")
        args.append(body.hours)
    if not fields:
        return fail(400, "没有可更新字段")
    args.append(code)
    with db() as conn:
        cur = conn.execute(f"UPDATE cards SET {', '.join(fields)} WHERE code=?", args)
        if cur.rowcount == 0:
            return fail(404, "卡密不存在")
        row = conn.execute("SELECT * FROM cards WHERE code=?", (code,)).fetchone()
        audit(
            conn,
            action="patch_card",
            actor="admin",
            target=code,
            detail=body.model_dump(exclude_none=True),
            ip=client_ip(request),
        )
        return ok(dict(row), "updated")


@app.delete(ADMIN_PREFIX + "/cards/{code}")
def admin_delete_card(
    request: Request,
    code: str,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        conn.execute("DELETE FROM sessions WHERE card=?", (code,))
        conn.execute("DELETE FROM devices WHERE card=?", (code,))
        conn.execute("DELETE FROM accounts WHERE card=?", (code,))
        conn.execute("DELETE FROM topup_used WHERE code=?", (code,))
        cur = conn.execute("DELETE FROM cards WHERE code=?", (code,))
        if cur.rowcount == 0:
            return fail(404, "卡密不存在")
        audit(conn, action="delete_card", actor="admin", target=code, ip=client_ip(request))
    return ok({"code": code}, "deleted")


@app.get(ADMIN_PREFIX + "/accounts")
def admin_accounts(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT a.card, a.expires_at, a.created_at, a.updated_at,
                   (SELECT COUNT(*) FROM devices d WHERE d.card=a.card) AS device_count
            FROM accounts a
            ORDER BY a.updated_at DESC
            """
        ).fetchall()
        return ok([dict(r) for r in rows])


@app.post(ADMIN_PREFIX + "/accounts/{card}/extend")
def admin_extend_account(
    request: Request,
    card: str,
    body: AdminExtendBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        exists = conn.execute("SELECT 1 FROM accounts WHERE card=?", (card,)).fetchone()
        card_exists = conn.execute("SELECT 1 FROM cards WHERE code=?", (card,)).fetchone()
        if exists is None and card_exists is None:
            return fail(404, "账号/卡密不存在")
        expires = add_hours(conn, card, body.hours)
        conn.execute(
            "UPDATE sessions SET expires_at=? WHERE card=?",
            (to_iso(expires), card),
        )
        audit(
            conn,
            action="extend_account",
            actor="admin",
            target=card,
            detail={"hours": body.hours},
            ip=client_ip(request),
        )
        return ok({"card": card, "expires": to_iso(expires)}, "extended")


@app.get(ADMIN_PREFIX + "/devices")
def admin_devices(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        rows = conn.execute(
            """
            SELECT id, card, device_id, name, bound_at
            FROM devices
            ORDER BY bound_at DESC
            """
        ).fetchall()
        return ok([dict(r) for r in rows])


@app.delete(ADMIN_PREFIX + "/devices/{device_row_id}")
def admin_delete_device(
    request: Request,
    device_row_id: int,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id=?", (device_row_id,)).fetchone()
        cur = conn.execute("DELETE FROM devices WHERE id=?", (device_row_id,))
        if cur.rowcount == 0:
            return fail(404, "设备不存在")
        audit(
            conn,
            action="admin_unbind_device",
            actor="admin",
            target=str(device_row_id),
            detail={"card": row["card"] if row else None, "device_id": row["device_id"] if row else None},
            ip=client_ip(request),
        )
    return ok({"id": device_row_id}, "deleted")


@app.get(ADMIN_PREFIX + "/logs")
def admin_logs(
    request: Request,
    limit: int = Query(default=100, ge=1, le=500),
    action: Optional[str] = None,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    sql = "SELECT id, created_at, actor, action, target, detail, ip, ok FROM audit_logs"
    args: list[Any] = []
    if action:
        sql += " WHERE action=?"
        args.append(action)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(limit)
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
        return ok([dict(r) for r in rows])


@app.get(ADMIN_PREFIX + "/token-hint")
def admin_token_hint(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    return ok(
        {
            "configured": bool(ADMIN_TOKEN),
            "hint": "已通过后台账号认证",
        }
    )


@app.get(ADMIN_PREFIX + "/settings")
def admin_get_settings(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        rows = conn.execute(
            "SELECT key, value, updated_at FROM app_settings ORDER BY key ASC"
        ).fetchall()
        data = {r["key"]: {"value": r["value"], "updatedAt": r["updated_at"]} for r in rows}
        return ok({"settings": data, "public": load_public_config(conn, request)})


@app.put(ADMIN_PREFIX + "/settings")
def admin_put_settings(
    request: Request,
    body: AdminSettingsBody,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    with db() as conn:
        if body.notice is not None:
            set_setting(conn, "notice", body.notice)
        if body.client_version is not None:
            set_setting(conn, "client_version", body.client_version.strip())
        rel = highest_release()
        advertised = (rel[0] if rel else None) or (
            body.client_version or get_setting(conn, "client_version", "1.0.0")
        )
        set_setting(conn, "download_url", latest_download_url(request, advertised))
        if body.force_update is not None:
            set_setting(conn, "force_update", "1" if body.force_update else "0")
        if body.min_client_version is not None:
            set_setting(conn, "min_client_version", body.min_client_version.strip())
        audit(
            conn,
            action="update_settings",
            actor="admin",
            detail=body.model_dump(exclude_none=True),
            ip=client_ip(request),
        )
        return ok(load_public_config(conn, request), "updated")


def _release_safe_name(name: str) -> str:
    base = Path(name or "").name
    if not re.fullmatch(r"[A-Za-z0-9._+\-]+\.exe", base, flags=re.I):
        raise HTTPException(status_code=400, detail=fail(400, "只允许上传 .exe 安装包"))
    if base.startswith("."):
        raise HTTPException(status_code=400, detail=fail(400, "非法文件名"))
    return base


@app.get("/files/{name}")
def download_release(request: Request, name: str) -> FileResponse:
    rate_limit(f"files:{client_ip(request)}", 30, 60)
    if name == "latest.exe":
        rel = highest_release()
        path = rel[1] if rel else (RELEASES_DIR / "latest.exe")
    else:
        _release_safe_name(name)
        path = RELEASES_DIR / name
    if not path.is_file() or not path.resolve().is_relative_to(RELEASES_DIR.resolve()):
        raise HTTPException(status_code=404, detail="file not found")
    return FileResponse(
        path,
        media_type="application/octet-stream",
        filename="快马小助手-setup.exe" if name == "latest.exe" else path.name,
        headers={"Cache-Control": "no-store"},
    )


@app.get(ADMIN_PREFIX + "/releases")
def admin_list_releases(
    request: Request,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    items = []
    for p in sorted(RELEASES_DIR.glob("*.exe"), key=lambda x: x.stat().st_mtime, reverse=True):
        st = p.stat()
        items.append(
            {
                "name": p.name,
                "size": st.st_size,
                "updatedAt": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat(),
                "url": f"{public_origin(request)}/files/{p.name}",
            }
        )
    return ok({"files": items, "latestUrl": f"{public_origin(request)}/files/latest.exe"})


@app.post(ADMIN_PREFIX + "/releases")
async def admin_upload_release(
    request: Request,
    file: UploadFile = File(...),
    version: str = Form(default=""),
    force_update: str = Form(default="0"),
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    require_admin(request, x_admin_token)
    ver = (version or "").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
        raise HTTPException(status_code=400, detail=fail(400, "请填写版本号，例如 1.0.1"))
    raw_name = file.filename or "setup.exe"
    if not raw_name.lower().endswith(".exe"):
        raise HTTPException(status_code=400, detail=fail(400, "只允许 .exe 安装包"))

    RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    tmp = RELEASES_DIR / f".tmp-{secrets.token_hex(8)}.exe"
    size = 0
    try:
        with tmp.open("wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_RELEASE_BYTES:
                    raise HTTPException(status_code=413, detail=fail(413, "安装包过大"))
                out.write(chunk)
        if size < 1024:
            raise HTTPException(status_code=400, detail=fail(400, "文件太小，不像安装包"))
        with tmp.open("rb") as fh:
            magic = fh.read(2)
        if magic != b"MZ":
            raise HTTPException(status_code=400, detail=fail(400, "不是有效的 Windows 可执行文件"))
        versioned = RELEASES_DIR / f"zbxzs-setup-{ver}.exe"
        shutil.move(str(tmp), str(versioned))
        rel = highest_release()
        latest = RELEASES_DIR / "latest.exe"
        shutil.copy2(rel[1] if rel else versioned, latest)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)
        await file.close()

    rel = highest_release()
    advertised = rel[0] if rel else ver
    download = latest_download_url(request, advertised)
    with db() as conn:
        set_setting(conn, "client_version", advertised)
        set_setting(conn, "download_url", download)
        if force_update in ("1", "true", "True", "yes"):
            set_setting(conn, "force_update", "1")
        audit(
            conn,
            action="upload_release",
            actor="admin",
            target=ver,
            detail={"size": size, "download": download},
            ip=client_ip(request),
        )
        pub = load_public_config(conn, request)
    return ok(
        {
            "version": advertised,
            "size": size,
            "download": download,
            "public": pub,
        },
        "uploaded",
    )


if STATIC_DIR.exists():
    app.mount(ADMIN_PREFIX + "/assets", StaticFiles(directory=STATIC_DIR), name="admin-assets")
