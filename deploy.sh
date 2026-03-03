#!/bin/bash
# =============================================================================
# Vaultwarden 服务器一键初始化脚本
# 适用：华为云 Debian 11，无 ICP 备案（使用 8443 端口）
#
# 用法：
#   1. 通过环境变量传入 DOMAIN / ACME_EMAIL / CF_TOKEN
#   2. scp 整个目录到服务器: scp -r . root@<SERVER_IP>:/opt/vaultwarden/
#   3. ssh root@<SERVER_IP> "DOMAIN=... ACME_EMAIL=... CF_TOKEN=... bash /opt/vaultwarden/deploy.sh"
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DOMAIN="${DOMAIN:-vault.yourdomain.com}"              # 你的域名（A 记录已指向服务器）
ACME_EMAIL="${ACME_EMAIL:-your@email.com}"            # acme.sh 注册邮箱
CF_TOKEN="${CF_TOKEN:-}"                              # Cloudflare API Token（Edit zone DNS 权限）
ACME_VERSION="${ACME_VERSION:-3.1.1}"                 # 固定 acme.sh 版本，避免 curl | sh

DEPLOY_DIR="/opt/vaultwarden"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_BIN="$HOME/.acme.sh/acme.sh"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

validate_inputs() {
    [[ "$DOMAIN" != "vault.yourdomain.com" ]] || die "请设置 DOMAIN 环境变量"
    [[ "$ACME_EMAIL" != "your@email.com" ]] || die "请设置 ACME_EMAIL 环境变量"
    [[ -n "$CF_TOKEN" ]] || die "请设置 CF_TOKEN 环境变量"
}

validate_digest_ref() {
    local value="$1"
    local name="$2"
    [[ -n "$value" ]] || die "$name 不能为空"
    [[ "$value" == *@sha256:* ]] || die "$name 必须是 digest 引用（示例: image@sha256:...）"
}

validate_inputs
[[ $EUID -eq 0 ]] || die "请用 root 权限运行"

# -----------------------------------------------------------------------------
# Phase 2.1：系统更新与基础软件
# -----------------------------------------------------------------------------
log "Phase 2.1: 系统更新..."
sed -i '/bullseye-backports/d' /etc/apt/sources.list
dpkg --configure -a 2>/dev/null || true
apt-get update -qq
apt-get upgrade -y -o Dpkg::Options::="--force-confold"
apt-get install -y curl wget ufw fail2ban logrotate unzip socat sqlite3 age rclone

# -----------------------------------------------------------------------------
# Phase 2.2：ufw 防火墙
# -----------------------------------------------------------------------------
log "Phase 2.2: 配置 ufw..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 8443/tcp comment 'Vaultwarden HTTPS'
ufw --force enable

# -----------------------------------------------------------------------------
# Phase 2.3：自动安全更新
# -----------------------------------------------------------------------------
log "Phase 2.3: 配置自动安全更新..."
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CFG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CFG

# -----------------------------------------------------------------------------
# Phase 2.4：Docker
# -----------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log "Phase 2.4: 安装 Docker（阿里云镜像源）..."
    apt-get install -y apt-transport-https ca-certificates gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg \
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://mirrors.aliyun.com/docker-ce/linux/debian $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
log "Docker 版本: $(docker --version)"

# -----------------------------------------------------------------------------
# Phase 2.5：acme.sh（固定版本安装，避免 curl | sh）
# -----------------------------------------------------------------------------
if [[ ! -x "$ACME_BIN" ]]; then
    log "Phase 2.5: 安装 acme.sh ${ACME_VERSION}..."
    TMP_DIR="$(mktemp -d)"
    curl -fsSL -o "$TMP_DIR/acme.sh.tar.gz" "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"
    tar -xzf "$TMP_DIR/acme.sh.tar.gz" -C "$TMP_DIR"
    "$TMP_DIR/acme.sh-${ACME_VERSION}/acme.sh" --install --home "$HOME/.acme.sh" --accountemail "$ACME_EMAIL"
    rm -rf "$TMP_DIR"
fi
[[ -x "$ACME_BIN" ]] || die "acme.sh 安装失败"

# -----------------------------------------------------------------------------
# Phase 3：申请 SSL 证书（DNS-01）
# -----------------------------------------------------------------------------
log "Phase 3: 申请 Let's Encrypt 证书（DNS-01 via Cloudflare）..."
export CF_Token="$CF_TOKEN"

"$ACME_BIN" --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    --server letsencrypt \
    || { rc=$?; [[ $rc -eq 2 ]] && log "证书已存在，跳过申请（正常）" || die "证书申请失败，退出码: $rc"; }

log "Phase 3: 安装证书到 $DEPLOY_DIR/certs/..."
mkdir -p "$DEPLOY_DIR/certs"
chmod 700 "$DEPLOY_DIR/certs"

