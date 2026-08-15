#!/bin/sh
set -eu

SOURCE_ROOT="$(CDPATH= cd "$(dirname "$0")" && pwd)"
TEST_ROOT="/tmp/openclash-hooks-test.$$"
CONFIG_FILE="${TEST_ROOT}/generated.yaml"
INLINE_CONFIG_FILE="${TEST_ROOT}/inline-generated.yaml"
NATIVE_ALIAS_CONFIG_FILE="${TEST_ROOT}/native-alias-generated.yaml"
CYCLIC_ALIAS_CONFIG_FILE="${TEST_ROOT}/cyclic-alias-generated.yaml"
LEGACY_CONFIG_FILE="${TEST_ROOT}/legacy-generated.yaml"
UNMATCHED_CONFIG_FILE="${TEST_ROOT}/unmatched-generated.yaml"

cleanup() {
  case "${TEST_ROOT}" in
    /tmp/openclash-hooks-test.*) rm -rf "${TEST_ROOT}" ;;
    *) echo "refusing to remove unexpected test path: ${TEST_ROOT}" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "${TEST_ROOT}/config"
cp -a "${SOURCE_ROOT}/hooks.d" "${TEST_ROOT}/hooks.d"
cp "${SOURCE_ROOT}/config/hosts.yaml" "${TEST_ROOT}/config/hosts.yaml"
cp "${SOURCE_ROOT}/config/dns.yaml" "${TEST_ROOT}/config/dns.yaml"
cp "${SOURCE_ROOT}/config/runtime.yaml" "${TEST_ROOT}/config/runtime.yaml"
cp "${SOURCE_ROOT}/config/proxy-groups.yaml" "${TEST_ROOT}/config/proxy-groups.yaml"
cp "${SOURCE_ROOT}/config/rules.yaml" "${TEST_ROOT}/config/rules.yaml"
cp "${SOURCE_ROOT}/config/firewall-bypass.yaml" "${TEST_ROOT}/config/firewall-bypass.yaml"

# Exercise a private proxy rule against both source-specific main groups.
ruby -ryaml -E UTF-8 - "${TEST_ROOT}/config/rules.yaml" <<'RUBY'
path = ARGV.fetch(0)
value = YAML.load_file(path)
value.fetch('rules') << 'DOMAIN,proxy-required.example.test,Proxy'
File.open(path, 'w') { |file| YAML.dump(value, file) }
RUBY

cat > "${CONFIG_FILE}" <<'YAML'
hosts:
  existing.example.test: 192.0.2.30
sniffer:
  enable: false
  skip-domain:
    - existing.example.test
tun:
  enable: true
  dns-hijack:
    - tcp://8.8.8.8:53
dns:
  default-nameserver:
    - 192.0.2.53
  fake-ip-filter:
    - "+.existing.example.test"
proxy-providers:
  oixCloud:
    type: http
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT
  - name: Microsoft
    type: select
    proxies:
      - DIRECT
rules:
  - DOMAIN-SUFFIX,tailscale.com,DIRECT
  - DOMAIN-SUFFIX,obsolete.example.test,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
YAML

OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${CONFIG_FILE}"
FIRST_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"

# A second pass must produce exactly the same output.
OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
  OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${CONFIG_FILE}"
SECOND_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
[ "${FIRST_SHA256}" = "${SECOND_SHA256}" ]

# An explicit opt-out must remain effective even when the dispatcher was
# installed into a persistent OpenClash custom directory by an earlier start.
BEFORE_DISABLED_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
ENABLE_OPENCLASH_HOOKS=0 \
OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${CONFIG_FILE}"
AFTER_DISABLED_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
[ "${BEFORE_DISABLED_SHA256}" = "${AFTER_DISABLED_SHA256}" ]

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" <<'RUBY'
value = YAML.load_file(ARGV.fetch(0))

raise 'existing host was lost' unless value.dig('hosts', 'existing.example.test') == '192.0.2.30'
unless value.dig('hosts', 'epdg.epc.mnc002.mcc262.pub.3gppnetwork.org') == '139.7.117.168'
  raise 'Vodafone Germany ePDG host was not added'
end
vodafone_uk = ['148.252.188.96', '88.82.11.208', '88.82.11.221']
unless value.dig('hosts', 'epdg.epc.mnc015.mcc234.pub.3gppnetwork.org') == vodafone_uk
  raise 'Vodafone UK 3GPP ePDG hosts were not added'
end
unless value.dig('hosts', 'epdg.vodafone.co.uk') == vodafone_uk
  raise 'Vodafone UK ePDG hosts were not added'
end

