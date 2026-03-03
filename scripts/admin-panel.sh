#!/bin/bash
# =============================================================================
# Vaultwarden /admin 面板开关脚本
# 用法: /opt/vaultwarden/scripts/admin-panel.sh [enable|disable|status]
# =============================================================================
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/vaultwarden}"
NGINX_DIR="$DEPLOY_DIR/nginx"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"

ACTIVE_FILE="$NGINX_DIR/admin-location.inc"
ENABLED_TEMPLATE="$NGINX_DIR/admin-location.enabled.inc"
DISABLED_TEMPLATE="$NGINX_DIR/admin-location.disabled.inc"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

reload_nginx() {
    docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload >/dev/null
}

set_enabled() {
    cp "$ENABLED_TEMPLATE" "$ACTIVE_FILE"
    reload_nginx
    log "Admin panel enabled"
}

set_disabled() {
    cp "$DISABLED_TEMPLATE" "$ACTIVE_FILE"
    reload_nginx
    log "Admin panel disabled"
}

show_status() {
    if grep -q "return 404" "$ACTIVE_FILE"; then
        log "Status: disabled"
    else
        log "Status: enabled"
    fi
}

[[ -f "$ACTIVE_FILE" ]] || die "Missing $ACTIVE_FILE"
[[ -f "$ENABLED_TEMPLATE" ]] || die "Missing $ENABLED_TEMPLATE"
[[ -f "$DISABLED_TEMPLATE" ]] || die "Missing $DISABLED_TEMPLATE"

ACTION="${1:-status}"
case "$ACTION" in
    enable)
        set_enabled
        ;;
    disable)
        set_disabled
        ;;
    status)
        show_status
        ;;
    *)
        die "Usage: $0 [enable|disable|status]"
        ;;
esac
