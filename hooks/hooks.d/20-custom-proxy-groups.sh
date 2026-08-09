#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/usr/local/share/openclash-hooks/config}"
DEFINITION_FILE="${HOOK_CONFIG_DIR}/proxy-groups.yaml"

[ -n "${CONFIG_FILE}" ] || exit 0
[ -f "${DEFINITION_FILE}" ] || exit 0

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" "${DEFINITION_FILE}" <<'RUBY'
config_file, definition_file = ARGV
value = YAML.load_file(config_file)
definition = YAML.load_file(definition_file)

raise 'generated config is not a map' unless value.is_a?(Hash)
raise 'proxy-groups.yaml must contain a map' unless definition.is_a?(Hash)
raise 'proxy-groups.yaml only supports version 1' unless definition['version'] == 1

groups = value['proxy-groups']
raise 'generated proxy-groups is not an array' unless groups.is_a?(Array)

custom_groups = definition['groups']
raise 'proxy-groups.yaml groups must be an array' unless custom_groups.is_a?(Array)

custom_names = custom_groups.map do |group|
  raise 'every custom proxy group must be a map' unless group.is_a?(Hash)
  name = group['name'].to_s
  raise 'every custom proxy group must have a name' if name.empty?
  name
end
raise 'custom proxy group names must be unique' unless custom_names.uniq.length == custom_names.length

providers = value['proxy-providers']
referenced_providers = custom_groups.flat_map { |group| Array(group['use']) }.uniq
missing_providers = referenced_providers.reject do |name|
  providers.is_a?(Hash) && providers.key?(name)
end
unless missing_providers.empty?
  raise "missing proxy providers: #{missing_providers.join(', ')}"
end

# Replace managed groups from an earlier pass, then put the canonical custom
# definitions first. This keeps repeated subscription updates idempotent.
groups.reject! do |group|
  group.is_a?(Hash) && custom_names.include?(group['name'])
end
value['proxy-groups'] = custom_groups + groups

prepend_to = definition['prepend-to'] || {}
raise 'proxy-groups.yaml prepend-to must be a map' unless prepend_to.is_a?(Hash)

prepend_to.each do |target_name, choices|
  target = value['proxy-groups'].find do |group|
    group.is_a?(Hash) && group['name'] == target_name
  end
  raise "target proxy group is missing: #{target_name}" unless target

  requested = Array(choices).map(&:to_s)
  unknown = requested.reject { |name| custom_names.include?(name) }
  unless unknown.empty?
    raise "prepend-to references unmanaged groups: #{unknown.join(', ')}"
  end

  target['proxies'] = (requested + Array(target['proxies'])).uniq
end

prepend_existing_to = definition['prepend-existing-to'] || {}
unless prepend_existing_to.is_a?(Hash)
  raise 'proxy-groups.yaml prepend-existing-to must be a map'
end

prepend_existing_to.each do |target_name, choices|
  target = value['proxy-groups'].find do |group|
    group.is_a?(Hash) && group['name'] == target_name
  end
  # Subscription-specific groups are optional. Skipping a missing target keeps
  # the same private definition portable across providers.
  next unless target

  requested = Array(choices).map(&:to_s)
  raise 'prepend-existing-to contains an empty choice' if requested.any?(&:empty?)
  known_names = value['proxy-groups'].filter_map do |group|
    group['name'] if group.is_a?(Hash)
  end
  unknown = requested.reject { |name| known_names.include?(name) }
  unless unknown.empty?
    raise "prepend-existing-to references missing groups: #{unknown.join(', ')}"
  end

  target['proxies'] = (requested + Array(target['proxies'])).uniq
end

File.open(config_file, 'w') { |file| YAML.dump(value, file) }
RUBY