filters = value.dig('dns', 'fake-ip-filter')
raise 'ts.net fake-IP filter was not prepended' unless filters.first == '+.ts.net'
raise 'DNS queries do not respect routing rules' unless value.dig('dns', 'respect-rules') == true
unless value.dig('dns', 'proxy-server-nameserver') == ['192.0.2.53']
  raise 'proxy node DNS bootstrap was not inherited from default-nameserver'
end

sniffer = value.fetch('sniffer')
%w[enable force-dns-mapping parse-pure-ip override-destination].each do |key|
  raise "sniffer #{key} was not enabled" unless sniffer[key] == true
end
unless sniffer['skip-domain'] == ['existing.example.test']
  raise 'existing sniffer settings were not preserved'
end
unless sniffer.dig('sniff', 'HTTP', 'ports') == [80, '8080-8880']
  raise 'default HTTP sniffer ports were not added'
end
raise 'TUN DNS hijack was not replaced' unless value.dig('tun', 'dns-hijack') == ['any:53']
raise 'existing TUN settings were not preserved' unless value.dig('tun', 'enable') == true

groups = value.fetch('proxy-groups')
names = groups.map { |group| group['name'] }
region_names = [
  '香港自动', '台湾自动', '新加坡自动', '日本自动', '韩国自动', '美国自动',
  '俄罗斯自动', '加拿大自动', '印度自动', '土耳其自动', '墨西哥自动',
  '尼日利亚自动', '巴西自动', '德国自动', '法国自动', '泰国自动',
  '澳大利亚自动', '英国自动', '菲律宾自动', '阿根廷自动', '马来西亚自动'
]
selector = groups.find { |group| group['name'] == '地区自动选择' }
raise 'custom selector was not added' unless selector
raise 'regional selector choices are incomplete' unless selector['proxies'] == region_names
region_groups = groups.select { |group| region_names.include?(group['name']) }
raise 'expected exactly 21 regional groups' unless region_groups.length == 21
region_groups.each do |group|
  raise "#{group['name']} is not url-test" unless group['type'] == 'url-test'
  raise "#{group['name']} does not use oixCloud" unless group['use'] == ['oixCloud']
  raise "#{group['name']} has the wrong test URL" unless group['url'] == 'http://cp.cloudflare.com/generate_204'
  raise "#{group['name']} has the wrong interval" unless group['interval'] == 3600
end
proxy = groups.find { |group| group['name'] == 'Proxy' }
raise 'custom selector was not exposed in Proxy' unless proxy['proxies'].first == '地区自动选择'
microsoft = groups.find { |group| group['name'] == 'Microsoft' }
raise 'existing group was not prepended' unless microsoft['proxies'].first == 'Proxy'

rules = value.fetch('rules')
private_bypasses = [
  'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
  'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve'
]
raise 'RFC1918 bypasses are not first' unless rules.first(3) == private_bypasses
console_rule = rules.index('DOMAIN,console.tailscale.com,Proxy')
tailscale_direct = rules.index('DOMAIN-SUFFIX,tailscale.com,DIRECT')
unless console_rule && tailscale_direct && console_rule < tailscale_direct
  raise 'Tailscale console Proxy rule does not precede the subscription DIRECT rule'
end
unless rules.include?('DOMAIN,proxy-required.example.test,Proxy')
  raise 'available Oix rule target was unexpectedly remapped'
end
raise 'subscription final rule was lost' unless rules.last == 'MATCH,Proxy'
RUBY

# A self-contained inline subscription keeps its own rules and proxy groups.
# Only regional url-test groups and the selector are generated from its nodes.
cat > "${INLINE_CONFIG_FILE}" <<'YAML'
hosts: {}
sniffer:
  enable: false
tun:
  enable: true
dns:
  default-nameserver:
    - 192.0.2.53
  fake-ip-filter: []
proxies:
  - {name: "🇭🇰 香港 01", type: direct}
  - {name: "🇨🇳 台湾 01", type: direct}
  - {name: "🇸🇬 新加坡 01", type: direct}
  - {name: "🇨🇳 上海 01", type: direct}
  - {name: "🇦🇪 迪拜 01", type: direct}
  - {name: "🇵🇰 巴基斯坦 01", type: direct}
  - {name: "🇺🇦 乌克兰 01", type: direct}
  - {name: "🇻🇳 越南 01", type: direct}
  - {name: "未分类 01", type: direct}