"$ACME_BIN" --install-cert \
    -d "$DOMAIN" \
    --cert-file      "$DEPLOY_DIR/certs/cert.pem" \
    --key-file       "$DEPLOY_DIR/certs/key.pem" \
    --fullchain-file "$DEPLOY_DIR/certs/fullchain.pem" \
    --reloadcmd "docker compose -f $DEPLOY_DIR/docker-compose.yml exec nginx nginx -s reload 2>/dev/null || true"

# -----------------------------------------------------------------------------
# Phase 4：部署文件
# -----------------------------------------------------------------------------
log "Phase 4: 创建目录结构..."
mkdir -p "$DEPLOY_DIR"/{data,nginx,scripts,backups,logs,certs}
chmod 700 "$DEPLOY_DIR/data" "$DEPLOY_DIR/backups" "$DEPLOY_DIR/certs"

if [[ "$SCRIPT_DIR" != "$DEPLOY_DIR" ]]; then
    log "复制部署文件从 $SCRIPT_DIR 到 $DEPLOY_DIR..."
    cp "$SCRIPT_DIR/docker-compose.yml" "$DEPLOY_DIR/"
    cp "$SCRIPT_DIR/.env.example"      "$DEPLOY_DIR/" || true

    if [[ -f "$SCRIPT_DIR/.env" && ! -f "$DEPLOY_DIR/.env" ]]; then
        cp "$SCRIPT_DIR/.env" "$DEPLOY_DIR/"
    fi

    cp -R "$SCRIPT_DIR/nginx/."   "$DEPLOY_DIR/nginx/"
    cp -R "$SCRIPT_DIR/scripts/." "$DEPLOY_DIR/scripts/"
fi

if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
    [[ -f "$DEPLOY_DIR/.env.example" ]] || die "缺少 .env 和 .env.example"
    cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
fi

log "替换配置中的域名占位符..."
for cfg in "$DEPLOY_DIR/nginx/vaultwarden.conf" "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.example"; do
    [[ -f "$cfg" ]] || continue
    sed -i "s/vault\.yourdomain\.com/$DOMAIN/g" "$cfg"
done

chmod 600 "$DEPLOY_DIR/.env"
chmod +x "$DEPLOY_DIR"/scripts/*.sh

# -----------------------------------------------------------------------------
# Phase 5：fail2ban
# -----------------------------------------------------------------------------
log "Phase 5: 配置 fail2ban..."
cp "$SCRIPT_DIR/fail2ban/filter.d/vaultwarden.conf" /etc/fail2ban/filter.d/
cp "$SCRIPT_DIR/fail2ban/jail.d/vaultwarden.conf"   /etc/fail2ban/jail.d/
systemctl enable --now fail2ban
systemctl restart fail2ban

# -----------------------------------------------------------------------------
# Phase 6：备份 cron
# -----------------------------------------------------------------------------
log "Phase 6: 配置备份 cron..."
cat > /etc/cron.d/vaultwarden-backup <<'CRON'
0 3 * * * root /opt/vaultwarden/scripts/backup.sh >> /opt/vaultwarden/logs/backup.log 2>&1
CRON

# -----------------------------------------------------------------------------
# Phase 7：启动服务
# -----------------------------------------------------------------------------
log "Phase 7: 校验配置并启动 Vaultwarden..."
cd "$DEPLOY_DIR"

set -a
# shellcheck disable=SC1091
source "$DEPLOY_DIR/.env"
set +a

validate_digest_ref "${VAULTWARDEN_IMAGE:-}" "VAULTWARDEN_IMAGE"
validate_digest_ref "${NGINX_IMAGE:-}" "NGINX_IMAGE"
[[ -n "${BACKUP_AGE_RECIPIENT:-}" || -n "${BACKUP_AGE_RECIPIENT_FILE:-}" ]] || die "必须设置 BACKUP_AGE_RECIPIENT 或 BACKUP_AGE_RECIPIENT_FILE"

if [[ "${BACKUP_REQUIRE_REMOTE:-true}" == "true" ]]; then
    [[ -n "${BACKUP_REMOTE_TARGET:-}" && "${BACKUP_REMOTE_TARGET}" != "SET_ME" ]] || die "BACKUP_REQUIRE_REMOTE=true 时必须设置 BACKUP_REMOTE_TARGET"
fi

docker compose config >/dev/null
docker compose up -d

log ""
log "============================================================"
log "部署完成！"
log ""
log "后续步骤："
log "  1. 访问 https://$DOMAIN:8443 注册账号"
log "  2. 验证 fail2ban 真实 IP: grep 'Username or password' /opt/vaultwarden/data/vaultwarden.log"
log "  3. /admin 默认关闭，维护时临时启用: /opt/vaultwarden/scripts/admin-panel.sh enable"
log "     维护后务必执行: /opt/vaultwarden/scripts/admin-panel.sh disable"
log ""
log "验证命令："
log "  curl -I https://$DOMAIN:8443"
log "  docker compose ps"
log "  fail2ban-client status vaultwarden"
log "  ~/.acme.sh/acme.sh --list"
log "============================================================"
