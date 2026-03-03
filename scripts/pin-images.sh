#!/bin/bash
# =============================================================================
# 生成镜像 digest 环境变量（写入示例到 stdout）
# 依赖: crane
# =============================================================================
set -euo pipefail

VAULTWARDEN_TAG="${1:-ghcr.io/dani-garcia/vaultwarden:latest}"
NGINX_TAG="${2:-nginx:1.27-alpine}"

command -v crane >/dev/null 2>&1 || {
    echo "crane is required. Install via: brew install crane" >&2
    exit 1
}

TMP_DOCKER_CONFIG="$(mktemp -d)"
trap 'rm -rf "$TMP_DOCKER_CONFIG"' EXIT

echo '{}' > "$TMP_DOCKER_CONFIG/config.json"

VW_DIGEST="$(DOCKER_CONFIG="$TMP_DOCKER_CONFIG" crane digest "$VAULTWARDEN_TAG")"
NGINX_DIGEST="$(DOCKER_CONFIG="$TMP_DOCKER_CONFIG" crane digest "$NGINX_TAG")"

echo "VAULTWARDEN_IMAGE=${VAULTWARDEN_TAG%@*}@${VW_DIGEST}"
echo "NGINX_IMAGE=${NGINX_TAG%@*}@${NGINX_DIGEST}"