proxy-groups:
  - name: 守候网络
    type: select
    proxies:
      - "🇭🇰 香港 01"
      - "🇨🇳 台湾 01"
      - "🇸🇬 新加坡 01"
      - "🇨🇳 上海 01"
      - "🇦🇪 迪拜 01"
      - "🇵🇰 巴基斯坦 01"
      - "🇺🇦 乌克兰 01"
      - "🇻🇳 越南 01"
      - "未分类 01"
  - name: Microsoft
    type: select
    proxies:
      - 守候网络
      - DIRECT
  - name: 漏网之鱼
    type: select
    proxies:
      - 守候网络
      - DIRECT
rules:
  - DOMAIN-SUFFIX,tailscale.com,DIRECT
  - DOMAIN-SUFFIX,inline.example.test,Microsoft
  - MATCH,漏网之鱼
YAML

OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${INLINE_CONFIG_FILE}"
INLINE_FIRST_SHA256="$(sha256sum "${INLINE_CONFIG_FILE}" | awk '{print $1}')"
OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${INLINE_CONFIG_FILE}"
INLINE_SECOND_SHA256="$(sha256sum "${INLINE_CONFIG_FILE}" | awk '{print $1}')"
[ "${INLINE_FIRST_SHA256}" = "${INLINE_SECOND_SHA256}" ]

ruby -ryaml -E UTF-8 - "${INLINE_CONFIG_FILE}" <<'RUBY'
value = YAML.load_file(ARGV.fetch(0))
groups = value.fetch('proxy-groups')
expected_regions = [
  '香港自动', '台湾自动', '新加坡自动', '中国大陆自动', '阿联酋自动',
  '巴基斯坦自动', '乌克兰自动', '越南自动'
]
selector = groups.find { |group| group['name'] == '地区自动选择' }
raise 'inline regional selector was not added' unless selector
unless selector['proxies'] == expected_regions
  raise "inline regional selector choices are wrong: #{selector['proxies'].inspect}"
end
raise 'empty inline region was not skipped' if groups.any? { |group| group['name'] == '日本自动' }

expected_nodes = {
  '香港自动' => ['🇭🇰 香港 01'],
  '台湾自动' => ['🇨🇳 台湾 01'],
  '新加坡自动' => ['🇸🇬 新加坡 01'],
  '中国大陆自动' => ['🇨🇳 上海 01'],
  '阿联酋自动' => ['🇦🇪 迪拜 01'],
  '巴基斯坦自动' => ['🇵🇰 巴基斯坦 01'],
  '乌克兰自动' => ['🇺🇦 乌克兰 01'],
  '越南自动' => ['🇻🇳 越南 01']
}
expected_nodes.each do |name, nodes|
  group = groups.find { |candidate| candidate['name'] == name }
  raise "inline regional group is missing: #{name}" unless group
  raise "#{name} is not url-test" unless group['type'] == 'url-test'
  raise "#{name} has the wrong nodes" unless group['proxies'] == nodes
  raise "#{name} unexpectedly uses a provider" if group.key?('use')
  raise "#{name} unexpectedly kept a provider filter" if group.key?('filter')
end

main_group = groups.find { |group| group['name'] == '守候网络' }
unless main_group['proxies'].first == '地区自动选择'
  raise 'inline regional selector was not exposed in the subscription main group'
end
proxy_alias = groups.find { |group| group['name'] == 'Proxy' }
unless proxy_alias == {'name' => 'Proxy', 'type' => 'select', 'proxies' => ['守候网络']}
  raise 'inline Proxy compatibility group does not point to the subscription main group'
end
microsoft = groups.find { |group| group['name'] == 'Microsoft' }
unless microsoft['proxies'].first == '守候网络'
  raise 'provider-specific prepend rules leaked into the inline profile'
end

rules = value.fetch('rules')
console_rule = rules.index('DOMAIN,console.tailscale.com,Proxy')
tailscale_direct = rules.index('DOMAIN-SUFFIX,tailscale.com,DIRECT')
unless console_rule && tailscale_direct && console_rule < tailscale_direct
  raise 'inline Tailscale console Proxy rule does not precede the subscription DIRECT rule'
end
unless rules.include?('DOMAIN,proxy-required.example.test,Proxy')
  raise 'custom Proxy rule was not inherited by the inline compatibility group'
end
raise 'inline subscription rule was lost' unless rules.include?('DOMAIN-SUFFIX,inline.example.test,Microsoft')
raise 'inline subscription final rule was lost' unless rules.last == 'MATCH,漏网之鱼'
RUBY

# A subscription-native Proxy group wins over the compatibility alias.
cat > "${NATIVE_ALIAS_CONFIG_FILE}" <<'YAML'
proxies:
  - {name: "🇭🇰 香港 01", type: direct}
proxy-groups:
  - {name: 守候网络, type: select, proxies: ["🇭🇰 香港 01"]}
  - {name: Proxy, type: select, proxies: [DIRECT]}
