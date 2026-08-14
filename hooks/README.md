# OpenClash 配置 Hook

这个目录提供一层默认启用、有序的本地配置，用于在 oixCloud 生成的配置上增加自定义内容。它使用 OpenClash 原生的 `openclash_custom_overwrite.sh` 入口，不修改下载的订阅文件。

## 目录结构

```text
hooks/
├── openclash_custom_overwrite.sh  # OpenClash 原生入口和 dispatcher
├── openclash_custom_firewall_rules.sh # pre-TUN 防火墙绕过入口
├── hooks.d/
│   ├── 10-custom-hosts.sh
│   ├── 15-custom-dns.sh
│   ├── 18-custom-runtime.sh
│   ├── 20-custom-proxy-groups.sh
│   └── 30-custom-rules.sh
└── config/
    ├── hosts.yaml
    ├── dns.yaml
    ├── runtime.yaml
    ├── firewall-bypass.yaml
    ├── proxy-groups.yaml
    └── rules.yaml
```

Hook 按文件名顺序同步执行。活动配置文件不存在时，对应 hook 直接跳过，因此仅挂载目录不会修改订阅。每个 hook 都直接读取和写回 OpenClash 生成的 YAML，并保证重复执行结果一致。dispatcher 在开始前保存完整配置；任一 hook 失败都会恢复原文件，避免留下部分修改。

## 默认启用与关闭

所有配置都会构建进镜像，`ENABLE_OPENCLASH_HOOKS` 默认为 `1`，首次启动时 entrypoint 会自动安装 dispatcher，不需要复制或改名文件：

```sh
docker compose up -d
```

不需要某项能力时，可以注释或删除对应 YAML 中的条目。若要整体关闭，在 `.env` 中设置 `ENABLE_OPENCLASH_HOOKS=0` 后重建容器；已经安装在持久化目录中的 dispatcher 也会识别这个开关并跳过内置 hooks。

如果使用已发布镜像但需要在宿主机直接编辑配置，可把 `docker-compose.override.example.yml` 复制为 `docker-compose.override.yml`，将本目录挂载到镜像的配置位置。更新配置后重启 OpenClash 或刷新订阅，使其重新生成活动配置并调用 dispatcher。

dispatcher、标准 hooks、默认 YAML 和防火墙入口都已内置在镜像中。容器启动时会把两个入口复制到 OpenClash 的持久化 `custom` 目录并设置执行权限。如果该位置已有不同脚本，entrypoint 会先保存为 `*.before-docker-hooks.sh`，然后由内置入口先执行保留脚本。

Docker 网桥到 LuCI 的放行规则不属于订阅配置 hooks。启用 `ENABLE_DOCKER_LUCI_ACCESS=1` 后，entrypoint 会注册独立的 fw4 include；本防火墙入口也会调用同一个幂等助手，在 OpenClash 重建 `input` 链后恢复规则。`ENABLE_OPENCLASH_HOOKS=0` 不会替代该功能的独立开关。

这些 YAML 受 Git 跟踪并进入 Docker build context。不要写入订阅 URL、令牌、账号或个人域名。`hosts.yaml` 中的 Vodafone 公网 ePDG 地址是部署所需的公开服务端点，可能由运营商轮换。

## 配置契约

- 每个活动配置都以 `version: 1` 开头。不支持的版本会直接失败，避免按错误 schema 静默处理。
- `hosts.yaml` 在 `hosts` 下保存 Clash hosts 映射；相同主机名会覆盖生成配置中的值。
- `dns.yaml` 可让 DNS 上游连接遵循代理规则，并在缺少 `proxy-server-nameserver` 时继承生成配置的 `default-nameserver` 作为代理节点引导解析；还可在 `fake-ip-filter.prepend` 中加入条目，并通过 `fake-ip-filter.remove` 删除旧条目。
- `runtime.yaml` 只允许管理四个 sniffer 布尔开关、缺失时使用的协议嗅探表和 `tun.dns-hijack`。其他 sniffer/TUN 设置会保留，未知字段会明确失败，避免它变成可覆盖任意 Clash 配置的入口。
- `proxy-groups.yaml` 在 `groups` 下保存标准 Clash 节点组。`prepend-to` 把自定义组加入现有选择器；`prepend-existing-to` 把一个已经存在的组加入可选的订阅选择器，目标不存在时跳过。`use` 引用的 provider 必须已存在于生成配置中。
- `rules.yaml` 包含 `rules` 数组、可选的 `remove` 数组和 `position`。`remove` 用于清理旧的精确规则；位置支持 `top` 和 `before-final`，后者会把新规则插在第一个 `MATCH` 或 `FINAL` 之前。
- `firewall-bypass.yaml` 的 `ipv4-destinations` 和 `udp-destination-ports` 会在 OpenClash mangle 链首加入 `return`，让指定流量在进入 TUN 前直连。脚本严格校验 IPv4 和端口格式，不执行 YAML 中的命令文本。

schema 错误、provider 不存在或目标组不存在时，hook 会明确失败，不会输出只修改了一部分的代理配置。

镜像 CI 会在 smoke-test 容器中执行 `test-hooks.sh` 和 `test-docker-luci-firewall.sh`。测试会连续应用两次全部示例，验证幂等性，确认原有 hosts、provider 节点组和订阅末尾规则没有丢失，并验证错误配置会触发完整回滚。防火墙助手测试另外覆盖窄化匹配、重复执行、端点变更、禁用清理和恶意配置拒绝。
