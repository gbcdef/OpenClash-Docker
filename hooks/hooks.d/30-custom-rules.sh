#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_CONFIG_DIR="${OPENCLASH_HOOK_CONFIG_DIR:-/usr/local/share/openclash-hooks/config}"
DEFINITION_FILE="${HOOK_CONFIG_DIR}/rules.yaml"

[ -n "${CONFIG_FILE}" ] || exit 0
[ -f "${DEFINITION_FILE}" ] || exit 0

ruby -ryaml -E UTF-8 - "${CONFIG_FILE}" "${DEFINITION_FILE}" <<'RUBY'
config_file, definition_file = ARGV
value = YAML.load_file(config_file)
definition = YAML.load_file(definition_file)

raise 'generated config is not a map' unless value.is_a?(Hash)
raise 'rules.yaml must contain a map' unless definition.is_a?(Hash)
raise 'rules.yaml only supports version 1' unless definition['version'] == 1

rules = value['rules']
raise 'generated rules is not an array' unless rules.is_a?(Array)

custom_rules = definition['rules']
raise 'rules.yaml rules must be an array' unless custom_rules.is_a?(Array)
custom_rules = custom_rules.map(&:to_s)
raise 'custom rules must not contain empty entries' if custom_rules.any?(&:empty?)

removed_rules = Array(definition['remove']).map(&:to_s)
raise 'removed rules must not contain empty entries' if removed_rules.any?(&:empty?)

position = definition.fetch('position', 'before-final')
unless ['top', 'before-final'].include?(position)
  raise 'rules.yaml position must be top or before-final'
end

# Remove explicitly retired rules and identical entries from an earlier pass
# before inserting the canonical private rules again.
rules.reject! { |rule| (removed_rules + custom_rules).include?(rule) }
index = if position == 'top'
          0
        else
          rules.index do |rule|
            ['MATCH', 'FINAL'].include?(rule.to_s.split(',', 2).first)
          end || rules.length
        end
rules.insert(index, *custom_rules)

File.open(config_file, 'w') { |file| YAML.dump(value, file) }
RUBY
