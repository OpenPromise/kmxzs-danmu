"""结构化请求日志：方法/路径/状态码/耗时；异常带 traceback。

uvicorn 自带的 access log 只有请求行，不包含耗时与异常栈，且格式固定。
这里由中间件统一输出结构化行（INFO/ERROR），并关闭 uvicorn.access 避免重复。
"""
from __future__ import annotations

import logging
import sys
import time
import traceback

from fastapi import Request

from .utils import client_ip

logger = logging.getLogger("kmxzs.access")


def setup_logging() -> None:
    """配置根 logger 的控制台输出（保留已存在的 handler，避免覆盖测试日志捕获）。"""
    root = logging.getLogger()
    if not root.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(
            logging.Formatter(
                fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
                datefmt="%Y-%m-%dT%H:%M:%S",
            )
        )
        root.setLevel(logging.INFO)
        root.addHandler(handler)

    # 请求行改由 request_logging 中间件输出，避免与 uvicorn 默认 access log 重复
    logging.getLogger("uvicorn.access").disabled = True
    logging.getLogger("uvicorn.error").setLevel(logging.INFO)


async def request_logging(request: Request, call_next):
    """HTTP 中间件：记录方法、路径、状态码、耗时；异常打印完整 traceback。"""
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    except Exception:
        duration_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "request method=%s path=%s status=500 duration_ms=%.1f client=%s\n%s",
            request.method,
            request.url.path,
            duration_ms,
            client_ip(request),
            traceback.format_exc(),
        )
        raise
    finally:
        if status != 500:  # 异常路径已在 except 记录，这里只补成功/业务错误
            duration_ms = (time.perf_counter() - start) * 1000
            logger.info(
                "request method=%s path=%s status=%d duration_ms=%.1f client=%s",
                request.method,
                request.url.path,
                status,
                duration_ms,
                client_ip(request),
            )
