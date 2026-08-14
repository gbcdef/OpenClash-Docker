#!/bin/sh
set -eu

CONFIG_PACKAGE='openclash_docker'
CONFIG_SECTION='luci_access'
FIREWALL_SECTION='docker_luci_access'
FIREWALL_HELPER_PATH='/usr/local/sbin/docker-luci-firewall'
MANAGED_COMMENT_PREFIX='OpenClash Docker LuCI Input '
UCI_CONFIG_FILE="${DOCKER_LUCI_UCI_CONFIG_FILE:-/etc/config/${CONFIG_PACKAGE}}"

fail() {
  echo "[docker-luci-firewall] $*" >&2
  exit 1
}

is_ipv4() (
  VALUE="$1"
  case "${VALUE}" in
    ''|*[!0-9.]*) exit 1 ;;
  esac

  IFS=.
  set -- ${VALUE}
  [ "$#" -eq 4 ] || exit 1
  for OCTET in "$@"; do
    [ -n "${OCTET}" ] || exit 1
    [ "${OCTET}" -le 255 ] 2>/dev/null || exit 1
  done
)

is_ipv4_cidr() {
  VALUE="$1"
  case "${VALUE}" in
    */*) ;;
    *) return 1 ;;
  esac

  ADDRESS="${VALUE%/*}"
  PREFIX="${VALUE#*/}"
  [ "${VALUE}" = "${ADDRESS}/${PREFIX}" ] || return 1
  case "${PREFIX}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${PREFIX}" -le 32 ] 2>/dev/null || return 1
  is_ipv4 "${ADDRESS}"
}

is_tcp_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

validate_enabled_config() {
  is_ipv4_cidr "${SOURCE_CIDR}" ||
    fail "invalid DOCKER_LUCI_SOURCE_CIDR: ${SOURCE_CIDR}"
  is_ipv4 "${LUCI_ADDRESS}" ||
    fail "invalid LUCI_BIND for Docker access: ${LUCI_ADDRESS}"
  [ "${LUCI_ADDRESS}" != '0.0.0.0' ] ||
    fail 'LUCI_BIND must be a specific IPv4 address when Docker access is enabled'
  case "${LUCI_ADDRESS}" in
    127.*) fail 'LUCI_BIND must be non-loopback when Docker access is enabled' ;;
  esac
  is_tcp_port "${LUCI_TCP_PORT}" ||
    fail "invalid LUCI_PORT for Docker access: ${LUCI_TCP_PORT}"
}

read_config() {
  ENABLED="$(uci -q get "${CONFIG_PACKAGE}.${CONFIG_SECTION}.enabled" || true)"
  case "${ENABLED}" in
    0) return 0 ;;
    1) ;;
    '') ENABLED=0; return 0 ;;
    *) fail "stored enabled value must be 0 or 1: ${ENABLED}" ;;
  esac

  SOURCE_CIDR="$(uci -q get "${CONFIG_PACKAGE}.${CONFIG_SECTION}.source_cidr" || true)"
  LUCI_ADDRESS="$(uci -q get "${CONFIG_PACKAGE}.${CONFIG_SECTION}.luci_bind" || true)"
  LUCI_TCP_PORT="$(uci -q get "${CONFIG_PACKAGE}.${CONFIG_SECTION}.luci_port" || true)"
  validate_enabled_config
}

list_input_chain() {
  nft -a list chain inet fw4 input 2>/dev/null
}

remove_managed_rules() {
  CHAIN_RULES="$1"
  printf '%s\n' "${CHAIN_RULES}" |
    awk -v marker="comment \"${MANAGED_COMMENT_PREFIX}" '
      index($0, marker) {
        for (field = 1; field <= NF; field++) {
          if ($field == "handle" && $(field + 1) ~ /^[0-9]+$/) {
            print $(field + 1)
          }
        }
      }
    ' |
    while IFS= read -r HANDLE; do
      [ -n "${HANDLE}" ] || continue
      nft "delete rule inet fw4 input handle ${HANDLE}"
    done
}

apply_rule() {
  read_config
  if ! CHAIN_RULES="$(list_input_chain)"; then
    return 0
  fi

  if [ "${ENABLED}" = '0' ]; then
    remove_managed_rules "${CHAIN_RULES}"
    return 0
  fi

  COMMENT="${MANAGED_COMMENT_PREFIX}${SOURCE_CIDR} ${LUCI_ADDRESS}:${LUCI_TCP_PORT}"
  if printf '%s\n' "${CHAIN_RULES}" | grep -Fq "comment \"${COMMENT}\""; then
    return 0
  fi

  remove_managed_rules "${CHAIN_RULES}"
  nft "insert rule inet fw4 input ip saddr ${SOURCE_CIDR} ip daddr ${LUCI_ADDRESS} tcp dport ${LUCI_TCP_PORT} counter accept comment \"${COMMENT}\""
}

configure_rule() {
  ENABLED="${ENABLE_DOCKER_LUCI_ACCESS:-0}"
  case "${ENABLED}" in
    0) ;;
    1)
      SOURCE_CIDR="${DOCKER_LUCI_SOURCE_CIDR:-172.16.0.0/12}"
      LUCI_ADDRESS="${LUCI_BIND:-127.0.0.1}"
      LUCI_TCP_PORT="${LUCI_PORT:-18080}"
      validate_enabled_config
      ;;
    *) fail 'ENABLE_DOCKER_LUCI_ACCESS must be 0 or 1' ;;
  esac

  mkdir -p "$(dirname "${UCI_CONFIG_FILE}")"
  touch "${UCI_CONFIG_FILE}"
  uci -q delete "${CONFIG_PACKAGE}.${CONFIG_SECTION}" >/dev/null 2>&1 || true
  uci -q set "${CONFIG_PACKAGE}.${CONFIG_SECTION}=luci_access"
  uci -q set "${CONFIG_PACKAGE}.${CONFIG_SECTION}.enabled=${ENABLED}"
  if [ "${ENABLED}" = '1' ]; then
    uci -q set "${CONFIG_PACKAGE}.${CONFIG_SECTION}.source_cidr=${SOURCE_CIDR}"
    uci -q set "${CONFIG_PACKAGE}.${CONFIG_SECTION}.luci_bind=${LUCI_ADDRESS}"
    uci -q set "${CONFIG_PACKAGE}.${CONFIG_SECTION}.luci_port=${LUCI_TCP_PORT}"
  fi
  uci -q commit "${CONFIG_PACKAGE}"

  uci -q delete "firewall.${FIREWALL_SECTION}" >/dev/null 2>&1 || true
  uci -q set "firewall.${FIREWALL_SECTION}=include"
  uci -q set "firewall.${FIREWALL_SECTION}.type=script"
  uci -q set "firewall.${FIREWALL_SECTION}.path=${FIREWALL_HELPER_PATH}"
  uci -q set "firewall.${FIREWALL_SECTION}.fw4_compatible=1"
  uci -q commit firewall

  apply_rule
}

case "${1:-apply}" in
  apply) apply_rule ;;
  configure) configure_rule ;;
  *) fail "unsupported action: $1" ;;
esac
