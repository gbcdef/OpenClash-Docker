#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/usr/local/share/openclash-hooks/config}"
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

unknown_sections = definition.keys - ['version', 'respect-rules', 'fake-ip-filter']
unless unknown_sections.empty?
  raise "dns.yaml contains unsupported sections: #{unknown_sections.join(', ')}"
end

if definition.key?('respect-rules')
  respect_rules = definition['respect-rules']
  unless respect_rules == true || respect_rules == false
    raise 'dns.yaml respect-rules must be a boolean'
  end

  if respect_rules
    proxy_nameservers = dns['proxy-server-nameserver']
    unless proxy_nameservers.nil? || proxy_nameservers.is_a?(Array)
      raise 'generated proxy-server-nameserver is not an array'
    end

    if Array(proxy_nameservers).empty?
      bootstrap_nameservers = dns['default-nameserver']
      unless bootstrap_nameservers.is_a?(Array) && !bootstrap_nameservers.empty?
        raise 'respect-rules requires default-nameserver or proxy-server-nameserver'
      end
      bootstrap_nameservers = bootstrap_nameservers.map(&:to_s)
      if bootstrap_nameservers.any?(&:empty?)
        raise 'generated default-nameserver entries must not be empty'
      end
      dns['proxy-server-nameserver'] = bootstrap_nameservers.uniq
    end
  end

  dns['respect-rules'] = respect_rules
end

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
