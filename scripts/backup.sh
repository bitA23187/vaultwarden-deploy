#!/bin/bash
# =============================================================================
# Vaultwarden 备份脚本（加密 + 可选异地同步）
# 部署路径: /opt/vaultwarden/scripts/backup.sh
# Cron: 0 3 * * * root /opt/vaultwarden/scripts/backup.sh >> /opt/vaultwarden/logs/backup.log 2>&1
# =============================================================================
set -euo pipefail
umask 077

DEPLOY_DIR="${DEPLOY_DIR:-/opt/vaultwarden}"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
DATA_DIR="${DATA_DIR:-$DEPLOY_DIR/data}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
REMOTE_TARGET="${BACKUP_REMOTE_TARGET:-}"
REQUIRE_REMOTE="${BACKUP_REQUIRE_REMOTE:-true}"
AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
AGE_RECIPIENT_FILE="${BACKUP_AGE_RECIPIENT_FILE:-}"

DATE="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="$(mktemp -d /tmp/vw_backup.XXXXXX)"
PAYLOAD_DIR="$WORK_DIR/payload"
SNAPSHOT_DB="$WORK_DIR/db.sqlite3"
PLAINTEXT_ARCHIVE="$WORK_DIR/vw_backup_${DATE}.tar.gz"
ENCRYPTED_ARCHIVE="$BACKUP_DIR/vw_backup_${DATE}.tar.gz.age"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

resolve_recipient() {
    if [[ -n "$AGE_RECIPIENT" ]]; then
        echo "$AGE_RECIPIENT"
        return
    fi

    if [[ -n "$AGE_RECIPIENT_FILE" && -f "$AGE_RECIPIENT_FILE" ]]; then
        grep -E '^[[:space:]]*age1[0-9a-z]+' "$AGE_RECIPIENT_FILE" | head -n 1 | tr -d '[:space:]'
        return
    fi

    echo ""
}

RECIPIENT="$(resolve_recipient)"
[[ -n "$RECIPIENT" ]] || die "未配置 BACKUP_AGE_RECIPIENT 或 BACKUP_AGE_RECIPIENT_FILE，拒绝生成明文备份"

require_cmd sqlite3
require_cmd tar
require_cmd age

if [[ -n "$REMOTE_TARGET" ]]; then
    require_cmd rclone
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
mkdir -p "$PAYLOAD_DIR"

[[ -f "$DATA_DIR/db.sqlite3" ]] || die "数据库不存在: $DATA_DIR/db.sqlite3"

log "Starting encrypted backup..."

# SQLite 在线备份，确保一致性快照
sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$SNAPSHOT_DB'"
mv "$SNAPSHOT_DB" "$PAYLOAD_DIR/db.sqlite3"

if [[ -d "$DATA_DIR/attachments" ]]; then
    cp -a "$DATA_DIR/attachments" "$PAYLOAD_DIR/attachments"
fi

if [[ -d "$DATA_DIR/sends" ]]; then
    cp -a "$DATA_DIR/sends" "$PAYLOAD_DIR/sends"
fi

tar czf "$PLAINTEXT_ARCHIVE" -C "$PAYLOAD_DIR" .
age --encrypt --recipient "$RECIPIENT" --output "$ENCRYPTED_ARCHIVE" "$PLAINTEXT_ARCHIVE"
chmod 600 "$ENCRYPTED_ARCHIVE"

# 异地副本（推荐）
if [[ -n "$REMOTE_TARGET" ]]; then
    rclone copy -- "$ENCRYPTED_ARCHIVE" "$REMOTE_TARGET"
    log "Remote sync completed: $REMOTE_TARGET"
elif [[ "$REQUIRE_REMOTE" == "true" ]]; then
    die "BACKUP_REQUIRE_REMOTE=true 但未配置 BACKUP_REMOTE_TARGET"
else
    log "Remote sync skipped: BACKUP_REMOTE_TARGET is empty"
fi

# 清理旧备份
find "$BACKUP_DIR" -name "vw_backup_*.tar.gz.age" -mtime "+$KEEP_DAYS" -delete

SIZE="$(du -sh "$ENCRYPTED_ARCHIVE" 2>/dev/null | cut -f1)"
COUNT="$(find "$BACKUP_DIR" -name 'vw_backup_*.tar.gz.age' | wc -l | tr -d ' ')"
log "Backup completed: $ENCRYPTED_ARCHIVE ($SIZE)"
log "Retained backups: $COUNT"
