"""pytest 全局夹具。环境变量必须在导入 app 之前设置。"""
from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# 测试环境：全部落到临时目录，避免污染仓库内真实数据
# ---------------------------------------------------------------------------
_TEST_DIR = Path(tempfile.mkdtemp(prefix="kmxzs-test-"))

os.environ["KMXZS_DB"] = str(_TEST_DIR / "test.db")
os.environ["KMXZS_RELEASES_DIR"] = str(_TEST_DIR / "releases")
os.environ["KMXZS_ADMIN_TOKEN_FILE"] = str(_TEST_DIR / "admin_token.txt")
os.environ["KMXZS_ADMIN_BASIC_FILE"] = str(_TEST_DIR / "admin_basic.txt")
os.environ["KMXZS_SUPERADMIN_FILE"] = str(_TEST_DIR / "superadmin.txt")
os.environ["KMXZS_JWT_SECRET_FILE"] = str(_TEST_DIR / "jwt_secret.txt")
os.environ["KMXZS_SIGNING_KEY_FILE"] = str(_TEST_DIR / "release_signing.key")
os.environ["KMXZS_SIGNING_PUB_FILE"] = str(_TEST_DIR / "release_signing.pub")

os.environ["KMXZS_PRODUCTION"] = "0"
os.environ["KMXZS_SEED_DEMO"] = "1"
os.environ["KMXZS_REQUIRE_SIGN"] = "1"
os.environ["KMXZS_API_SECRET"] = "test-api-secret-0123456789abcdef0123456789abcdef"
os.environ["KMXZS_TRUST_PROXY"] = "0"
os.environ["KMXZS_HTTP_TRANSITION"] = "0"
os.environ["KMXZS_LOGIN_RATE_LIMIT"] = "5"
os.environ["KMXZS_LOGIN_RATE_WINDOW"] = "900"

os.environ["KMXZS_ADMIN_TOKEN"] = "test-admin-token-0123456789abcdef0123456789abcdef"
os.environ["KMXZS_ADMIN_PASSWORD"] = "test-admin-pass-123"
os.environ["KMXZS_ADMIN_USER"] = "zbxzs"
os.environ["KMXZS_SUPERADMIN_USER"] = "superadmin"
os.environ["KMXZS_SUPERADMIN_PASSWORD"] = "test-superadmin-pass-123"


@pytest.fixture
def client():
    """每个用例一个全新数据库/安装包目录的 TestClient。"""
    from fastapi.testclient import TestClient

    from app.main import app

    db_file = Path(os.environ["KMXZS_DB"])
    for suffix in ("", "-wal", "-shm"):
        p = Path(f"{db_file}{suffix}")
        p.unlink(missing_ok=True)

    releases = Path(os.environ["KMXZS_RELEASES_DIR"])
    if releases.exists():
        shutil.rmtree(releases, ignore_errors=True)
    releases.mkdir(parents=True, exist_ok=True)

    with TestClient(app) as c:
        yield c
