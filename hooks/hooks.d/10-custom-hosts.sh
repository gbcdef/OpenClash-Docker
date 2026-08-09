#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/etc/openclash-hooks/config}"
DEFINITION_FILE="${HOOK_CONFIG_DIR}/hosts.yaml"

[ -n "${CONFIG_FILE}" ] || exit 0
[ -f "${DEFINITION_FILE}" ] || exit 0

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" "${DEFINITION_FILE}" <<'RUBY'
config_file, definition_file = ARGV
value = YAML.load_file(config_file)
definition = YAML.load_file(definition_file)

raise 'generated config is not a map' unless value.is_a?(Hash)
raise 'hosts.yaml must contain a map' unless definition.is_a?(Hash)
raise 'hosts.yaml only supports version 1' unless definition['version'] == 1

custom_hosts = definition['hosts']
raise 'hosts.yaml hosts must contain a map' unless custom_hosts.is_a?(Hash)

hosts = value['hosts']
unless hosts.is_a?(Hash)
  hosts = {}
  value['hosts'] = hosts
end

custom_hosts.each do |hostname, address|
  raise 'hosts.yaml contains an empty hostname' if hostname.to_s.empty?
  hosts[hostname.to_s] = address
end

File.open(config_file, 'w') { |file| YAML.dump(value, file) }
RUBY