rules:
  - MATCH,Proxy
YAML
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${TEST_ROOT}/hooks.d/20-custom-proxy-groups.sh" "${NATIVE_ALIAS_CONFIG_FILE}"
ruby -ryaml -E UTF-8 - "${NATIVE_ALIAS_CONFIG_FILE}" <<'RUBY'
value = YAML.load_file(ARGV.fetch(0))
proxy = value.fetch('proxy-groups').find { |group| group['name'] == 'Proxy' }
raise 'subscription-native Proxy group was overwritten' unless proxy['proxies'] == ['DIRECT']
RUBY

# Refuse to generate Proxy -> 守候网络 when 守候网络 already points to Proxy.
cat > "${CYCLIC_ALIAS_CONFIG_FILE}" <<'YAML'
proxies:
  - {name: "🇭🇰 香港 01", type: direct}
proxy-groups:
  - {name: 守候网络, type: select, proxies: [Proxy, "🇭🇰 香港 01"]}
rules:
  - MATCH,守候网络
YAML
CYCLIC_ALIAS_BEFORE_SHA256="$(sha256sum "${CYCLIC_ALIAS_CONFIG_FILE}" | awk '{print $1}')"
if OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${TEST_ROOT}/hooks.d/20-custom-proxy-groups.sh" "${CYCLIC_ALIAS_CONFIG_FILE}"; then
  echo "cyclic compatibility alias unexpectedly succeeded" >&2
  exit 1
fi
CYCLIC_ALIAS_AFTER_SHA256="$(sha256sum "${CYCLIC_ALIAS_CONFIG_FILE}" | awk '{print $1}')"
[ "${CYCLIC_ALIAS_BEFORE_SHA256}" = "${CYCLIC_ALIAS_AFTER_SHA256}" ]

# Existing private version 1 definitions remain valid across an image upgrade.
cp "${TEST_ROOT}/config/proxy-groups.yaml" "${TEST_ROOT}/config/proxy-groups-v2.yaml"
cat > "${TEST_ROOT}/config/proxy-groups.yaml" <<'YAML'
version: 1
groups:
  - name: Legacy Auto
    type: url-test
    use: [oixCloud]
    url: http://cp.cloudflare.com/generate_204
    interval: 3600
prepend-to:
  Proxy: [Legacy Auto]
YAML
cat > "${LEGACY_CONFIG_FILE}" <<'YAML'
proxy-providers:
  oixCloud:
    type: http
proxy-groups:
  - name: Proxy
    type: select
    proxies: [DIRECT]
rules:
  - MATCH,Proxy
YAML
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${TEST_ROOT}/hooks.d/20-custom-proxy-groups.sh" "${LEGACY_CONFIG_FILE}"
ruby -ryaml -E UTF-8 - "${LEGACY_CONFIG_FILE}" <<'RUBY'
value = YAML.load_file(ARGV.fetch(0))
groups = value.fetch('proxy-groups')
legacy = groups.find { |group| group['name'] == 'Legacy Auto' }
raise 'legacy version 1 group was not added' unless legacy
raise 'legacy provider reference was lost' unless legacy['use'] == ['oixCloud']
proxy = groups.find { |group| group['name'] == 'Proxy' }
raise 'legacy prepend-to was not applied' unless proxy['proxies'].first == 'Legacy Auto'
RUBY
mv "${TEST_ROOT}/config/proxy-groups-v2.yaml" "${TEST_ROOT}/config/proxy-groups.yaml"

# An unrelated inline configuration must remain byte-for-byte untouched.
cat > "${UNMATCHED_CONFIG_FILE}" <<'YAML'
proxies:
  - {name: "unrelated", type: direct}
proxy-groups:
  - name: Other
    type: select
    proxies: [unrelated, DIRECT]
rules:
  - MATCH,Other
YAML
UNMATCHED_BEFORE_SHA256="$(sha256sum "${UNMATCHED_CONFIG_FILE}" | awk '{print $1}')"
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${TEST_ROOT}/hooks.d/20-custom-proxy-groups.sh" "${UNMATCHED_CONFIG_FILE}"
UNMATCHED_AFTER_SHA256="$(sha256sum "${UNMATCHED_CONFIG_FILE}" | awk '{print $1}')"
[ "${UNMATCHED_BEFORE_SHA256}" = "${UNMATCHED_AFTER_SHA256}" ]

