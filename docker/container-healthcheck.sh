#!/bin/sh
set -eu

ubus call system board >/dev/null 2>&1
/etc/init.d/uhttpd status >/dev/null 2>&1
uci -q get 'system.@system[0]' >/dev/null 2>&1
test -S /dev/log
/etc/init.d/dnsmasq status >/dev/null 2>&1

if [ "${REQUIRE_OPENCLASH_HEALTHY:-0}" = "1" ]; then
  /usr/local/sbin/openclash-healthcheck
fi
