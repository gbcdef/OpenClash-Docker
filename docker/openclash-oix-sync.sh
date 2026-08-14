#!/bin/sh
set -u

CONFIG_DIRECTORY="${OPENCLASH_OIX_CONFIG_DIR:-/etc/openclash/config}"
CONFIG_PATH="${CONFIG_DIRECTORY}/oixCloud - smart.yaml"
TEMPORARY_PATH="${CONFIG_PATH}.new.$$"
ERROR_PATH="/tmp/openclash-oix-sync-error.$$"
SUBSCRIPTION_URL="${1:-}"

cleanup() {
  rm -f "${TEMPORARY_PATH}" "${ERROR_PATH}"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'ERROR\t%s\n' "$1"
  exit 1
}

case "${SUBSCRIPTION_URL}" in
  https://*) ;;
  *) fail "subscription URL must use HTTPS" ;;
esac

if ! mkdir -p "${CONFIG_DIRECTORY}"; then
  fail "cannot create the OpenClash config directory"
fi
if [ ! -d "${CONFIG_DIRECTORY}" ] || [ ! -w "${CONFIG_DIRECTORY}" ]; then
  fail "OpenClash config directory is not writable"
fi

rm -f "${TEMPORARY_PATH}" "${ERROR_PATH}"
CURL_EXIT_CODE=0
curl \
  --fail \
  --location \
  --show-error \
  --silent \
  --connect-timeout 10 \
  --max-time 180 \
  --retry 2 \
  --proto '=https' \
  --proto-redir '=https' \
  --user-agent clash \
  --output "${TEMPORARY_PATH}" \
  "${SUBSCRIPTION_URL}" 2>"${ERROR_PATH}" || CURL_EXIT_CODE="$?"
if [ "${CURL_EXIT_CODE}" -ne 0 ]; then
  case "${CURL_EXIT_CODE}" in
    6) CURL_FAILURE="subscription host could not be resolved" ;;
    22) CURL_FAILURE="subscription server returned an HTTP error" ;;
    23) CURL_FAILURE="subscription response could not be written" ;;
    28) CURL_FAILURE="subscription download timed out" ;;
    *) CURL_FAILURE="subscription download failed (curl exit ${CURL_EXIT_CODE})" ;;
  esac
  fail "${CURL_FAILURE}"
fi

if [ ! -s "${TEMPORARY_PATH}" ]; then
  fail "subscription response is empty"
fi

if ! ruby -ryaml -e '
  content = File.binread(ARGV.fetch(0))
  value = begin
    YAML.safe_load(
      content,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: true
    )
  rescue ArgumentError
    YAML.safe_load(content, [], [], true)
  end
  valid = value.is_a?(Hash) &&
    value["proxy-providers"].is_a?(Hash) &&
    !value["proxy-providers"].empty? &&
    value["proxy-groups"].is_a?(Array) &&
    !value["proxy-groups"].empty?
  exit(valid ? 0 : 1)
' "${TEMPORARY_PATH}" >/dev/null 2>&1; then
  fail "subscription response is not a valid Clash YAML configuration"
fi

if ! chmod 0600 "${TEMPORARY_PATH}"; then
  fail "validated subscription permissions could not be secured"
fi
if ! mv -f "${TEMPORARY_PATH}" "${CONFIG_PATH}"; then
  fail "validated subscription could not be installed"
fi

printf 'OK\t%s\n' "${CONFIG_PATH}"