# A schema/provider error must leave the last valid generated config untouched.
ruby -ryaml -E UTF-8 - "${TEST_ROOT}/config/proxy-groups.yaml" <<'RUBY'
path = ARGV.fetch(0)
value = YAML.load_file(path)
profile = value.fetch('profiles').find { |candidate| candidate['name'] == 'oix-provider' }
profile.fetch('source')['provider'] = 'missing-provider'
File.open(path, 'w') { |file| YAML.dump(value, file) }
RUBY
BEFORE_FAILURE_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
if OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
  OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${CONFIG_FILE}"; then
  echo "invalid hook configuration unexpectedly succeeded" >&2
  exit 1
fi
AFTER_FAILURE_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
[ "${BEFORE_FAILURE_SHA256}" = "${AFTER_FAILURE_SHA256}" ]

# Runtime settings are deliberately constrained instead of accepting an
# arbitrary deep merge. A non-boolean sniffer value must also roll back.
cp "${SOURCE_ROOT}/config/proxy-groups.yaml" "${TEST_ROOT}/config/proxy-groups.yaml"
cat > "${TEST_ROOT}/config/runtime.yaml" <<'YAML'
version: 1
sniffer:
  enable: "yes"
YAML
BEFORE_FAILURE_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
if OPENCLASH_HOOK_ROOT="${TEST_ROOT}" \
  OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_overwrite.sh" "${CONFIG_FILE}"; then
  echo "invalid runtime configuration unexpectedly succeeded" >&2
  exit 1
fi
AFTER_FAILURE_SHA256="$(sha256sum "${CONFIG_FILE}" | awk '{print $1}')"
[ "${BEFORE_FAILURE_SHA256}" = "${AFTER_FAILURE_SHA256}" ]

# The firewall hook must validate private definitions and pass only structured,
# documentation-only values to nft. Fake commands keep this test unprivileged.
cat > "${TEST_ROOT}/config/firewall-bypass.yaml" <<'YAML'
version: 1
ipv4-destinations:
  - 192.0.2.10
udp-destination-ports:
  - 3478
YAML
mkdir -p "${TEST_ROOT}/bin"
cat > "${TEST_ROOT}/bin/uci" <<'SH'
#!/bin/sh
printf '%s\n' eth0
SH
cat > "${TEST_ROOT}/bin/nft" <<'SH'
#!/bin/sh
if [ "${1:-}" = list ]; then
  exit 0
fi
printf '%s\n' "$*" >> "${NFT_TEST_LOG}"
SH
cat > "${TEST_ROOT}/bin/docker-luci-firewall" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${DOCKER_LUCI_HELPER_TEST_LOG}"
SH
chmod 0755 \
  "${TEST_ROOT}/bin/uci" \
  "${TEST_ROOT}/bin/nft" \
  "${TEST_ROOT}/bin/docker-luci-firewall"
: > "${TEST_ROOT}/docker-luci-helper.log"
: > "${TEST_ROOT}/nft.log"
ENABLE_OPENCLASH_HOOKS=0 \
DOCKER_LUCI_FIREWALL="${TEST_ROOT}/bin/docker-luci-firewall" \
DOCKER_LUCI_HELPER_TEST_LOG="${TEST_ROOT}/docker-luci-helper.log" \
NFT_TEST_LOG="${TEST_ROOT}/nft.log" \
PATH="${TEST_ROOT}/bin:${PATH}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_firewall_rules.sh"
[ "$(wc -l < "${TEST_ROOT}/nft.log")" -eq 2 ]
[ "$(wc -l < "${TEST_ROOT}/docker-luci-helper.log")" -eq 1 ]
grep -Fxq 'apply' "${TEST_ROOT}/docker-luci-helper.log"
grep -Fq 'ip saddr 172.16.0.0/12 udp dport 53' "${TEST_ROOT}/nft.log"
grep -Fq 'ip saddr 172.16.0.0/12 tcp dport 53' "${TEST_ROOT}/nft.log"

: > "${TEST_ROOT}/nft.log"
DOCKER_LUCI_FIREWALL="${TEST_ROOT}/bin/docker-luci-firewall" \
DOCKER_LUCI_HELPER_TEST_LOG="${TEST_ROOT}/docker-luci-helper.log" \
NFT_TEST_LOG="${TEST_ROOT}/nft.log" \
PATH="${TEST_ROOT}/bin:${PATH}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_firewall_rules.sh"
[ "$(wc -l < "${TEST_ROOT}/nft.log")" -eq 6 ]
[ "$(wc -l < "${TEST_ROOT}/docker-luci-helper.log")" -eq 2 ]
grep -Fq 'ip daddr 192.0.2.10' "${TEST_ROOT}/nft.log"
grep -Fq 'udp dport 3478' "${TEST_ROOT}/nft.log"

echo "[openclash-hooks] tests passed"
