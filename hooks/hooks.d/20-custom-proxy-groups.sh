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

groups = value['proxy-groups']
raise 'generated proxy-groups is not an array' unless groups.is_a?(Array)

def group_names(groups)
  groups.each_with_object([]) do |group, names|
    names << group['name'] if group.is_a?(Hash)
  end
end

def prepend_choices(groups, target_name, choices, optional: false)
  target = groups.find do |group|
    group.is_a?(Hash) && group['name'] == target_name
  end
  return if optional && !target
  raise "target proxy group is missing: #{target_name}" unless target

  requested = Array(choices).map(&:to_s)
  raise 'proxy group choice cannot be empty' if requested.any?(&:empty?)

  unknown = requested.reject { |name| group_names(groups).include?(name) }
  unless unknown.empty?
    raise "proxy group choices are missing: #{unknown.join(', ')}"
  end

  current = target['proxies']
  raise "target proxy group proxies is not an array: #{target_name}" unless current.is_a?(Array)
  target['proxies'] = (requested + current).uniq
end

def apply_version_1(value, definition)
  groups = value['proxy-groups']
  custom_groups = definition['groups']
  raise 'proxy-groups.yaml groups must be an array' unless custom_groups.is_a?(Array)

  custom_names = custom_groups.map do |group|
    raise 'every custom proxy group must be a map' unless group.is_a?(Hash)
    name = group['name'].to_s
    raise 'every custom proxy group must have a name' if name.empty?
    name
  end
  unless custom_names.uniq.length == custom_names.length
    raise 'custom proxy group names must be unique'
  end

  providers = value['proxy-providers']
  referenced_providers = custom_groups.flat_map { |group| Array(group['use']) }.uniq
  missing_providers = referenced_providers.reject do |name|
    providers.is_a?(Hash) && providers.key?(name)
  end
  unless missing_providers.empty?
    raise "missing proxy providers: #{missing_providers.join(', ')}"
  end

  groups.reject! do |group|
    group.is_a?(Hash) && custom_names.include?(group['name'])
  end
  value['proxy-groups'] = custom_groups + groups

  prepend_to = definition['prepend-to'] || {}
  raise 'proxy-groups.yaml prepend-to must be a map' unless prepend_to.is_a?(Hash)
  prepend_to.each do |target_name, choices|
    unknown = Array(choices).map(&:to_s).reject { |name| custom_names.include?(name) }
    unless unknown.empty?
      raise "prepend-to references unmanaged groups: #{unknown.join(', ')}"
    end
    prepend_choices(value['proxy-groups'], target_name, choices)
  end

  prepend_existing_to = definition['prepend-existing-to'] || {}
  unless prepend_existing_to.is_a?(Hash)
    raise 'proxy-groups.yaml prepend-existing-to must be a map'
  end
  prepend_existing_to.each do |target_name, choices|
    prepend_choices(value['proxy-groups'], target_name, choices, optional: true)
  end
  true
end

def profile_matches?(profile, value, groups)
  match = profile['match']
  raise 'every proxy group profile must define match' unless match.is_a?(Hash)

  supported = %w[provider inline-proxies groups]
  unknown = match.keys.map(&:to_s) - supported
  raise "unsupported profile match keys: #{unknown.join(', ')}" unless unknown.empty?
  raise 'proxy group profile match cannot be empty' if match.empty?

  checks = []
  if match.key?('provider')
    provider = match['provider'].to_s
    raise 'profile match provider cannot be empty' if provider.empty?
    providers = value['proxy-providers']
    checks << (providers.is_a?(Hash) && providers.key?(provider))
  end
  if match.key?('inline-proxies')
    unless match['inline-proxies'] == true || match['inline-proxies'] == false
      raise 'profile match inline-proxies must be boolean'
    end
    inline = value['proxies'].is_a?(Array) && !value['proxies'].empty?
    checks << (inline == match['inline-proxies'])
  end
  if match.key?('groups')
    required = Array(match['groups']).map(&:to_s)
    raise 'profile match groups cannot contain an empty name' if required.any?(&:empty?)
    checks << required.all? { |name| group_names(groups).include?(name) }
  end
  checks.all?
end

