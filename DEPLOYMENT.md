# Vaultwarden 部署参考（国内云服务器）

> 这份文档记录了在华为云 Debian 11 上部署 Vaultwarden 时遇到的问题和解法。如果你也打算用 Claude Code 部署，可以把这份文档和 `vaultwarden-deploy/` 一起丢给 CC 作为参考上下文。

---

## 约束条件

| 约束 | 原因 | 解决方案 |
|------|------|---------|
| 不能用 80/443 端口 | 无 ICP 备案，云厂商在网络层封锁 | 改用 8443 |
| 不能用 HTTP-01 证书验证 | 80 端口不通 | 改用 DNS-01（Cloudflare API）|
| Docker Hub 被墙 | 国内服务器无法拉取镜像 | 本地 Mac 用 `crane` 拉取后 SSH pipe 传入 |
| Mac 是 Apple Silicon | 服务器是 amd64 | `crane --platform linux/amd64`（Docker Desktop 指定 platform 无效）|

---

## 架构

```
Bitwarden 客户端
      |
  HTTPS :8443
      |
  Nginx 容器 (nginx:1.27-alpine)
  ├── TLS 1.2/1.3 + HSTS
  ├── 限速：主应用 10r/m，/admin 5r/m
  └── /admin 默认返回 404，维护时临时开启
      |
  Docker bridge 网络 vw_internal
      |
  Vaultwarden 容器 (ghcr.io/dani-garcia/vaultwarden:latest)
  ├── 监听 :80（仅内网）
  ├── WebSocket :3012（实时同步）
  └── SQLite → bind mount /opt/vaultwarden/data/
```

安全层次：云安全组 → ufw → Nginx 限速 + fail2ban → argon2id ADMIN_TOKEN

---

## 部署前需要准备

这些是 CC 没法帮你做的，需要你自己提前准备好：

1. **Cloudflare DNS**：添加 A 记录指向服务器 IP，**必须 DNS only（灰色云朵）**
2. **Cloudflare API Token**：My Profile → API Tokens → Edit zone DNS 模板
3. **云安全组**：开放 TCP 22 + 8443
4. **age 密钥对**（备份加密用）：`brew install age && age-keygen -o ~/vaultwarden-age-private.txt`
5. **ADMIN_TOKEN**（argon2 hash）：Docker Hub 被墙无法用官方工具，改用 Python：

```bash
pip3 install argon2-cffi
python3 -c "
from argon2 import PasswordHasher
import getpass
ph = PasswordHasher(time_cost=3, memory_cost=65540, parallelism=4, hash_len=32, salt_len=16)
print(ph.hash(getpass.getpass('admin 密码: ')))
"
```

---

## 踩坑记录

### 1. `get.docker.com` 被墙

安装 Docker 引擎本身的官方脚本无法下载。

**解法：** 用阿里云 Docker CE apt 源（`deploy.sh` 已处理）。

### 2. `bullseye-backports` 404

Debian 11 EOL，华为云 backports 镜像已下线。

**解法：** `sed -i '/bullseye-backports/d' /etc/apt/sources.list`

### 3. `dpkg-reconfigure` 在非交互 SSH 中卡死

**解法：** `export DEBIAN_FRONTEND=noninteractive` + 直接写配置文件代替 `dpkg-reconfigure`。

### 4. gpg 管道报错 `cannot open /dev/tty`

**解法：** `gpg --batch --yes --dearmor`

### 5. acme.sh `--issue` 退出码 2 中断脚本

证书已存在时返回 exit 2，触发 `set -e`。

**解法：** `|| { rc=$?; [[ $rc -eq 2 ]] && echo "skip" || exit $rc; }`

### 6. `--reloadcmd` 在容器未启动时报错

**解法：** reloadcmd 末尾加 `|| true`

### 7. 服务器无法拉取 Docker 镜像

Docker Hub 直连超时，NJU 403，百度 DNS 失败，GHCR 服务器端也超时。**所有国内镜像加速源均已失效（2026-02 测试）。**

**解法：** 本地 Mac 拉取后传入：

```bash
brew install crane
crane pull --platform linux/amd64 ghcr.io/dani-garcia/vaultwarden:latest /tmp/vw.tar
cat /tmp/vw.tar | ssh server "docker load"
```

### 8. Apple Silicon 拉 amd64 镜像失败

`docker pull --platform linux/amd64` 在 Docker Desktop for Apple Silicon 上无效，始终下载 arm64。

**解法：** 用 `crane`，它直接操作 OCI 镜像层，不经过 Docker Desktop。

### 9. nginx `cap_drop: ALL` 导致启动失败

```
nginx: [emerg] chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)
```

**解法：** 补回最小能力集 `cap_add: [CHOWN, SETUID, SETGID]`（Vaultwarden 容器不需要补回）。

---

## 安全加固清单

首次部署后做的安全审查改动：

- 镜像从 `:latest` 改为 `@sha256:` digest 固定（`scripts/pin-images.sh`）
- 容器 `cap_drop: ALL` + `no-new-privileges:true`
- `/admin` 默认 404，通过 `scripts/admin-panel.sh` 临时开启
- `deploy.sh` 敏感信息改为环境变量传入
- acme.sh 从 `curl | sh` 改为固定版本 tarball 安装
- 备份强制 `age` 公钥加密（拒绝明文备份）
- 异地备份：`rclone` + 坚果云 WebDAV

---

## 备份与恢复

**备份链路：** SQLite `.backup` → tar → age 加密 → rclone 同步至坚果云

**恢复：**
```bash
age --decrypt -i ~/vaultwarden-age-private.txt -o /tmp/backup.tar.gz backup.tar.gz.age
tar xzf /tmp/backup.tar.gz -C /tmp/restore
# 得到 db.sqlite3, attachments/, sends/
```

**重要：** age 私钥丢失 = 所有加密备份无法解密，务必妥善保管。

---

## 坚果云 WebDAV 配置要点

- 必须使用「应用密码」（坚果云 → 安全选项 → 第三方应用管理），不能用登录密码
- `rclone.conf` 中的 `pass` 需要用 `rclone obscure` 混淆后填入
- 模板见 `vaultwarden-deploy/rclone.conf`
