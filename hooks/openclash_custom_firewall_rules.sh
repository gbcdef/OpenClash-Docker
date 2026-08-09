#!/bin/sh
set -eu

HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/etc/openclash-hooks/config}"
DEFINITION_FILE="${HOOK_CONFIG_DIR}/firewall-bypass.yaml"
PREVIOUS_HOOK='/etc/openclash/custom/openclash_custom_firewall_rules.before-docker-hooks.sh'

if [ -f "${PREVIOUS_HOOK}" ]; then
  /bin/sh "${PREVIOUS_HOOK}"
fi

[ -f "${DEFINITION_FILE}" ] || exit 0

LAN_INTERFACE="$(uci -q get openclash.config.lan_interface_name || true)"
if [ -z "${LAN_INTERFACE}" ]; then
  echo '[openclash-hooks] OpenClash LAN interface is not configured' >&2
  exit 1
fi

RULES="$(ruby -ryaml -E UTF-8 - "${DEFINITION_FILE}" <<'RUBY'
definition = YAML.load_file(ARGV.fetch(0))
raise 'firewall-bypass.yaml must contain a map' unless definition.is_a?(Hash)
unless definition['version'] == 1
  raise 'firewall-bypass.yaml only supports version 1'
end

ipv4_values = Array(definition['ipv4-destinations']).map(&:to_s)
udp_ports = Array(definition['udp-destination-ports'])

ipv4_values.each do |address|
  octets = address.split('.', -1)
  valid = octets.length == 4 && octets.all? do |octet|
    octet.match?(/\A(?:0|[1-9][0-9]{0,2})\z/) && octet.to_i <= 255
  end
  raise "invalid IPv4 destination: #{address}" unless valid
  puts "ipv4 #{address}"
end

udp_ports.each do |raw_port|
  port = Integer(raw_port, exception: false)
  unless port && port.between?(1, 65_535)
    raise "invalid UDP destination port: #{raw_port}"
  end
  puts "udp-port #{port}"
end
RUBY
)"

ensure_rule() {
  chain="$1"
  comment="$2"
  shift 2

  if ! nft list chain inet fw4 "${chain}" 2>/dev/null | grep -Fq "${comment}"; then
    nft insert rule inet fw4 "${chain}" "$@" counter return comment "\"${comment}\""
  fi
}

printf '%s\n' "${RULES}" | while read -r rule_type value; do
  [ -n "${rule_type}" ] || continue
  case "${rule_type}" in
    ipv4)
      comment="OpenClash Docker IPv4 bypass ${value}"
      ensure_rule openclash_mangle "${comment}" \
        iifname "${LAN_INTERFACE}" ip daddr "${value}"
      ensure_rule openclash_mangle_output "${comment}" ip daddr "${value}"
      ;;
    udp-port)
      comment="OpenClash Docker UDP bypass ${value}"
      ensure_rule openclash_mangle "${comment}" \
        iifname "${LAN_INTERFACE}" udp dport "${value}"
      ensure_rule openclash_mangle_output "${comment}" udp dport "${value}"
      ;;
    *)
      echo "[openclash-hooks] unsupported firewall bypass type: ${rule_type}" >&2
      exit 1
      ;;
  esac
done
