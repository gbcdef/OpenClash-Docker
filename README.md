# OpenClash Docker

在 Linux 主机上通过 Docker Compose 运行 OpenClash，提供 LuCI 管理界面、代理端口、DNS 和单臂旁路由能力。

这是一个独立的 Docker 打包项目，不包含也不派生自 OpenClash 的 Git 源码历史。镜像以官方 OpenWrt rootfs 为基础，在构建时下载并校验 `vernesong/OpenClash` 发布的 IPK，再通过 `opkg` 安装。仓库应作为独立 GitHub 仓库托管，而不是保留在 OpenClash 的 fork network 中。

- 镜像：`ghcr.io/gbcdef/openclash-docker:latest`
- 架构：amd64 / x86_64
- 配置方式：`docker-compose.yml` + `.env` + Compose secret
- 数据持久化：宿主机 `./data` 目录
- 内置 OpenClash：`v0.47.133`
- 上游 IPK SHA-256：`c2490630043ea7e3db91a8f0d079088bc39c6aab4dc283d292f302064f891b90`

> [!WARNING]
> 容器使用 `host` 网络和 `privileged` 权限，会操作宿主机的 TUN、路由与防火墙。请只在可信 Linux 主机上运行，不要把 LuCI、控制器、DNS 或无认证代理端口暴露到公网。

## 安装

需要 Docker Engine、Docker Compose plugin 2.6 或更高版本，以及 `/dev/net/tun`。

```sh
mkdir -p openclash-docker
cd openclash-docker
mkdir -p secrets data/config data/openclash

curl -fsSLO https://raw.githubusercontent.com/gbcdef/OpenClash-Docker/main/docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/gbcdef/OpenClash-Docker/main/.env.example -o .env
curl -fsSL https://raw.githubusercontent.com/gbcdef/OpenClash-Docker/main/secrets/root_password.example -o secrets/root_password.txt
chmod 600 .env secrets/root_password.txt
```

编辑 `.env`：

```sh
nano .env
nano secrets/root_password.txt
```

在 `.env` 中至少修改以下两项：

```dotenv
HOST_LAN_INTERFACE=eth0
LUCI_BIND=192.168.1.2
```

- `HOST_LAN_INTERFACE`：连接局域网的物理网卡，可通过 `ip -br link` 查看。
- `LUCI_BIND`：该网卡已经拥有的 IPv4 地址，可通过 `ip -4 -br addr` 查看。它也是 LuCI 和 DNS 的监听地址。

将 `secrets/root_password.txt` 的内容替换为 LuCI `root` 用户的强密码。该文件通过 Compose secret 挂载到容器，不会进入镜像、容器环境变量或 `docker inspect`。

确认 TUN 设备和最终配置：

```sh
test -c /dev/net/tun && echo TUN_OK
docker compose config
```

启动：

```sh
docker compose pull
docker compose up -d
docker compose ps
```

打开 `http://<LUCI_BIND>:18080/`，使用用户 `root` 和 `secrets/root_password.txt` 中的密码登录。

`docker compose ps` 显示的 `healthy` 只表示 OpenWrt、ubus 和 LuCI 基础服务正常。OpenClash 首次启动时默认关闭，需要导入配置并在 LuCI 中启动。

## `.env` 配置

