#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/usr/local/share/openclash-hooks/config}"
DEFINITION_FILE="${HOOK_CONFIG_DIR}/runtime.yaml"

[ -n "${CONFIG_FILE}" ] || exit 0
[ -f "${DEFINITION_FILE}" ] || exit 0

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" "${DEFINITION_FILE}" <<'RUBY'
config_file, definition_file = ARGV
value = YAML.load_file(config_file)
definition = YAML.load_file(definition_file)

raise 'generated config is not a map' unless value.is_a?(Hash)
raise 'runtime.yaml must contain a map' unless definition.is_a?(Hash)
raise 'runtime.yaml only supports version 1' unless definition['version'] == 1

unknown_sections = definition.keys - ['version', 'sniffer', 'tun']
unless unknown_sections.empty?
  raise "runtime.yaml contains unsupported sections: #{unknown_sections.join(', ')}"
end

sniffer_definition = definition['sniffer'] || {}
raise 'runtime.yaml sniffer must contain a map' unless sniffer_definition.is_a?(Hash)

supported_sniffer_keys = [
  'enable',
  'force-dns-mapping',
  'parse-pure-ip',
  'override-destination',
  'sniff'
]
unknown_sniffer_keys = sniffer_definition.keys - supported_sniffer_keys
unless unknown_sniffer_keys.empty?
  raise "runtime.yaml sniffer contains unsupported keys: #{unknown_sniffer_keys.join(', ')}"
end

unless sniffer_definition.empty?
  sniffer = value['sniffer']
  unless sniffer.is_a?(Hash)
    sniffer = {}
    value['sniffer'] = sniffer
  end

  sniffer_definition.each do |key, setting|
    if key == 'sniff'
      raise 'runtime.yaml sniffer sniff must contain a map' unless setting.is_a?(Hash)
      if setting.empty? || setting.any? { |protocol, options| protocol.to_s.empty? || !options.is_a?(Hash) }
        raise 'runtime.yaml sniffer sniff must contain named protocol maps'
      end
      # A subscription-specific sniff map takes precedence. The local defaults
      # only fill the section when it is missing or malformed.
      sniffer['sniff'] = setting unless sniffer['sniff'].is_a?(Hash)
      next
    end

    unless setting == true || setting == false
      raise "runtime.yaml sniffer #{key} must be a boolean"
    end
    sniffer[key] = setting
  end
end

tun_definition = definition['tun'] || {}
raise 'runtime.yaml tun must contain a map' unless tun_definition.is_a?(Hash)

unknown_tun_keys = tun_definition.keys - ['dns-hijack']
unless unknown_tun_keys.empty?
  raise "runtime.yaml tun contains unsupported keys: #{unknown_tun_keys.join(', ')}"
end

if tun_definition.key?('dns-hijack')
  dns_hijack = tun_definition['dns-hijack']
  unless dns_hijack.is_a?(Array) && !dns_hijack.empty?
    raise 'runtime.yaml tun dns-hijack must be a non-empty array'
  end
  dns_hijack = dns_hijack.map(&:to_s)
  if dns_hijack.any?(&:empty?)
    raise 'runtime.yaml tun dns-hijack entries must not be empty'
  end

  tun = value['tun']
  raise 'generated tun is not a map' unless tun.is_a?(Hash)
  tun['dns-hijack'] = dns_hijack.uniq
end

File.open(config_file, 'w') { |file| YAML.dump(value, file) }
RUBY
