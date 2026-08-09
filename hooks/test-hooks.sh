#!/bin/sh
set -eu

SOURCE_ROOT="$(CDPATH= cd "$(dirname "$0")" && pwd)"
TEST_ROOT="/tmp/openclash-hooks-test.$$"
CONFIG_FILE="${TEST_ROOT}/generated.yaml"

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
raise 'subscription final rule was lost' unless rules.last == 'MATCH,Proxy'
RUBY

# A schema/provider error must leave the last valid generated config untouched.
sed -i 's/oixCloud/missing-provider/g' "${TEST_ROOT}/config/proxy-groups.yaml"
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
chmod 0755 "${TEST_ROOT}/bin/uci" "${TEST_ROOT}/bin/nft"
: > "${TEST_ROOT}/nft.log"
ENABLE_OPENCLASH_HOOKS=0 \
NFT_TEST_LOG="${TEST_ROOT}/nft.log" \
PATH="${TEST_ROOT}/bin:${PATH}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_firewall_rules.sh"
[ ! -s "${TEST_ROOT}/nft.log" ]

NFT_TEST_LOG="${TEST_ROOT}/nft.log" \
PATH="${TEST_ROOT}/bin:${PATH}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_firewall_rules.sh"
[ "$(wc -l < "${TEST_ROOT}/nft.log")" -eq 4 ]
grep -Fq 'ip daddr 192.0.2.10' "${TEST_ROOT}/nft.log"
grep -Fq 'udp dport 3478' "${TEST_ROOT}/nft.log"

echo "[openclash-hooks] tests passed"
