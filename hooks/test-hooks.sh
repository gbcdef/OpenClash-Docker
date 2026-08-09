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
cp "${SOURCE_ROOT}/config/hosts.example.yaml" "${TEST_ROOT}/config/hosts.yaml"
cp "${SOURCE_ROOT}/config/dns.example.yaml" "${TEST_ROOT}/config/dns.yaml"
cp "${SOURCE_ROOT}/config/proxy-groups.example.yaml" "${TEST_ROOT}/config/proxy-groups.yaml"
cp "${SOURCE_ROOT}/config/rules.example.yaml" "${TEST_ROOT}/config/rules.yaml"
cp "${SOURCE_ROOT}/config/firewall-bypass.example.yaml" "${TEST_ROOT}/config/firewall-bypass.yaml"

cat > "${CONFIG_FILE}" <<'YAML'
hosts:
  existing.example.test: 192.0.2.30
dns:
  fake-ip-filter:
    - "+.obsolete.example.test"
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

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" <<'RUBY'
value = YAML.load_file(ARGV.fetch(0))

raise 'existing host was lost' unless value.dig('hosts', 'existing.example.test') == '192.0.2.30'
raise 'custom host was not added' unless value.dig('hosts', 'api.example.test') == '192.0.2.10'

filters = value.dig('dns', 'fake-ip-filter')
raise 'custom fake-IP filter was not prepended' unless filters.first == '+.example.test'
if filters.include?('+.obsolete.example.test')
  raise 'removed fake-IP filter is still present'
end

groups = value.fetch('proxy-groups')
names = groups.map { |group| group['name'] }
raise 'custom selector was not added' unless names.include?('地区自动选择')
proxy = groups.find { |group| group['name'] == 'Proxy' }
raise 'custom selector was not exposed in Proxy' unless proxy['proxies'].first == '地区自动选择'
microsoft = groups.find { |group| group['name'] == 'Microsoft' }
raise 'existing group was not prepended' unless microsoft['proxies'].first == 'Proxy'

rules = value.fetch('rules')
if rules.include?('DOMAIN-SUFFIX,obsolete.example.test,DIRECT')
  raise 'retired custom rule is still present'
end
custom_index = rules.index('DOMAIN-SUFFIX,example.test,DIRECT')
final_index = rules.index('MATCH,Proxy')
raise 'custom rules were not inserted before MATCH' unless custom_index && final_index && custom_index < final_index
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

# The firewall hook must validate private definitions and pass only structured,
# documentation-only values to nft. Fake commands keep this test unprivileged.
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
NFT_TEST_LOG="${TEST_ROOT}/nft.log" \
PATH="${TEST_ROOT}/bin:${PATH}" \
OPENCLASH_HOOK_CONFIG_DIR="${TEST_ROOT}/config" \
  /bin/sh "${SOURCE_ROOT}/openclash_custom_firewall_rules.sh"
[ "$(wc -l < "${TEST_ROOT}/nft.log")" -eq 4 ]
grep -Fq 'ip daddr 192.0.2.10' "${TEST_ROOT}/nft.log"
grep -Fq 'udp dport 3478' "${TEST_ROOT}/nft.log"

echo "[openclash-hooks] tests passed"
