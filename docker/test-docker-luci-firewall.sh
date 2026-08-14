#!/bin/sh
set -eu

SOURCE_ROOT="$(CDPATH= cd "$(dirname "$0")" && pwd)"
DEFAULT_FIREWALL_HELPER="${SOURCE_ROOT}/docker-luci-firewall.sh"
if [ ! -x "${DEFAULT_FIREWALL_HELPER}" ]; then
  DEFAULT_FIREWALL_HELPER='/usr/local/sbin/docker-luci-firewall'
fi
FIREWALL_HELPER="${DOCKER_LUCI_FIREWALL_UNDER_TEST:-${DEFAULT_FIREWALL_HELPER}}"
TEST_ROOT="/tmp/docker-luci-firewall-test.$$"

cleanup() {
  case "${TEST_ROOT}" in
    /tmp/docker-luci-firewall-test.*) rm -rf "${TEST_ROOT}" ;;
    *) echo "refusing to remove unexpected test path: ${TEST_ROOT}" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/uci-state"

cat > "${TEST_ROOT}/bin/uci" <<'SH'
#!/bin/sh
set -eu

[ "${1:-}" != '-q' ] || shift
ACTION="${1:-}"
[ "$#" -eq 0 ] || shift

state_path() {
  SAFE_KEY="$(printf '%s' "$1" | tr './-' '___')"
  printf '%s/%s' "${UCI_TEST_STATE}" "${SAFE_KEY}"
}

case "${ACTION}" in
  get)
    TARGET="$(state_path "$1")"
    [ -f "${TARGET}" ] || exit 1
    cat "${TARGET}"
    ;;
  set)
    KEY="${1%%=*}"
    VALUE="${1#*=}"
    printf '%s\n' "${VALUE}" > "$(state_path "${KEY}")"
    ;;
  delete)
    PREFIX="$(state_path "$1")"
    rm -f "${PREFIX}" "${PREFIX}"_*
    ;;
  commit) ;;
  *)
    echo "unexpected fake uci action: ${ACTION}" >&2
    exit 1
    ;;
esac
SH

cat > "${TEST_ROOT}/bin/nft" <<'SH'
#!/bin/sh
set -eu

[ "${1:-}" != '-a' ] || shift
COMMAND="$*"
case "${COMMAND}" in
  'list chain inet fw4 input')
    printf '%s\n' 'chain input {'
    [ ! -f "${NFT_TEST_STATE}" ] || cat "${NFT_TEST_STATE}"
    printf '%s\n' '}'
    ;;
  'insert rule inet fw4 input '*)
    HANDLE=1
    if [ -s "${NFT_TEST_NEXT_HANDLE}" ]; then
      HANDLE="$(cat "${NFT_TEST_NEXT_HANDLE}")"
    fi
    NEXT_HANDLE=$((HANDLE + 1))
    printf '%s\n' "${NEXT_HANDLE}" > "${NFT_TEST_NEXT_HANDLE}"
    printf '  %s # handle %s\n' "${COMMAND}" "${HANDLE}" >> "${NFT_TEST_STATE}"
    printf '%s\n' "${COMMAND}" >> "${NFT_TEST_LOG}"
    ;;
  'delete rule inet fw4 input handle '*)
    HANDLE="${COMMAND##* }"
    awk -v suffix="# handle ${HANDLE}" \
      'substr($0, length($0) - length(suffix) + 1) != suffix' \
      "${NFT_TEST_STATE}" > "${NFT_TEST_STATE}.new"
    mv "${NFT_TEST_STATE}.new" "${NFT_TEST_STATE}"
    printf '%s\n' "${COMMAND}" >> "${NFT_TEST_LOG}"
    ;;
  *)
    echo "unexpected fake nft command: ${COMMAND}" >&2
    exit 1
    ;;
esac
SH
chmod 0755 "${TEST_ROOT}/bin/uci" "${TEST_ROOT}/bin/nft"

export PATH="${TEST_ROOT}/bin:${PATH}"
export UCI_TEST_STATE="${TEST_ROOT}/uci-state"
export NFT_TEST_STATE="${TEST_ROOT}/nft.state"
export NFT_TEST_NEXT_HANDLE="${TEST_ROOT}/nft.next-handle"
export NFT_TEST_LOG="${TEST_ROOT}/nft.log"
export DOCKER_LUCI_UCI_CONFIG_FILE="${TEST_ROOT}/openclash_docker"
: > "${NFT_TEST_STATE}"
: > "${NFT_TEST_LOG}"

# Invalid external values must fail before UCI or nft state is changed.
if ENABLE_DOCKER_LUCI_ACCESS=2 "${FIREWALL_HELPER}" configure; then
  echo 'invalid enable switch unexpectedly succeeded' >&2
  exit 1
fi
if ENABLE_DOCKER_LUCI_ACCESS=1 \
  DOCKER_LUCI_SOURCE_CIDR='172.16.0.0/12;drop table inet fw4' \
  LUCI_BIND=192.0.2.20 \
  LUCI_PORT=18080 \
  "${FIREWALL_HELPER}" configure; then
  echo 'invalid Docker source CIDR unexpectedly succeeded' >&2
  exit 1
