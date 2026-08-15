# 平台配置能力

OpenClash Docker 把稳定的处理逻辑放在镜像 hook 中，把部署差异放在可挂载的 YAML 中。订阅刷新或切换配置时，hook 只修改 OpenClash 生成的运行时配置，不改写下载到 `/etc/openclash/config` 的原始订阅文件。

常规扩展不需要修改镜像源码：新增订阅 profile、地区匹配、统一策略入口、自定义规则、DNS、hosts 或运行参数时，修改宿主机配置并重新生成活动配置即可。只有增加新的匹配语义、节点来源类型或 hook 行为时才需要更新镜像。

## 挂载与优先级

镜像内默认配置目录为：

```text
/usr/local/share/openclash-hooks/config
```

复制 Compose override 后，可以用宿主机目录覆盖它：

```sh
cp docker-compose.override.example.yml docker-compose.override.yml
```

```yaml
services:
  openclash:
    volumes:
      - ${OPENCLASH_HOOK_CONFIG_DIR:-./hooks/config}:/usr/local/share/openclash-hooks/config:ro
```

建议在 `.env` 中把 `OPENCLASH_HOOK_CONFIG_DIR` 指向部署机上的独立配置目录。该目录可以包含部署专用域名和地址，但不应纳入 Git；仓库的 `hooks/config` 只保存可以公开构建进镜像的默认模板。

挂载目录会完全覆盖镜像内的同一路径。更新镜像不会删除宿主机配置，也不会自动合并新的默认 YAML；配置 schema 升级时应参考仓库模板人工合并。

## 配置文件

| 文件 | 平台能力 | 对原订阅的影响 |
| --- | --- | --- |
| `proxy-groups.yaml` | 识别订阅、生成地区组、挂入订阅主组、生成兼容别名 | 保留订阅原有节点、规则和其他策略组 |
| `rules.yaml` | 在顶部或最终规则前插入本地规则 | 保留订阅原有规则顺序 |
| `hosts.yaml` | 合并 Clash hosts | 同名 host 由本地值覆盖 |
| `dns.yaml` | 管理 DNS 按规则路由与 fake-IP 例外 | 保留未管理的 DNS 字段 |
| `runtime.yaml` | 管理 sniffer 和 TUN DNS 劫持 | 保留未管理的运行参数 |
| `firewall-bypass.yaml` | 让指定 IPv4 目标或 UDP 端口在进入 TUN 前直连 | 不修改订阅 YAML |

所有 YAML 都带显式 `version`。未知字段、目标组缺失、多个 profile 同时匹配或循环引用会使 hook 失败；dispatcher 会恢复本次处理前的完整运行时配置。

## 订阅 profile

`proxy-groups.yaml` 的 `profiles` 用于描述不同订阅。平台不会按订阅文件名写死逻辑，而是根据生成配置的结构匹配 profile。一个配置必须只匹配一个 profile。

### Provider 订阅

Provider 型订阅通过 `proxy-providers` 名称和主策略组识别：

```yaml
profiles:
  - name: provider-subscription
    match:
      provider: providerName
      groups: [Proxy]
    source:
      type: provider
      provider: providerName
    regions:
      - hong-kong
      - singapore
      - japan
    prepend-to: Proxy
```

生成的地区组使用 `use` 和 `filter` 引用 provider，不复制 provider 节点。

### 内联节点订阅

内联订阅通过非空顶层 `proxies` 和订阅原生主组识别：

```yaml
profiles:
  - name: inline-subscription
    match:
      inline-proxies: true
      groups: [自定义主组]
    source:
      type: inline
    regions:
      - hong-kong
      - singapore
      - japan
    prepend-to: 自定义主组
    aliases:
      Proxy: 自定义主组
```

平台按地区正则从内联节点中生成 `url-test` 组，并跳过没有节点的地区。`prepend-to` 把“地区自动选择”放到订阅原生主组的首位。

`aliases` 提供跨订阅统一入口。上例仅在订阅缺少 `Proxy` 时生成：

```yaml
- name: Proxy
  type: select
  proxies: [自定义主组]
```

因此其他 hooks、规则和用户界面可以统一引用 `Proxy`。订阅若原生已有同名组，平台保留原组；若别名会形成循环引用，配置会被拒绝。

### 增加新订阅

1. 在 LuCI 中添加并更新订阅，不把订阅 URL 写入 hook 配置。
2. 查看生成 YAML 的节点来源：provider 使用 `proxy-providers`，普通订阅通常使用顶层 `proxies`。
3. 确认订阅自身稳定存在的主选择组名称。
4. 在 `profiles` 下增加唯一匹配项。
5. 从 `regions` 中选择该订阅需要的地区。
6. 若主组不叫 `Proxy`，通过 `aliases` 声明 `Proxy` 指向它。
7. 重启 OpenClash 或刷新订阅，检查只有目标 profile 被匹配。

