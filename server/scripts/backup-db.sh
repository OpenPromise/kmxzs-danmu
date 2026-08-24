#!/usr/bin/env bash
# ============================================================
# kmxzs SQLite 在线备份（sqlite3 .backup，WAL 模式下安全，无需停服）
#
# 用法（宿主机 cron 每天调用容器执行，不用在 docker-compose 里加服务）：
#   docker exec kmxzs-card-server bash /app/scripts/backup-db.sh
#
# 宿主机 crontab 一行（每天 03:30，保留 14 份，日志可重定向到宿主文件）：
#   30 3 * * * docker exec kmxzs-card-server bash /app/scripts/backup-db.sh >>/var/log/kmxzs-backup.log 2>&1
#
# 可配置环境变量（默认值适配容器内 /data 布局）：
#   KMXZS_DB          源库路径       默认 /data/kmxzs.db
#   KMXZS_BACKUP_DIR  备份目录       默认 /data/backups
#   KMXZS_BACKUP_KEEP 保留份数       默认 14
# ============================================================
set -euo pipefail

DB="${KMXZS_DB:-/data/kmxzs.db}"
BACKUP_DIR="${KMXZS_BACKUP_DIR:-/data/backups}"
KEEP="${KMXZS_BACKUP_KEEP:-14}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "错误：容器内未找到 sqlite3 命令，请在 Dockerfile 安装（apt-get install -y sqlite3）" >&2
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "错误：数据库不存在：$DB" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/kmxzs-$STAMP.db"

# .backup 基于 SQLite online backup API，WAL 模式下对正在写入的库也是安全的
sqlite3 "$DB" ".backup '$OUT'"

# 保留最近 KEEP 份，清理更旧的
ls -1t "$BACKUP_DIR"/kmxzs-*.db 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$(date '+%Y-%m-%d %H:%M:%S') 备份完成：$OUT（保留 $KEEP 份）"
