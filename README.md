# vaultwarden-deploy

国内云服务器部署 [Vaultwarden](https://github.com/dani-garcia/vaultwarden) 的配置文件和脚本。

针对国内环境做了适配：无 ICP 备案（8443 端口）、Docker Hub 被墙（crane 本地拉取）、DNS-01 证书验证等。

## 使用方式

### 用 Claude Code 部署（推荐）

把这个仓库 clone 到本地，然后告诉 Claude Code 你的服务器信息，让它参考这些配置帮你部署：

```
git clone https://github.com/bitA23187/vaultwarden-deploy.git
cd vaultwarden-deploy
claude   # 启动 Claude Code，告诉它你想部署 Vaultwarden
```

### 手动部署

参考 [DEPLOYMENT.md](./DEPLOYMENT.md) 中的说明。

## 部署前准备

这些需要你自己提前准备好：

1. **云服务器**（Debian 11/12），安全组开放 TCP 22 + 8443
2. **域名** + Cloudflare DNS（A 记录指向服务器，**DNS only 灰色云朵**）
3. **Cloudflare API Token**（Edit zone DNS 权限）
4. **age 密钥对**（备份加密用）：`brew install age && age-keygen -o ~/vaultwarden-age-private.txt`

## 文件说明

```
├── deploy.sh                    # 服务器一键初始化（系统更新→Docker→证书→fail2ban→启动）
├── docker-compose.yml           # Nginx + Vaultwarden 容器编排
├── .env.example                 # 环境变量模板（复制为 .env 后填写）
├── rclone.conf                  # 坚果云 WebDAV 模板（异地备份用）
├── nginx/
│   ├── vaultwarden.conf         # SSL + 限速 + 反代
│   ├── admin-location.disabled.inc  # /admin 默认策略（返回 404）
│   └── admin-location.enabled.inc   # /admin 维护模式
├── scripts/
│   ├── backup.sh                # 加密备份（age）+ 异地同步（rclone）
│   ├── admin-panel.sh           # /admin 面板开关
│   └── pin-images.sh            # 生成镜像 digest 引用
├── fail2ban/
│   ├── filter.d/vaultwarden.conf
│   └── jail.d/vaultwarden.conf
└── DEPLOYMENT.md                # 踩坑记录 + 架构说明
```

## 国内部署踩坑速查

| 问题 | 解法 |
|------|------|
| 80/443 端口不通（无备案） | 改用 8443；SSL 证书用 DNS-01 验证 |
| Docker Hub 被墙 | 本地 Mac 用 `crane` 拉镜像，SSH pipe 传入服务器 |
| 国内镜像加速源全部失效 | 同上，不依赖任何国内镜像站 |
| `get.docker.com` 被墙 | 用阿里云 Docker CE apt 源（deploy.sh 已处理） |
| Apple Silicon 拉不到 amd64 镜像 | 用 `crane`（Docker Desktop 指定 platform 无效） |
| Debian 11 backports 404 | deploy.sh 自动移除过期源 |

更多踩坑细节见 [DEPLOYMENT.md](./DEPLOYMENT.md)。

## 安全措施

- 华为云安全组 + ufw 双重防火墙
- Nginx 限速 + fail2ban（5 次失败 / 10 分钟 → 封禁 1 小时）
- Docker 容器 `cap_drop: ALL` + `no-new-privileges:true`
- `/admin` 面板默认 404，维护时临时开启
- ADMIN_TOKEN 使用 argon2id hash
- 每日自动备份：age 加密 → rclone 同步至坚果云

## License

MIT