普通部署配置都在 `.env` 中完成；LuCI 密码单独保存在 Compose secret 文件中：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OPENCLASH_IMAGE` | `ghcr.io/gbcdef/openclash-docker:latest` | GitHub 镜像地址，也可固定为 `sha-<commit>` 标签 |
| `CONTAINER_NAME` | `openclash` | 容器名称 |
| `RESTART_POLICY` | `unless-stopped` | 容器重启策略 |
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `ROOT_PASSWORD_FILE` | `./secrets/root_password.txt` | LuCI 密码 secret 文件路径 |
| `DATA_DIR` | `./data` | OpenWrt 和 OpenClash 持久化数据目录 |
| `HOST_LAN_INTERFACE` | 必须修改 | 宿主机 LAN 网卡 |
| `LUCI_BIND` | `127.0.0.1` | LuCI 与 DNS 的监听地址 |
| `LUCI_PORT` | `18080` | LuCI HTTP 端口 |
| `MIXED_PROXY_PORT` | `7890` | Mixed 代理端口 |
| `SOCKS_PROXY_PORT` | `7891` | SOCKS5 代理端口 |
| `REDIR_PROXY_PORT` | `7892` | Redir 代理端口 |
| `HTTP_PROXY_PORT` | `7893` | HTTP 代理端口 |
| `TPROXY_PORT` | `7895` | TProxy 端口 |
| `DNS_PORT` | `7874` | OpenClash DNS 端口 |
| `CONTROLLER_PORT` | `9090` | OpenClash Controller 端口 |
| `REQUIRE_OPENCLASH_HEALTHY` | `0` | 设为 `1` 后，Compose 健康检查同时要求核心、TUN、策略路由和监听端口正常 |

`.env` 和 `secrets/root_password.txt` 都已被 Git 忽略。密码文件必须保持权限为 `600`，不要上传到 Git 或发送给他人。仓库中的 `secrets/root_password.example` 只是可公开的格式模板，不包含真实密码。

## Docker Compose 使用

查看状态和日志：

```sh
docker compose ps
docker compose logs -f --tail=200 openclash
```

分别检查容器基础服务和 OpenClash 运行状态：

```sh
# OpenWrt、ubus 和 LuCI 是否正常；Compose healthcheck 使用这一项
docker compose exec openclash /usr/local/sbin/container-healthcheck