## 地区自动组

地区定义与订阅 profile 位于同一个 `proxy-groups.yaml`。`regions` 保存地区名称和节点名称正则：

```yaml
regions:
  example-region:
    name: 示例地区自动
    filter: "(^🏳️|示例地区|Example Region)"
```

启用新地区时，还需要把 `example-region` 加入相应 profile 的 `regions` 数组。不同订阅可以选择不同地区集合，共用或分别调整同一套正则。

修改正则时应注意：

- 正则匹配节点名称，不匹配服务器地址。
- 内联订阅没有匹配节点时不会创建空组。
- 地区名称、selector 名称和兼容别名不能重名。
- 修改后应分别切换每一种订阅，确认地区节点数量和主组入口。

## 自定义规则

两套配置都具有统一的 `Proxy` 入口，因此需要代理的规则可以只写一份：

```yaml
version: 1
position: top
rules:
  - DOMAIN-SUFFIX,example.com,Proxy
  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
```

在 provider 订阅中，`Proxy` 使用订阅原生组；在内联订阅中，`Proxy` 通过 profile 别名进入它的原生主组。

`position` 支持：

- `top`：放在订阅规则之前，适合必须优先执行的直连或指定代理规则。
- `before-final`：放在第一个 `MATCH` 或 `FINAL` 之前，尽量保留订阅规则的优先级。

可选的 `remove` 数组按完整字符串删除旧规则。Hook 会在插入前删除相同规则，因此重复执行不会累积副本。

订阅更新端点必须直连时，可为其主机名增加 `DIRECT` 规则，但不要把完整订阅 URL、查询参数、令牌或签名写入仓库模板：

```yaml
rules:
  - DOMAIN-SUFFIX,subscription.example.com,DIRECT
```

## 其他 overrides

### DNS 与 fake-IP

`dns.yaml` 可以启用 `respect-rules`、补充 `fake-ip-filter`，并在订阅没有提供 `proxy-server-nameserver` 时复用其 `default-nameserver`。不要在这里整体复制订阅的 DNS 配置。

### Sniffer 与 TUN

`runtime.yaml` 只管理允许的 sniffer 布尔开关、缺失时使用的协议嗅探表和 `tun.dns-hijack`。未知运行参数会被拒绝，避免 override 演变成不受约束的整份配置替换。

### Hosts

`hosts.yaml` 合并到 Clash 的 `hosts`。适合需要固定解析结果的公开服务端点；可能轮换的地址需要定期复核。

### pre-TUN 直连

`firewall-bypass.yaml` 用于必须在进入 OpenClash TUN 前绕过的 IPv4 目标或 UDP 端口。它与 Clash `DIRECT` 规则处于不同层级，只应在规则层无法覆盖的场景使用。

## 应用与验证

仅修改已挂载的 YAML 后，不需要重建容器：

```sh
docker compose exec openclash /etc/init.d/openclash restart
```

也可以在 LuCI 中刷新订阅或切换配置，让 OpenClash 重新生成运行时 YAML。验证时至少检查：

```sh
docker compose ps
docker compose exec openclash /etc/init.d/openclash status
docker compose exec openclash tail -n 200 /tmp/openclash.log
```

对当前运行时配置执行 Mihomo 校验：

```sh
docker compose exec openclash sh -c '
  name="$(basename "$(uci -q get openclash.config.config_path)")"
  SAFE_PATHS=/usr/share/openclash:/etc/ssl \
    /etc/openclash/clash -t -d /etc/openclash -f "/etc/openclash/$name"
'
```

修改订阅 profile、地区或别名后，应逐一切换所有受支持订阅，确认核心没有 `Parse config error`，并检查：

- 活动配置文件名正确；
- `Proxy` 存在且没有循环引用；
- “地区自动选择”位于对应订阅主组；
- 空地区没有生成；
- 自定义规则目标都能解析到现有策略组。

## 备份与回滚

修改宿主机配置前先保存单文件备份：

```sh
cp -p hooks/config/proxy-groups.yaml hooks/config/proxy-groups.yaml.before-change
cp -p hooks/config/rules.yaml hooks/config/rules.yaml.before-change
```

验证失败时恢复对应文件，再重启 OpenClash：

```sh
cp -p hooks/config/proxy-groups.yaml.before-change hooks/config/proxy-groups.yaml
cp -p hooks/config/rules.yaml.before-change hooks/config/rules.yaml
docker compose exec openclash /etc/init.d/openclash restart
```

不要删除 LuCI 中的订阅或 `/etc/openclash/config` 下的原始配置来回滚 hook；hook 配置与订阅数据是相互独立的。
