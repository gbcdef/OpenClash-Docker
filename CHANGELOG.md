# 更新日志

本文档记录 OpenClash Docker 镜像、容器启动流程、构建发布和仓库内置配置的主要变更。

本项目默认在构建时安装当时最新的 OpenClash，因此 OpenClash 插件自身的功能变化请查阅
[vernesong/OpenClash Releases](https://github.com/vernesong/OpenClash/releases)。本文档不重复维护上游的完整更新记录。

## 维护约定

- 尚未发布的变更记录在“未发布”章节。
- 镜像发布后，将对应条目移动到以 `YYYY-MM-DD` 命名的章节。
- 条目按“新增、变更、修复、安全”分类，只记录对构建、部署或运行行为有实际影响的内容。
- 不在日志中记录账号、密码、令牌、订阅地址或节点配置。

## 未发布

### 新增

- 地区代理组 hook 新增来源感知 profile：保持 oixCloud provider 的 21 个地区组，同时支持为带独立规则的内联节点订阅生成非空地区组，并额外识别中国大陆、阿联酋、巴基斯坦、乌克兰和越南。
- `dev` 分支推送自动构建 `latest-dev` 测试镜像；`main` 仍只发布 `latest`。

### 修复

- 内联订阅缺少统一入口时生成 `Proxy` 兼容组并指向其原生主组，让自定义规则可在两套订阅中统一使用 `Proxy`，避免切换后核心启动失败。
- host 网络模式下将 OpenWrt 逻辑 LAN 映射到实际的 `HOST_LAN_INTERFACE`，避免 dnsmasq、fw4 和 OpenClash 继续访问不存在的默认 `br-lan/eth0`。
- DNS hook 启用按规则路由上游连接，并在订阅未提供 `proxy-server-nameserver` 时复用其 `default-nameserver`，修复境外 fallback DoH 被直连阻断后持续解析超时的问题。
- 新增默认关闭的 Docker 网桥到 LuCI 最小权限放行规则，严格匹配声明的源 CIDR、`LUCI_BIND` 和 `LUCI_PORT/tcp`，并在 fw4 reload 和 OpenClash 防火墙重建后幂等恢复。
- 在缺少 `/etc/config/system` 时自动创建最小 OpenWrt system 配置，确保 `logd`、`/dev/log` 和 `dnsmasq` 正常启动，避免 DNS 劫持启用后因本机 53 端口无人监听而造成网络中断。
- host 网络模式下自动将现有 `docker0` 和 `br-*` 网桥的 IPv4 网关加入 dnsmasq 监听地址，并仅允许 Docker 私网来源访问本机 53 端口，修复普通 Docker 容器的 DNS 请求经 OpenClash 重定向后被拒绝的问题。
- 基础健康检查和 CI 新增 `system` 配置、日志 socket 与 `dnsmasq` 回归校验。

## 2026-08-14

### 新增

- 构建时解析并安装最新 OpenClash IPK，不再要求容器首次启动后交互下载。
- 镜像预置最新 x86_64 oixCloud 内核、GeoIP、GeoSite、Country/ASN MMDB，以及 IPv4/IPv6 China route 数据；持久化目录缺少对应资产时从镜像本地补齐。
- 增加 oixCloud 订阅安全同步助手和自动化测试，覆盖成功同步、HTTP 错误、无效 YAML、非 HTTPS 地址、带空格路径、旧配置保留和临时文件清理。
- 增加容器控制台开关 `ENABLE_CONTAINER_CONSOLE`，默认值为 `0`。

### 变更

- GitHub Actions 仅在推送到 `main` 分支或 `v*` 标签时构建镜像，不再定时构建。
- 镜像构建对 oixCloud Controller 补丁应用源码签名校验；上游相关代码变化时主动停止构建，要求人工复核兼容性。
- 容器重建或重启时保留已有 OpenWrt、OpenClash 配置和订阅数据，仅为空目录初始化默认内容。
- oixCloud 登录成功与订阅同步成功分别处理；同步失败时保留认证状态并向界面返回明确错误。

### 修复

- 修复 BusyBox `find` 不支持 `-quit` 导致的入口脚本兼容性问题。
- 修复 OpenWrt 正常关机后容器根文件系统保持只读、导致 Docker 重启失败的问题。
- 修复持久化初始化标记写入时机不正确、可能被 `uci commit` 清除的问题。
- 修复设置 root 密码成功信息进入容器启动日志的问题。
- 修复 oixCloud 配置目录不存在、下载失败或内容无效时仍直接覆盖现有配置的问题；新流程先下载到同目录临时文件，校验 Clash YAML 后以 `0600` 权限原子替换。
- 修复 oixCloud 请求参数直接拼接到 shell 命令带来的空格、特殊字符和命令注入风险。

### 安全

- 默认删除 OpenWrt `/etc/inittab` 中的 `askfirst` 和 `askconsole` 登录项，避免特权容器打开或读取宿主机 `ttyS0`、`hvc0`、`tty1` 等控制台设备。
- oixCloud 订阅同步仅允许 HTTPS，并限制重定向后的协议仍为 HTTPS。

## 2026-08-09

### 新增

- 发布独立的 OpenClash Docker 项目和 amd64 镜像。
- 提供 Docker Compose、Compose secret、持久化数据目录、基础健康检查和 OpenClash 专用健康检查。
- 提供默认启用的 OpenClash 配置 hooks，支持 hosts、DNS、运行参数、代理组、规则和防火墙扩展。
- `main` 分支发布 `latest` 与不可变的 `sha-<提交>` 镜像标签，`v*` Git 标签发布对应版本标签。

### 变更

- OpenClash 已安装在镜像中，但首次启动默认保持关闭；导入有效配置后由用户启用。