# OpenClash 是否已经启用，并且对应的 procd 实例确实在运行
docker compose exec openclash /usr/local/sbin/openclash-healthcheck
```

第二个命令还会检查核心可执行文件、TUN、策略路由、DNS 和 Mixed 监听端口。默认不会因此把基础容器标记为 unhealthy；完成 OpenClash 配置并验证运行正常后，可在 `.env` 设置 `REQUIRE_OPENCLASH_HEALTHY=1`，获得与生产部署一致的严格健康检查。

重启或停止：

```sh
docker compose restart openclash
docker compose stop
docker compose start
```

更新到最新 GitHub 镜像：

```sh
docker compose pull
docker compose up -d
docker image prune -f
```

功能分支可从 GitHub Actions 手动运行镜像工作流。分支构建会发布独立的 `branch-<分支名>` 和不可变的 `sha-<提交>` 标签，不会覆盖 `latest`；远端验证应优先在 `.env` 固定 `sha-<提交>`，确认无误后再合并到 `main`。

删除容器但保留 `DATA_DIR` 中的 OpenClash 配置与订阅：

```sh
docker compose down
```

以下备份和重置命令假定 `DATA_DIR=./data`；如果修改过该变量，请替换为实际目录。

备份数据目录：

```sh
tar -czf "openclash-data-$(date +%Y%m%d-%H%M%S).tar.gz" data/
```

需要完全重置时，先停止容器并把现有目录移动为备份，再重新启动：

```sh
docker compose down
mv data "data.backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p data/config data/openclash
docker compose up -d
```

首次启动且目标目录为空时，容器会自动写入 OpenWrt 和 OpenClash 默认文件。升级或重建容器不会覆盖已有数据。

## 上游版本与构建验证

默认构建固定使用 OpenClash `v0.47.133`，不会在每次构建时自动漂移到 `latest`。构建脚本精确下载：

```text
https://github.com/vernesong/OpenClash/releases/download/v0.47.133/luci-app-openclash_0.47.133_all.ipk
```

下载后必须匹配仓库中固定的 SHA-256，否则构建立刻失败。CI 还会真正启动刚构建的镜像，等待基础容器健康，并确认：

- LuCI/OpenWrt 基础服务可以响应；
- `luci-app-openclash` 已安装且版本正确；
- `/etc/init.d/openclash` 存在；
- OpenClash 初始保持关闭，且独立运行状态检查不会误报成功。

升级 OpenClash 时，需要同时更新 `Dockerfile` 和 GitHub Actions 中的版本与 SHA-256。摘要必须取自对应 GitHub Release asset 的 `digest` 字段，不能只修改版本或绕过校验。也可以离线提供 `vendor/openclash.ipk`，但它仍必须与构建参数传入的 SHA-256 一致。

## OpenClash 配置

### 推荐：切换 oixCloud 专用内核

该 Docker 版本可以安装并运行 oixCloud 专用内核。OpenClash 已内置 oixCloud 登录集成，登录后会**自动下载 oixCloud 专用内核并导入专用订阅**。专用内核已内置所需的 DNS 分流与规则，无需再手动补充 DNS 配置，是 OpenClash 用户更省心的使用方案。

如尚无账号，可前往 [oixCloud 注册](https://oixcloud.com/auth/register?affid=30328)。

首次登录 LuCI 后：

1. 打开“服务 → OpenClash”。
2. 进入“插件设置 → oixCloud”，登录 oixCloud 账号。
3. 等待专用内核自动下载和专用订阅导入完成。
4. 确认活动配置启用了 `allow-lan`，并使用 `.env` 中配置的代理端口。
5. 启动或重启 OpenClash，检查运行状态。

也可以不使用 oixCloud，直接在 OpenClash 中导入其他兼容订阅。

账号、订阅 URL 和节点配置只应在 LuCI 中填写。它们保存在 `${DATA_DIR}/openclash` 目录中，不应写入 `.env` 或 Compose 文件。

### 在 oixCloud 订阅上叠加本地配置

仓库提供了一个可选、按顺序执行的 [hooks 目录](hooks/README.md)，通过 OpenClash 原生的 `openclash_custom_overwrite.sh` 在每次配置生成后叠加本地能力，不修改下载的 oixCloud 订阅文件：

```text
10-custom-hosts.sh         合并自定义 hosts
15-custom-dns.sh           管理 fake-IP 过滤条目
20-custom-proxy-groups.sh  创建节点组并挂入已有 Proxy 选择器
30-custom-rules.sh         在 MATCH/FINAL 前插入自定义规则
custom firewall hook       让指定目标或 UDP 端口在进入 TUN 前直连
```

启用需要先复制示例配置和 Compose override：

```sh
cp hooks/config/hosts.example.yaml hooks/config/hosts.yaml
cp hooks/config/dns.example.yaml hooks/config/dns.yaml
cp hooks/config/firewall-bypass.example.yaml hooks/config/firewall-bypass.yaml
cp hooks/config/proxy-groups.example.yaml hooks/config/proxy-groups.yaml
cp hooks/config/rules.example.yaml hooks/config/rules.yaml
cp docker-compose.override.example.yml docker-compose.override.yml
docker compose up -d
```

随后编辑需要启用的非示例 YAML，删除文档占位值并写入自己的配置，再更新订阅或重启 OpenClash。活动配置文件已被 Git 和 Docker build context 忽略。仓库示例只使用 `example.test`、`192.0.2.0/24` 等保留的文档值，不包含个人域名、用户名、订阅 URL 或公网地址。

hook 执行程序已经内置在 GitHub 镜像中，部署机只需保留私有 YAML 和 Compose override。若没有克隆仓库，可单独下载公开的配置示例和 override；不要把改名后的活动 YAML 提交到 Git。

宿主机使用 Mixed 代理的示例：

```sh
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export all_proxy=socks5h://127.0.0.1:7891
```

## 排障

```sh
docker compose exec openclash ubus call system board
docker compose exec openclash /etc/init.d/openclash status
docker compose exec openclash logread -e openclash
docker compose exec openclash tail -n 200 /tmp/openclash.log
```

如果 LuCI 无法访问，确认：

- `HOST_LAN_INTERFACE` 确实存在；
- `LUCI_BIND` 已配置在该网卡上；
- `LUCI_PORT` 未被其他程序占用；
- 宿主机防火墙允许可信局域网访问该端口。

## 项目与许可

OpenClash IPK 来自 [vernesong/OpenClash Releases](https://github.com/vernesong/OpenClash/releases)。本仓库只维护 Docker 打包、启动和持久化逻辑，不复制或维护 OpenClash 源码。本仓库采用 [MIT License](LICENSE)，OpenClash、OpenWrt、Mihomo 及其第三方组件仍受各自许可证约束。
