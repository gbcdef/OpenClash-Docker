# OpenClash 配置 Hook

这个目录提供一层可选、有序的本地配置，用于在 oixCloud 生成的配置上增加自定义内容。它使用 OpenClash 原生的 `openclash_custom_overwrite.sh` 入口，不修改下载的订阅文件。

## 目录结构

```text
hooks/
├── openclash_custom_overwrite.sh  # OpenClash 原生入口和 dispatcher
├── openclash_custom_firewall_rules.sh # pre-TUN 防火墙绕过入口
├── hooks.d/
│   ├── 10-custom-hosts.sh
│   ├── 15-custom-dns.sh
│   ├── 20-custom-proxy-groups.sh
│   └── 30-custom-rules.sh
└── config/
    ├── hosts.example.yaml
    ├── dns.example.yaml
    ├── firewall-bypass.example.yaml
    ├── proxy-groups.example.yaml
    └── rules.example.yaml
```

Hook 按文件名顺序同步执行。活动配置文件不存在时，对应 hook 直接跳过，因此仅挂载目录不会修改订阅。每个 hook 都直接读取和写回 OpenClash 生成的 YAML，并保证重复执行结果一致。dispatcher 在开始前保存完整配置；任一 hook 失败都会恢复原文件，避免留下部分修改。

## 启用

只复制需要的示例，删除其中的文档占位值，再换成本地配置：

```sh
cp hooks/config/hosts.example.yaml hooks/config/hosts.yaml
cp hooks/config/dns.example.yaml hooks/config/dns.yaml
cp hooks/config/firewall-bypass.example.yaml hooks/config/firewall-bypass.yaml
cp hooks/config/proxy-groups.example.yaml hooks/config/proxy-groups.yaml
cp hooks/config/rules.example.yaml hooks/config/rules.yaml
cp docker-compose.override.example.yml docker-compose.override.yml
docker compose up -d
```

随后重启 OpenClash 或更新订阅，使 OpenClash 重新生成活动配置并调用 dispatcher。

dispatcher、标准 hooks 和防火墙入口已经内置在 GitHub 镜像中；Compose override 只把私有 YAML 挂载到 `/etc/openclash-hooks/config`。容器启动时会把两个入口复制到 OpenClash 的持久化 `custom` 目录并设置执行权限。如果该位置已有不同的脚本，entrypoint 会先保存为 `*.before-docker-hooks.sh`，然后由内置入口先执行保留脚本。

活动 `*.yaml` 已被 Git 和 Docker build context 忽略。不要在受版本控制的示例中放入订阅 URL、令牌、账号、个人域名或公网 IP。仓库示例只使用保留的文档域名和地址段。

## 配置契约

- 每个活动配置都以 `version: 1` 开头。不支持的版本会直接失败，避免按错误 schema 静默处理。
- `hosts.yaml` 在 `hosts` 下保存 Clash hosts 映射；相同主机名会覆盖生成配置中的值。
- `dns.yaml` 可在 `fake-ip-filter.prepend` 中加入条目，并通过 `fake-ip-filter.remove` 删除旧条目。
- `proxy-groups.yaml` 在 `groups` 下保存标准 Clash 节点组。`prepend-to` 把自定义组加入现有选择器；`prepend-existing-to` 把一个已经存在的组加入可选的订阅选择器，目标不存在时跳过。`use` 引用的 provider 必须已存在于生成配置中。
- `rules.yaml` 包含 `rules` 数组、可选的 `remove` 数组和 `position`。`remove` 用于清理旧的精确规则；位置支持 `top` 和 `before-final`，后者会把新规则插在第一个 `MATCH` 或 `FINAL` 之前。
- `firewall-bypass.yaml` 的 `ipv4-destinations` 和 `udp-destination-ports` 会在 OpenClash mangle 链首加入 `return`，让指定流量在进入 TUN 前直连。脚本严格校验 IPv4 和端口格式，不执行 YAML 中的命令文本。

schema 错误、provider 不存在或目标组不存在时，hook 会明确失败，不会输出只修改了一部分的代理配置。

镜像 CI 会在 smoke-test 容器中执行 `test-hooks.sh`。测试会连续应用两次全部示例，验证幂等性，确认原有 hosts、provider 节点组和订阅末尾规则没有丢失，并验证错误配置会触发完整回滚。