fi
if ENABLE_DOCKER_LUCI_ACCESS=1 \
  DOCKER_LUCI_SOURCE_CIDR=172.18.0.0/16 \
  LUCI_BIND=0.0.0.0 \
  LUCI_PORT=18080 \
  "${FIREWALL_HELPER}" configure; then
  echo 'wildcard LuCI bind unexpectedly succeeded' >&2
  exit 1
fi
if ENABLE_DOCKER_LUCI_ACCESS=1 \
  DOCKER_LUCI_SOURCE_CIDR=172.18.0.0/16 \
  LUCI_BIND=127.0.0.1 \
  LUCI_PORT=18080 \
  "${FIREWALL_HELPER}" configure; then
  echo 'loopback LuCI bind unexpectedly succeeded' >&2
  exit 1
fi
if ENABLE_DOCKER_LUCI_ACCESS=1 \
  DOCKER_LUCI_SOURCE_CIDR=172.18.0.0/16 \
  LUCI_BIND=192.0.2.20 \
  LUCI_PORT=70000 \
  "${FIREWALL_HELPER}" configure; then
  echo 'invalid LuCI port unexpectedly succeeded' >&2
  exit 1
fi
[ ! -s "${NFT_TEST_LOG}" ]
[ ! -e "${DOCKER_LUCI_UCI_CONFIG_FILE}" ]

# Configure the fw4 include and install one narrow rule.
ENABLE_DOCKER_LUCI_ACCESS=1 \
DOCKER_LUCI_SOURCE_CIDR=172.18.0.0/16 \
LUCI_BIND=192.0.2.20 \
LUCI_PORT=18080 \
  "${FIREWALL_HELPER}" configure
[ "$(uci -q get openclash_docker.luci_access.enabled)" = 1 ]
[ "$(uci -q get openclash_docker.luci_access.source_cidr)" = 172.18.0.0/16 ]
[ "$(uci -q get openclash_docker.luci_access.luci_bind)" = 192.0.2.20 ]
[ "$(uci -q get openclash_docker.luci_access.luci_port)" = 18080 ]
[ "$(uci -q get firewall.docker_luci_access.path)" = /usr/local/sbin/docker-luci-firewall ]
[ "$(uci -q get firewall.docker_luci_access.fw4_compatible)" = 1 ]
[ "$(wc -l < "${NFT_TEST_STATE}")" -eq 1 ]
grep -Fq \
  'ip saddr 172.18.0.0/16 ip daddr 192.0.2.20 tcp dport 18080' \
  "${NFT_TEST_STATE}"

# Reapplying the helper or the fw4 include must not duplicate the rule.
BEFORE_IDEMPOTENT_LINES="$(wc -l < "${NFT_TEST_LOG}")"
"${FIREWALL_HELPER}" apply
"${FIREWALL_HELPER}" apply
[ "$(wc -l < "${NFT_TEST_LOG}")" -eq "${BEFORE_IDEMPOTENT_LINES}" ]
[ "$(wc -l < "${NFT_TEST_STATE}")" -eq 1 ]

# A flushed input chain, as produced by fw4 or OpenClash, is repopulated from
# the stored UCI contract without running the entrypoint again.
: > "${NFT_TEST_STATE}"
"${FIREWALL_HELPER}" apply
[ "$(wc -l < "${NFT_TEST_STATE}")" -eq 1 ]
grep -Fq 'tcp dport 18080' "${NFT_TEST_STATE}"

# A changed endpoint replaces the stale managed rule instead of widening it.
ENABLE_DOCKER_LUCI_ACCESS=1 \
DOCKER_LUCI_SOURCE_CIDR=172.18.0.0/16 \
LUCI_BIND=192.0.2.21 \
LUCI_PORT=19090 \
  "${FIREWALL_HELPER}" configure
[ "$(wc -l < "${NFT_TEST_STATE}")" -eq 1 ]
grep -Fq \
  'ip saddr 172.18.0.0/16 ip daddr 192.0.2.21 tcp dport 19090' \
  "${NFT_TEST_STATE}"
if grep -Fq 'tcp dport 18080' "${NFT_TEST_STATE}"; then
  echo 'stale LuCI firewall rule was not removed' >&2
  exit 1
fi

# Disabling the feature removes the active rule and leaves the fw4 cleanup
# include registered for future reloads.
ENABLE_DOCKER_LUCI_ACCESS=0 "${FIREWALL_HELPER}" configure
[ "$(uci -q get openclash_docker.luci_access.enabled)" = 0 ]
[ ! -s "${NFT_TEST_STATE}" ]
if uci -q get openclash_docker.luci_access.luci_port >/dev/null 2>&1; then
  echo 'disabled configuration retained the LuCI port' >&2
  exit 1
fi
[ "$(uci -q get firewall.docker_luci_access.type)" = script ]

echo '[docker-luci-firewall] tests passed'
