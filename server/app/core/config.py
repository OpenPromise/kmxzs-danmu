"""集中式环境配置。所有配置在 import 时从环境变量读取一次。"""
from __future__ import annotations

import os
from pathlib import Path

# ---------------------------------------------------------------------------
# 客户端 API 根路径（老客户端 1.0.x 硬编码，绝不能改）
# ---------------------------------------------------------------------------
API_ROOT = "/api/user/1009/flutter/1.0.2"

# ---------------------------------------------------------------------------
# 存储路径
# ---------------------------------------------------------------------------
DB_PATH = Path(os.getenv("KMXZS_DB", "/data/kmxzs.db"))
TOKEN_FILE = Path(os.getenv("KMXZS_ADMIN_TOKEN_FILE", "/data/admin_token.txt"))
RELEASES_DIR = Path(os.getenv("KMXZS_RELEASES_DIR", "/data/releases"))
SUPERADMIN_FILE = Path(os.getenv("KMXZS_SUPERADMIN_FILE", "/data/superadmin.txt"))
JWT_SECRET_FILE = Path(os.getenv("KMXZS_JWT_SECRET_FILE", "/data/jwt_secret.txt"))
SIGNING_KEY_FILE = Path(os.getenv("KMXZS_SIGNING_KEY_FILE", "/data/release_signing.key"))
SIGNING_PUB_FILE = Path(os.getenv("KMXZS_SIGNING_PUB_FILE", "/data/release_signing.pub"))
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"

# ---------------------------------------------------------------------------
# 安全基线
# ---------------------------------------------------------------------------
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
SEED_DEMO = os.getenv("KMXZS_SEED_DEMO", "0") == "1"
PRODUCTION = os.getenv("KMXZS_PRODUCTION", "0") == "1"
API_SECRET = (os.getenv("KMXZS_API_SECRET") or "").strip()
TRUST_PROXY = os.getenv("KMXZS_TRUST_PROXY", "0") == "1"
# 阶段0：HTTP 过渡入口。开启后仅放行 /config、/files/*、/health，其余路径在明文 HTTP 上拒绝。
HTTP_TRANSITION = os.getenv("KMXZS_HTTP_TRANSITION", "0") == "1"
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
MAX_RELEASE_BYTES = int(os.getenv("KMXZS_MAX_RELEASE_BYTES", str(80 * 1024 * 1024)))
_cors_default = "*" if not PRODUCTION else ""
CORS_ORIGINS = [
    o.strip()
    for o in os.getenv("KMXZS_CORS_ORIGINS", _cors_default).split(",")
    if o.strip()
]

# ---------------------------------------------------------------------------
# 管理后台（过渡期保留的 Basic + token 后台）
# ---------------------------------------------------------------------------
ADMIN_TOKEN = ""  # 启动时由 resolve_admin_token() 填充
ADMIN_BASIC_PASS = ""  # 启动时由 resolve_admin_basic_pass() 填充
ADMIN_BASIC_USER = (os.getenv("KMXZS_ADMIN_USER") or "zbxzs").strip() or "zbxzs"
ADMIN_BASIC_FILE = Path(os.getenv("KMXZS_ADMIN_BASIC_FILE", "/data/admin_basic.txt"))


def _normalize_admin_prefix(raw: str) -> str:
    p = (raw or "").strip()
    if not p.startswith("/"):
        p = "/" + p
    p = p.rstrip("/")
    reserved = {"", "/", "/health", "/docs", "/redoc", "/openapi.json"}
    if p in reserved or p.startswith(API_ROOT) or p.startswith("/api"):
        return "/zbpanel"
    return p


ADMIN_PREFIX = _normalize_admin_prefix(os.getenv("KMXZS_ADMIN_PATH", "/zbpanel"))

# ---------------------------------------------------------------------------
# 阶段1：RBAC / JWT / 分销代理
# ---------------------------------------------------------------------------
JWT_ALG = "HS256"
ACCESS_TOKEN_MINUTES = int(os.getenv("KMXZS_ACCESS_TOKEN_MINUTES", "120"))
REFRESH_TOKEN_DAYS = int(os.getenv("KMXZS_REFRESH_TOKEN_DAYS", "14"))
SUPERADMIN_USER = (os.getenv("KMXZS_SUPERADMIN_USER") or "superadmin").strip() or "superadmin"
SUPERADMIN_PASSWORD = (os.getenv("KMXZS_SUPERADMIN_PASSWORD") or "").strip()

# ---------------------------------------------------------------------------
# SQLite 持久化的安全内部表
# ---------------------------------------------------------------------------
RATE_LIMIT_TABLE = "rate_limits"
NONCE_TABLE = "nonce_seen"
USER_SESSION_TABLE = "user_sessions"

SERVER_VERSION = "1.3.0"


def is_admin_path(path: str) -> bool:
    return path == ADMIN_PREFIX or path.startswith(ADMIN_PREFIX + "/")
