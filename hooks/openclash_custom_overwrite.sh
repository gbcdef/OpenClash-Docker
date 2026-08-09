#!/bin/sh
set -eu

CONFIG_FILE="${1:-}"
HOOK_ROOT="${OPENCLASH_HOOK_ROOT:-/usr/local/share/openclash-hooks}"
HOOK_DIR="${HOOK_ROOT}/hooks.d"
PREVIOUS_HOOK='/etc/openclash/custom/openclash_custom_overwrite.before-docker-hooks.sh'

if [ -z "${CONFIG_FILE}" ]; then
  exit 0
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "[openclash-hooks] generated config does not exist: ${CONFIG_FILE}" >&2
  exit 1
fi

ROLLBACK_FILE="${CONFIG_FILE}.openclash-hooks.$$"
HOOKS_SUCCEEDED=0
cp -p "${CONFIG_FILE}" "${ROLLBACK_FILE}"

restore_on_failure() {
  if [ "${HOOKS_SUCCEEDED}" != "1" ]; then
    echo "[openclash-hooks] hook failed; restoring generated config" >&2
    cp -p "${ROLLBACK_FILE}" "${CONFIG_FILE}" || true
  fi
  rm -f "${ROLLBACK_FILE}"
}
trap restore_on_failure EXIT INT TERM

if [ -f "${PREVIOUS_HOOK}" ]; then
  echo "[openclash-hooks] running preserved overwrite script"
  /bin/sh "${PREVIOUS_HOOK}" "${CONFIG_FILE}"
fi

for HOOK in "${HOOK_DIR}"/*.sh; do
  [ -f "${HOOK}" ] || continue
  echo "[openclash-hooks] running $(basename "${HOOK}")"
  /bin/sh "${HOOK}" "${CONFIG_FILE}"
done

HOOKS_SUCCEEDED=1
