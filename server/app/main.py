"""kmxzs-card-server 组合根：装配 FastAPI、中间件与路由。"""
from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from .api.routers import admin as admin_router
from .api.routers import admin_ops as admin_ops_router
from .api.routers import auth as auth_router
from .api.routers import client as client_router
from .api.routers import legacy_admin as legacy_admin_router
from .api.routers import public as public_router
from .api.routers import reseller as reseller_router
from .core import config
from .core.db import init_db
from .core.logging import request_logging, setup_logging
from .core.security import (
    _check_admin_basic,
    is_weak_api_secret,
    rate_limit,
    resolve_admin_basic_pass,
    resolve_admin_token,
)
from .core.utils import client_ip, effective_scheme, fail
from .services.auth import ensure_superadmin
from .services.signing import public_key_b64

setup_logging()


@asynccontextmanager
async def lifespan(_: FastAPI):  # type: ignore[no-untyped-def]
    """应用生命周期：在开始接收请求前完成安全检查与持久层初始化。"""
    _initialize_app()
    yield


app = FastAPI(
    title="kmxzs-card-server",
    version=config.SERVER_VERSION,
    docs_url=None if config.PRODUCTION else "/docs",
    redoc_url=None if config.PRODUCTION else "/redoc",
    openapi_url=None if config.PRODUCTION else "/openapi.json",
    lifespan=lifespan,
)
if config.CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=config.CORS_ORIGINS if config.CORS_ORIGINS != ["*"] else ["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )


def _is_transition_allowed(path: str) -> bool:
    """HTTP 过渡入口白名单：老客户端拿到更新提示与新版安装包即可。"""
    if path == "/health":
        return True
    if path == "/config" or path == f"{config.API_ROOT}/config":
        return True
    if path.startswith("/files/"):
        return True
    return False


@app.middleware("http")
async def protect_admin(request: Request, call_next):  # type: ignore[no-untyped-def]
    """后台必须先过账号密码；扫到端口没有密码进不去。"""
    if config.is_admin_path(request.url.path) and (config.PRODUCTION or config.ADMIN_BASIC_PASS):
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


@app.middleware("http")
async def http_transition_guard(request: Request, call_next):  # type: ignore[no-untyped-def]
    """阶段0：明文 HTTP 仅放行过渡白名单，其余拒绝，推动老客户端升级到 HTTPS。"""
    if config.HTTP_TRANSITION and effective_scheme(request) == "http":
        if not _is_transition_allowed(request.url.path):
            return JSONResponse(
                status_code=403,
                content=fail(403, "请在客户端升级后使用加密连接（HTTPS）"),
            )
    return await call_next(request)


@app.middleware("http")
async def log_requests(request: Request, call_next):  # type: ignore[no-untyped-def]
    """最外层：结构化请求日志（方法/路径/状态码/耗时），异常带 traceback。"""
    return await request_logging(request, call_next)


def _initialize_app() -> None:
    if config.PRODUCTION:
        if config.SEED_DEMO:
            raise RuntimeError("生产环境禁止 KMXZS_SEED_DEMO=1")
        if not config.API_SECRET or is_weak_api_secret(config.API_SECRET):
            raise RuntimeError(
                "生产环境必须设置足够强的 KMXZS_API_SECRET（建议 openssl rand -hex 32）"
            )
        if not config.REQUIRE_SIGN:
            raise RuntimeError("生产环境必须开启签名校验")
    elif config.REQUIRE_SIGN and (not config.API_SECRET or is_weak_api_secret(config.API_SECRET)):
        raise RuntimeError("已要求签名但 KMXZS_API_SECRET 无效或过弱")

    init_db()
    config.RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    config.ADMIN_TOKEN = resolve_admin_token()
    config.ADMIN_BASIC_PASS = resolve_admin_basic_pass()
    superadmin_user, superadmin_pwd = ensure_superadmin()

    # 安装包 Ed25519 签名：首次自动生成私钥并导出公钥，打印公钥供客户端打包
    try:
        release_pub_b64 = public_key_b64()
        print(f"release signing public key file: {config.SIGNING_PUB_FILE}")
        print(f"release signing public key (base64, 客户端打包注入 KMXZS_UPDATE_PUBKEY): {release_pub_b64}")
    except Exception as e:  # pragma: no cover - 运维提示
        print(f"warning: 初始化安装包签名密钥失败（安装包将无法下发签名）: {e}")

    print("=" * 60)
    print("kmxzs-card-server started")
    print(f"admin token file: {config.TOKEN_FILE}")
    print(f"admin path: {config.ADMIN_PREFIX}/")
    print(f"admin basic user: {config.ADMIN_BASIC_USER}")
    print(f"admin basic password file: {config.ADMIN_BASIC_FILE}")
    if config.PRODUCTION:
        print(f"admin token: {config.ADMIN_TOKEN[:4]}...{config.ADMIN_TOKEN[-4:]} (full token in file)")
        print("admin password: (see /data/admin_basic.txt)")
    else:
        print(f"admin token: {config.ADMIN_TOKEN}")
        print(f"admin password: {config.ADMIN_BASIC_PASS}")
    print(f"seed demo: {config.SEED_DEMO}")
    print(f"production: {config.PRODUCTION}")
    print(f"require sign: {config.REQUIRE_SIGN}")
    print(f"api secret configured: {bool(config.API_SECRET) and not is_weak_api_secret(config.API_SECRET)}")
    print(f"trust proxy: {config.TRUST_PROXY}")
    print(f"http transition: {config.HTTP_TRANSITION}")
    print(f"superadmin: {superadmin_user}" + ("" if superadmin_pwd else " (already exists)"))
    if superadmin_pwd:
        print(f"superadmin password: {superadmin_pwd} (also in {config.SUPERADMIN_FILE})")
    print("=" * 60)


app.include_router(public_router.router)
app.include_router(client_router.router)
app.include_router(legacy_admin_router.router)
app.include_router(auth_router.router)
app.include_router(reseller_router.router)
app.include_router(admin_router.router)
app.include_router(admin_ops_router.router)

if config.STATIC_DIR.exists():
    app.mount(
        config.ADMIN_PREFIX + "/assets",
        StaticFiles(directory=config.STATIC_DIR),
        name="admin-assets",
    )
