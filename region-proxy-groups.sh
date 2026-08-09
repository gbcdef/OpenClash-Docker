#!/bin/sh

# Add country/region URL-Test groups to the generated oixCloud configuration.
# OpenClash runs this script after its own config generation, so subscription
# updates keep the groups without modifying the downloaded subscription file.

if [ -z "$1" ]; then
  exit 0
fi

CONFIG_FILE="$1"

# Keep all mutations in one Ruby operation. OpenClash queues each helper call
# in a separate thread, so one atomic block avoids races between group inserts
# and makes repeated runs idempotent.
RUBY_PART=$(cat <<'RUBY'
test_url = 'http://cp.cloudflare.com/generate_204'
test_interval = 3600
provider_name = 'oixCloud'

# Match the transparent-takeover behavior of the previous Mihomo container.
# LAN clients do not need DHCP to advertise this host as their DNS server:
# DNS packets that traverse the bypass router are intercepted by TUN, while
# HTTP Host, TLS SNI, and QUIC ClientHello restore the real destination domain.
sniffer = Value['sniffer']
unless sniffer.is_a?(Hash)
  sniffer = {}
  Value['sniffer'] = sniffer
end
sniffer['enable'] = true
sniffer['force-dns-mapping'] = true
sniffer['parse-pure-ip'] = true
sniffer['override-destination'] = true
sniffer['sniff'] ||= {
  'HTTP' => {'ports' => [80, '8080-8880'], 'override-destination' => true},
  'TLS' => {'ports' => [443, 8443]},
  'QUIC' => {'ports' => [443, 8443]}
}

tun = Value['tun']
raise 'tun is missing or is not a map' unless tun.is_a?(Hash)
tun['dns-hijack'] = ['any:53']

region_specs = [
  ['香港自动', '(^🇭🇰|香港(?!.*(阿根廷|菲律宾|Edge)))'],
  ['台湾自动', '(^🇨🇳.*(台湾|台灣)|台湾|台灣)'],
  ['新加坡自动', '(^🇸🇬|新加坡)'],
  ['日本自动', '(^🇯🇵|日本)'],
  ['韩国自动', '(^🇰🇷|韩国|韓國)'],
  ['美国自动', '(^🇺🇸|美国|美國)'],
  ['俄罗斯自动', '(^🇷🇺|俄罗斯|俄羅斯)'],
  ['加拿大自动', '(^🇨🇦|加拿大)'],
  ['印度自动', '(^🇮🇳|印度)'],
  ['土耳其自动', '(^🇹🇷|土耳其)'],
  ['墨西哥自动', '(^🇲🇽|墨西哥)'],
  ['尼日利亚自动', '(^🇳🇬|尼日利亚|尼日利亞)'],
  ['巴西自动', '(^🇧🇷|巴西)'],
  ['德国自动', '(^🇩🇪|德国|德國)'],
  ['法国自动', '(^🇫🇷|法国|法國)'],
  ['泰国自动', '(^🇹🇭|泰国|泰國)'],
  ['澳大利亚自动', '(^🇦🇺|澳大利亚|澳洲)'],
  ['英国自动', '(^🇬🇧|英国|英國)'],
  ['菲律宾自动', '(^🇵🇭|菲律宾|菲律賓)'],
  ['阿根廷自动', '(^🇦🇷|阿根廷)'],
  ['马来西亚自动', '(^🇲🇾|马来西亚|馬來西亞)']
]

groups = Value['proxy-groups']
raise 'proxy-groups is missing or is not an array' unless groups.is_a?(Array)

providers = Value['proxy-providers']
unless providers.is_a?(Hash) && providers.key?(provider_name)
  raise "proxy provider #{provider_name} is missing"
end

proxy_group = groups.find do |group|
  group.is_a?(Hash) && group['name'] == 'Proxy'
end
raise 'Proxy group is missing' unless proxy_group

region_names = region_specs.map(&:first)
selector_name = '地区自动选择'
managed_names = [selector_name] + region_names

# Remove groups from an earlier run before adding the canonical definitions.
groups.reject! do |group|
  group.is_a?(Hash) && managed_names.include?(group['name'])
end

region_groups = region_specs.map do |name, filter|
  {
    'name' => name,
    'type' => 'url-test',
    'url' => test_url,
    'interval' => test_interval,
    'use' => [provider_name],
    'filter' => filter
  }
end

selector_group = {
  'name' => selector_name,
  'type' => 'select',
  'proxies' => region_names
}

Value['proxy-groups'] = [selector_group] + region_groups + groups

# Expose the selector at the top of Proxy while retaining every original
# automatic, direct, provider, and individual-node choice.
existing_choices = Array(proxy_group['proxies'])
proxy_group['proxies'] = ([selector_name] + existing_choices).uniq
RUBY
)

# Run synchronously. The OpenClash helper queues each mutation in a separate
# thread and its parent-process detector can loop in containerized OpenWrt.
# A direct Ruby transaction is also supported by the stock overwrite template.
ruby -ryaml -E UTF-8 -e "
  Value = YAML.load_file(ARGV.fetch(0))
  $RUBY_PART
  File.open(ARGV.fetch(0), 'w') { |file| YAML.dump(Value, file) }
" "$CONFIG_FILE"
