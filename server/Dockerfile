FROM python:3.12-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    KMXZS_DB=/data/kmxzs.db \
    KMXZS_ADMIN_TOKEN_FILE=/data/admin_token.txt

COPY requirements.txt .
# 腾讯云等国内机器访问 pypi.org 常超时，使用腾讯云 PyPI 镜像
RUN pip install --no-cache-dir \
    -i https://mirrors.cloud.tencent.com/pypi/simple \
    --trusted-host mirrors.cloud.tencent.com \
    -r requirements.txt

# sqlite3 CLI 供 scripts/backup-db.sh 做在线备份
RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 \
    && rm -rf /var/lib/apt/lists/*

COPY app ./app
COPY scripts ./scripts
COPY alembic.ini .
COPY alembic ./alembic

RUN mkdir -p /data

EXPOSE 18080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18080/health', timeout=3)"

# 启动前先执行 Alembic 迁移（幂等：既有库原地升级不丢数据，新库全量建表）
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 18080"]
