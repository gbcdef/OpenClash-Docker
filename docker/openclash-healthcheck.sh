#!/bin/sh
set -eu

if [ "$(uci -q get openclash.config.enable || true)" != "1" ]; then
  echo "OpenClash is disabled" >&2
  exit 1
fi

if ! /etc/init.d/openclash status >/dev/null 2>&1; then
  echo "OpenClash is enabled but its procd service is not running" >&2
  exit 1
fi

CLASH_PID="$(pidof clash 2>/dev/null | cut -d ' ' -f 1)"
if [ -z "${CLASH_PID}" ]; then
  echo 'OpenClash core process is missing' >&2
  exit 1
fi

CLASH_EXECUTABLE="$(tr '\0' '\n' < "/proc/${CLASH_PID}/cmdline" | sed -n '1p')"
if [ "${CLASH_EXECUTABLE}" != "${OPENCLASH_CORE_PATH:-/etc/openclash/clash}" ]; then
  echo 'OpenClash core process has an unexpected executable' >&2
  exit 1
fi

TUN_INTERFACE="${OPENCLASH_TUN_INTERFACE:-utun}"
if ! ip link show dev "${TUN_INTERFACE}" 2>/dev/null | grep -q 'UP'; then
  echo 'OpenClash TUN interface is not up' >&2
  exit 1
fi

ROUTE_MARK="${OPENCLASH_ROUTE_MARK:-0x162}"
ROUTE_TABLE="${OPENCLASH_ROUTE_TABLE:-354}"
if ! ip rule show | grep -Eq "fwmark ${ROUTE_MARK}([/[:space:]]|$).*lookup ${ROUTE_TABLE}"; then
  echo 'OpenClash policy-routing rule is missing' >&2
  exit 1
fi
if ! ip route show table "${ROUTE_TABLE}" | grep -Eq "^default[[:space:]]+dev[[:space:]]+${TUN_INTERFACE}([[:space:]]|$)"; then
  echo 'OpenClash policy-routing default route is missing' >&2
  exit 1
fi

for PORT in "${DNS_PORT:-7874}" "${MIXED_PROXY_PORT:-7890}"; do
  if ! netstat -ln 2>/dev/null | grep -Eq "[:.]${PORT}[[:space:]]"; then
    echo "OpenClash expected port is not listening: ${PORT}" >&2
    exit 1
  fi
done