def apply_version_2(value, definition)
  groups = value['proxy-groups']
  profiles = definition['profiles']
  regions = definition['regions']
  selector = definition['selector']
  url_test = definition['url-test']

  raise 'proxy-groups.yaml profiles must be an array' unless profiles.is_a?(Array)
  raise 'proxy-groups.yaml regions must be a map' unless regions.is_a?(Hash)
  raise 'proxy-groups.yaml selector must be a map' unless selector.is_a?(Hash)
  raise 'proxy-groups.yaml url-test must be a map' unless url_test.is_a?(Hash)

  selector_name = selector['name'].to_s
  raise 'selector name cannot be empty' if selector_name.empty?
  test_url = url_test['url'].to_s
  interval = url_test['interval']
  raise 'url-test URL cannot be empty' if test_url.empty?
  raise 'url-test interval must be a positive integer' unless interval.is_a?(Integer) && interval.positive?

  profile_names = profiles.map do |profile|
    raise 'every proxy group profile must be a map' unless profile.is_a?(Hash)
    name = profile['name'].to_s
    raise 'every proxy group profile must have a name' if name.empty?
    name
  end
  raise 'proxy group profile names must be unique' unless profile_names.uniq.length == profile_names.length

  matched = profiles.select { |profile| profile_matches?(profile, value, groups) }
  return false if matched.empty?
  if matched.length > 1
    raise "multiple proxy group profiles matched: #{matched.map { |p| p['name'] }.join(', ')}"
  end
  profile = matched.first

  source = profile['source']
  raise 'matched proxy group profile must define source' unless source.is_a?(Hash)
  source_type = source['type'].to_s
  raise "unsupported proxy group source type: #{source_type}" unless %w[provider inline].include?(source_type)

  region_ids = Array(profile['regions']).map(&:to_s)
  raise 'matched proxy group profile must select regions' if region_ids.empty?
  missing_regions = region_ids.reject { |id| regions.key?(id) }
  raise "profile references missing regions: #{missing_regions.join(', ')}" unless missing_regions.empty?

  region_names = regions.values.map do |region|
    raise 'every region definition must be a map' unless region.is_a?(Hash)
    name = region['name'].to_s
    raise 'every region definition must have a name' if name.empty?
    name
  end
  raise 'region names must be unique' unless region_names.uniq.length == region_names.length
  raise 'selector name conflicts with a region name' if region_names.include?(selector_name)

  inline_names = nil
  provider_name = nil
  if source_type == 'provider'
    provider_name = source['provider'].to_s
    raise 'provider source must name a provider' if provider_name.empty?
    providers = value['proxy-providers']
    unless providers.is_a?(Hash) && providers.key?(provider_name)
      raise "missing proxy provider: #{provider_name}"
    end
  else
    proxies = value['proxies']
    raise 'inline source requires a proxies array' unless proxies.is_a?(Array)
    inline_names = proxies.map do |proxy|
      raise 'every inline proxy must be a map' unless proxy.is_a?(Hash)
      name = proxy['name'].to_s
      raise 'every inline proxy must have a name' if name.empty?
      name
    end
    raise 'inline proxy names must be unique' unless inline_names.uniq.length == inline_names.length
  end

  generated_regions = region_ids.map do |id|
    region = regions.fetch(id)
    name = region['name'].to_s
    filter = region['filter'].to_s
    raise "region filter cannot be empty: #{id}" if filter.empty?

    group = {
      'name' => name,
      'type' => 'url-test',
      'url' => test_url,
      'interval' => interval
    }
    if source_type == 'provider'
      group['use'] = [provider_name]
      group['filter'] = filter
    else
      begin
        pattern = Regexp.new(filter)
      rescue RegexpError => e
        raise "invalid region filter #{id}: #{e.message}"
      end
      matching = inline_names.select { |proxy_name| pattern.match?(proxy_name) }
      next if matching.empty?
      group['proxies'] = matching
    end
    group
  end.compact
  raise "profile produced no regional groups: #{profile['name']}" if generated_regions.empty?

  aliases = profile.fetch('aliases', {})
  raise 'profile aliases must be a map' unless aliases.is_a?(Hash)
  generated_aliases = aliases.each_with_object([]) do |(alias_name, target_name), result|
    alias_name = alias_name.to_s
    target_name = target_name.to_s
    raise 'profile alias name cannot be empty' if alias_name.empty?
    raise "profile alias target cannot be empty: #{alias_name}" if target_name.empty?
    if region_names.include?(alias_name) || alias_name == selector_name
      raise "profile alias conflicts with a managed group: #{alias_name}"
    end

    target = groups.find do |group|
      group.is_a?(Hash) && group['name'] == target_name
    end
    raise "profile alias target group is missing: #{target_name}" unless target

    expected = {
      'name' => alias_name,
      'type' => 'select',
      'proxies' => [target_name]
    }
    existing = groups.find do |group|
      group.is_a?(Hash) && group['name'] == alias_name
    end
    # Keep a subscription-native group with the same name. An exact match is
    # a generated alias from an earlier idempotent pass and can be rebuilt.
    next if existing && existing != expected
    if Array(target['proxies']).include?(alias_name)
      raise "profile alias would create a group cycle: #{alias_name}"
    end
    groups.delete(existing) if existing
    result << expected
  end

  managed_names = region_names + [selector_name]
  groups.reject! do |group|
    group.is_a?(Hash) && managed_names.include?(group['name'])
  end
  selector_group = {
    'name' => selector_name,
    'type' => 'select',
    'proxies' => generated_regions.map { |group| group['name'] }
  }
  value['proxy-groups'] = [selector_group] + generated_regions + generated_aliases + groups

  attach_to = profile['prepend-to'].to_s
  raise 'matched proxy group profile must define prepend-to' if attach_to.empty?
  prepend_choices(value['proxy-groups'], attach_to, [selector_name])

  prepend_existing_to = profile['prepend-existing-to'] || {}
  unless prepend_existing_to.is_a?(Hash)
    raise 'profile prepend-existing-to must be a map'
  end
  prepend_existing_to.each do |target_name, choices|
    prepend_choices(value['proxy-groups'], target_name, choices, optional: true)
  end
  true
end

changed = case definition['version']
when 1
  apply_version_1(value, definition)
when 2
  apply_version_2(value, definition)
else
  raise 'proxy-groups.yaml only supports versions 1 and 2'
end

File.open(config_file, 'w') { |file| YAML.dump(value, file) } if changed
RUBY
