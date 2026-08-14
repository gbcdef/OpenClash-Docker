#!/bin/sh
set -eu

TEST_ROOT="/tmp/openclash-oix-sync-test.$$"
CONFIG_DIRECTORY="${TEST_ROOT}/config"
FAKE_BIN="${TEST_ROOT}/bin"
SYNC_SCRIPT="${OPENCLASH_OIX_SYNC_SCRIPT:-/usr/local/sbin/openclash-oix-sync}"
CONFIG_PATH="${CONFIG_DIRECTORY}/oixCloud - smart.yaml"

cleanup() {
  case "${TEST_ROOT}" in
    /tmp/openclash-oix-sync-test.*) rm -rf "${TEST_ROOT}" ;;
    *) echo "refusing to remove unexpected test path: ${TEST_ROOT}" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/curl" <<'SH'
#!/bin/sh
set -eu

OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done

[ -n "${OUTPUT}" ]
case "${MOCK_CURL_RESULT:-success}" in
  success)
    cat > "${OUTPUT}" <<'YAML'
proxy-providers:
  oixCloud:
    type: http
proxy-groups:
  - name: Proxy
    type: select
    proxies: [DIRECT]
YAML
    ;;
  invalid)
    printf '%s\n' 'not-a-clash-config: true' > "${OUTPUT}"
    ;;
  http_error)
    exit 22
    ;;
  *) exit 2 ;;
esac
SH
chmod 0755 "${FAKE_BIN}/curl"

PATH="${FAKE_BIN}:${PATH}" \
OPENCLASH_OIX_CONFIG_DIR="${CONFIG_DIRECTORY}" \
  "${SYNC_SCRIPT}" 'https://example.invalid/oix subscription'

test -s "${CONFIG_PATH}"
grep -Fq 'proxy-providers:' "${CONFIG_PATH}"
grep -Fq 'proxy-groups:' "${CONFIG_PATH}"
ruby -e 'exit((File.stat(ARGV.fetch(0)).mode & 0777) == 0600 ? 0 : 1)' \
  "${CONFIG_PATH}"
ORIGINAL_SHA256="$(sha256sum "${CONFIG_PATH}" | awk '{ print $1 }')"

if PATH="${FAKE_BIN}:${PATH}" \
  MOCK_CURL_RESULT=http_error \
  OPENCLASH_OIX_CONFIG_DIR="${CONFIG_DIRECTORY}" \
  "${SYNC_SCRIPT}" 'https://example.invalid/oix subscription'; then
  echo "HTTP failure unexpectedly replaced the subscription" >&2
  exit 1
fi
[ "$(sha256sum "${CONFIG_PATH}" | awk '{ print $1 }')" = "${ORIGINAL_SHA256}" ]

if PATH="${FAKE_BIN}:${PATH}" \
  MOCK_CURL_RESULT=invalid \
  OPENCLASH_OIX_CONFIG_DIR="${CONFIG_DIRECTORY}" \
  "${SYNC_SCRIPT}" 'https://example.invalid/oix subscription'; then
  echo "Invalid YAML unexpectedly replaced the subscription" >&2
  exit 1
fi
[ "$(sha256sum "${CONFIG_PATH}" | awk '{ print $1 }')" = "${ORIGINAL_SHA256}" ]

if OPENCLASH_OIX_CONFIG_DIR="${CONFIG_DIRECTORY}" \
  "${SYNC_SCRIPT}" 'http://example.invalid/not-https'; then
  echo "Non-HTTPS subscription URL unexpectedly succeeded" >&2
  exit 1
fi

if find "${CONFIG_DIRECTORY}" -name '*.new.*' -print | grep -q .; then
  echo "Temporary subscription file was not cleaned up" >&2
  exit 1
fi

echo "[oix-sync] tests passed"
