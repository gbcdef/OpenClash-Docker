#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/etc/openclash-hooks/config}"
DEFINITION_FILE="${HOOK_CONFIG_DIR}/dns.yaml"

[ -n "${CONFIG_FILE}" ] || exit 0
[ -f "${DEFINITION_FILE}" ] || exit 0

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" "${DEFINITION_FILE}" <<'RUBY'
config_file, definition_file = ARGV
value = YAML.load_file(config_file)
definition = YAML.load_file(definition_file)

raise 'generated config is not a map' unless value.is_a?(Hash)
raise 'dns.yaml must contain a map' unless definition.is_a?(Hash)
raise 'dns.yaml only supports version 1' unless definition['version'] == 1

dns = value['dns']
raise 'generated dns is not a map' unless dns.is_a?(Hash)

filter_definition = definition['fake-ip-filter'] || {}
raise 'dns.yaml fake-ip-filter must be a map' unless filter_definition.is_a?(Hash)

prepend = Array(filter_definition['prepend']).map(&:to_s)
remove = Array(filter_definition['remove']).map(&:to_s)
if (prepend + remove).any?(&:empty?)
  raise 'dns.yaml fake-ip-filter entries must not be empty'
end

filters = Array(dns['fake-ip-filter']).map(&:to_s)
filters.reject! { |entry| remove.include?(entry) }
dns['fake-ip-filter'] = (prepend + filters).uniq

File.open(config_file, 'w') { |file| YAML.dump(value, file) }
RUBY
