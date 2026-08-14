#!/bin/sh
set -eu

HOST_NETWORK="${HOST_NETWORK:-0}"
HOST_LAN_INTERFACE="${HOST_LAN_INTERFACE:-eth0}"
LUCI_BIND="${LUCI_BIND:-127.0.0.1}"
LUCI_PORT="${LUCI_PORT:-18080}"
DEFAULTS_DIR="${DEFAULTS_DIR:-/usr/local/share/openclash-defaults}"
ENABLE_OPENCLASH_HOOKS="${ENABLE_OPENCLASH_HOOKS:-1}"
OPENCLASH_HOOK_SOURCE="${OPENCLASH_HOOK_SOURCE:-/usr/local/share/openclash-hooks/openclash_custom_overwrite.sh}"
OPENCLASH_FIREWALL_HOOK_SOURCE="${OPENCLASH_FIREWALL_HOOK_SOURCE:-/usr/local/share/openclash-hooks/openclash_custom_firewall_rules.sh}"

ensure_root_filesystem_writable() {
  PROBE_DIRECTORY="/.openclash-container-write-test.$$"

  if mkdir "${PROBE_DIRECTORY}" 2>/dev/null; then
    rmdir "${PROBE_DIRECTORY}"
    return 0
  fi

  # OpenWrt remounts its root filesystem read-only during a clean shutdown.
  # Docker can reuse that mount state when starting the same container again.
  ROOT_MOUNT_SOURCE="$(awk '$2 == "/" { print $1; exit }' /proc/mounts)"
  if [ -z "${ROOT_MOUNT_SOURCE}" ] \
    || ! mount -o remount,rw "${ROOT_MOUNT_SOURCE}" / >/dev/null 2>&1; then
    echo "[entrypoint] failed to remount the container root filesystem read-write" >&2
    exit 1
  fi
  if ! mkdir "${PROBE_DIRECTORY}" 2>/dev/null; then
    echo "[entrypoint] container root filesystem is read-only" >&2
    exit 1
  fi
  rmdir "${PROBE_DIRECTORY}"
}

initialize_persistent_directory() {
  SOURCE_DIR="$1"
  TARGET_DIR="$2"

  mkdir -p "${TARGET_DIR}"
  if directory_has_entries "${TARGET_DIR}"; then
    return
  fi

  if [ ! -d "${SOURCE_DIR}" ]; then
    echo "[entrypoint] missing defaults directory: ${SOURCE_DIR}" >&2
    exit 1
  fi

  echo "[entrypoint] initializing ${TARGET_DIR}"
  cp -a "${SOURCE_DIR}/." "${TARGET_DIR}/"
}

directory_has_entries() {
  for ENTRY in "${1}"/* "${1}"/.[!.]* "${1}"/..?*; do
    if [ -e "${ENTRY}" ] || [ -L "${ENTRY}" ]; then
      return 0
    fi
  done
  return 1
}

initialize_persistent_data() {
  initialize_persistent_directory "${DEFAULTS_DIR}/config" /etc/config
  initialize_persistent_directory "${DEFAULTS_DIR}/openclash" /etc/openclash
  mkdir -p /etc/openclash/config
  install_packaged_openclash_assets
}

ensure_system_config() {
  if uci -q get 'system.@system[0]' >/dev/null 2>&1; then
    return 0
  fi

  # Some OpenWrt rootfs releases do not include /etc/config/system. Without a
  # system section the log init script creates no logd instance, so /dev/log
  # remains absent and dnsmasq cannot start inside its procd jail.
  echo "[entrypoint] creating missing OpenWrt system config"
  touch /etc/config/system
  uci -q delete system.container || true
  uci set system.container='system'
  uci set system.container.hostname='openclash'
  uci set system.container.timezone='CST-8'
  uci set "system.container.zonename=${TZ:-Asia/Shanghai}"
  uci set system.container.log_size='64'
  uci commit system
}

install_packaged_openclash_assets() {
  for RELATIVE_PATH in \
    core/clash_meta \
    core/.packaged-oix-version \
    Country.mmdb \
    GeoIP.dat \
    GeoSite.dat \
    ASN.mmdb \
    china_ip_route.ipset \
    china_ip6_route.ipset; do
    SOURCE="${DEFAULTS_DIR}/openclash/${RELATIVE_PATH}"
    TARGET="/etc/openclash/${RELATIVE_PATH}"

    case "${RELATIVE_PATH}" in
      core/clash_meta)
        [ -x "${TARGET}" ] && continue
        ;;
      *)
        [ -s "${TARGET}" ] && continue
        ;;
    esac

    if [ ! -s "${SOURCE}" ]; then
      echo "[entrypoint] packaged OpenClash asset is missing: ${RELATIVE_PATH}" >&2
      exit 1
    fi

    echo "[entrypoint] installing packaged OpenClash asset: ${RELATIVE_PATH}"
    mkdir -p "$(dirname "${TARGET}")"
    cp -a "${SOURCE}" "${TARGET}.new"
    mv -f "${TARGET}.new" "${TARGET}"
  done
}

configure_openclash_hooks() {
  [ "${ENABLE_OPENCLASH_HOOKS}" = "1" ] || return 0

  mkdir -p /etc/openclash/custom

  install_openclash_hook \
    "${OPENCLASH_HOOK_SOURCE}" \
    /etc/openclash/custom/openclash_custom_overwrite.sh \
    /etc/openclash/custom/openclash_custom_overwrite.before-docker-hooks.sh
  install_openclash_hook \
    "${OPENCLASH_FIREWALL_HOOK_SOURCE}" \
    /etc/openclash/custom/openclash_custom_firewall_rules.sh \
    /etc/openclash/custom/openclash_custom_firewall_rules.before-docker-hooks.sh
}

install_openclash_hook() {
  SOURCE="$1"
  TARGET="$2"
  BACKUP="$3"
  TEMPORARY_TARGET="${TARGET}.new.$$"

  if [ ! -f "${SOURCE}" ]; then
    echo "[entrypoint] OpenClash hook is missing: ${SOURCE}" >&2
    exit 1
  fi

  if [ -f "${TARGET}" ] \
    && ! cmp -s "${SOURCE}" "${TARGET}" \
    && [ ! -e "${BACKUP}" ]; then
    echo "[entrypoint] preserving existing OpenClash hook: ${TARGET}"
    cp -a "${TARGET}" "${BACKUP}"
  fi

  rm -f "${TEMPORARY_TARGET}"
  cp "${SOURCE}" "${TEMPORARY_TARGET}"
  chmod 0755 "${TEMPORARY_TARGET}"
  mv -f "${TEMPORARY_TARGET}" "${TARGET}"
}

configure_root_password() {
  ROOT_PASSWORD_FILE="${ROOT_PASSWORD_FILE:-/run/secrets/root_password}"
  if [ ! -r "${ROOT_PASSWORD_FILE}" ]; then
    echo "[entrypoint] missing /run/secrets/root_password" >&2
    exit 1
  fi

  ROOT_PASSWORD="$(cat "${ROOT_PASSWORD_FILE}")"
  if [ -z "${ROOT_PASSWORD}" ]; then
    echo "[entrypoint] root password secret must be non-empty" >&2
    exit 1
  fi

  ROOT_PASSWORD_SINGLE_LINE="$(printf '%s' "${ROOT_PASSWORD}" | tr -d '\r\n')"
  if [ "${ROOT_PASSWORD_SINGLE_LINE}" != "${ROOT_PASSWORD}" ]; then
    echo "[entrypoint] root password secret must contain no newline" >&2
    exit 1
  fi

  if ! PASSWD_OUTPUT="$(
    printf '%s\n%s\n' "${ROOT_PASSWORD}" "${ROOT_PASSWORD}" |
      passwd root 2>&1
  )"; then
    echo "[entrypoint] failed to set root password" >&2
    printf '%s\n' "${PASSWD_OUTPUT}" >&2
    exit 1
  fi
  unset ROOT_PASSWORD ROOT_PASSWORD_SINGLE_LINE PASSWD_OUTPUT
}

configure_container_console() {
  case "${ENABLE_CONTAINER_CONSOLE:-0}" in
    0)
      [ -f /etc/inittab ] || return 0
      # OpenWrt's default inittab starts login shells on console devices. A
      # privileged container may resolve those devices to the host consoles.
      sed -i \
        -e '/::askfirst:/d' \
        -e '/::askconsole:/d' \
        /etc/inittab
      ;;
    1)
      echo "[entrypoint] container console login explicitly enabled" >&2
      ;;
    *)
      echo "[entrypoint] ENABLE_CONTAINER_CONSOLE must be 0 or 1" >&2
      exit 1
      ;;
  esac
}

configure_host_network() {
  if ! ip link show dev "${HOST_LAN_INTERFACE}" >/dev/null 2>&1; then
    echo "[entrypoint] host interface ${HOST_LAN_INTERFACE} does not exist" >&2
    exit 1
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
  sysctl -w "net.ipv4.conf.${HOST_LAN_INTERFACE}.rp_filter=0" >/dev/null

  # These OpenWrt services must never manage the Ubuntu host namespace.
  for service in boot network dropbear odhcpd sysntpd packet_steering ucitrack gpio_switch led sysctl; do
    "/etc/init.d/${service}" disable >/dev/null 2>&1 || true
  done

  mkdir -p /var/lock /var/log /var/run /var/state /var/tmp /tmp/.uci /tmp/resolv.conf.d /etc/crontabs
  chmod 1777 /var/lock
  chmod 0700 /tmp/.uci
  touch /var/log/wtmp /var/log/lastlog /tmp/resolv.conf.d/resolv.conf.auto /etc/crontabs/root

  # Bind LuCI to the configured Ubuntu address and avoid ports 80/443.
  uci -q delete uhttpd.main.listen_http || true
  uci -q add_list "uhttpd.main.listen_http=${LUCI_BIND}:${LUCI_PORT}"
  uci -q delete uhttpd.main.listen_https || true
  uci -q set uhttpd.main.redirect_https='0'
  uci -q commit uhttpd

  # One-arm side-router firewall: accept all traffic forwarded from the
  # physical LAN interface. Mihomo performs transparent interception.
  uci -q del_list "firewall.@zone[0].device=eth0" >/dev/null 2>&1 || true
  uci -q del_list "firewall.@zone[0].device=${HOST_LAN_INTERFACE}" >/dev/null 2>&1 || true
  uci -q add_list "firewall.@zone[0].device=${HOST_LAN_INTERFACE}"
  uci -q delete firewall.side_router_forward || true
  uci -q set firewall.side_router_forward='rule'
  uci -q set firewall.side_router_forward.name='Allow-SideRouter-Forward'
  uci -q set firewall.side_router_forward.src='lan'
  uci -q delete firewall.side_router_forward.src_ip || true
  uci -q set firewall.side_router_forward.dest='*'
  uci -q set firewall.side_router_forward.proto='all'
  uci -q set firewall.side_router_forward.family='ipv4'
  uci -q set firewall.side_router_forward.target='ACCEPT'

  # Mihomo redirects marked Docker TCP connections to a dynamic local port.
  # Allow only that marked traffic into the host input path.
  uci -q delete firewall.docker_tun_input || true
  uci -q set firewall.docker_tun_input='rule'
  uci -q set firewall.docker_tun_input.name='Allow-Docker-TUN-Input'
  uci -q set firewall.docker_tun_input.src='*'
  uci -q set firewall.docker_tun_input.src_ip='172.16.0.0/12'
  uci -q set firewall.docker_tun_input.mark='0x162/0xffffffff'
  uci -q set firewall.docker_tun_input.proto='all'
  uci -q set firewall.docker_tun_input.family='ipv4'
  uci -q set firewall.docker_tun_input.target='ACCEPT'

  # Allow containers to reach an HTTPS reverse proxy on the host. Keep this
  # exception limited to HTTPS and the standard Docker private address range.
  uci -q delete firewall.docker_https_input || true
  uci -q set firewall.docker_https_input='rule'
  uci -q set firewall.docker_https_input.name='Allow-Docker-Host-HTTPS'
  uci -q set firewall.docker_https_input.src='*'
  uci -q set firewall.docker_https_input.src_ip='172.16.0.0/12'
  uci -q set firewall.docker_https_input.dest_port='443'
  uci -q set firewall.docker_https_input.proto='tcp'
  uci -q set firewall.docker_https_input.family='ipv4'
  uci -q set firewall.docker_https_input.target='ACCEPT'

  # Capture host and Docker embedded-DNS upstream queries without restarting
  # the Docker daemon or changing every Compose project.
  uci -q delete firewall.docker_dns_hijack || true
  uci -q set firewall.docker_dns_hijack='include'
  uci -q set firewall.docker_dns_hijack.type='script'
  uci -q set firewall.docker_dns_hijack.path='/usr/local/sbin/docker-tun-firewall'
  uci -q set firewall.docker_dns_hijack.fw4_compatible='1'
  uci -q commit firewall
  /etc/init.d/firewall enable >/dev/null 2>&1 || true

  # Serve LAN DNS on the host LAN address and forward to Mihomo's DNS listener.
  uci -q set dhcp.@dnsmasq[0].port='53'
  uci -q set dhcp.@dnsmasq[0].noresolv='1'
  uci -q set dhcp.@dnsmasq[0].bindinterfaces='1'
  uci -q delete dhcp.@dnsmasq[0].listen_address || true
  uci -q add_list "dhcp.@dnsmasq[0].listen_address=${LUCI_BIND}"
  uci -q add_list dhcp.@dnsmasq[0].listen_address='127.0.0.1'
  uci -q delete dhcp.@dnsmasq[0].server || true
  uci -q add_list "dhcp.@dnsmasq[0].server=127.0.0.1#${DNS_PORT:-7874}"
  uci -q set dhcp.lan.ignore='1'
  uci -q set dhcp.wan.ignore='1'
  uci -q commit dhcp
  /etc/init.d/dnsmasq enable >/dev/null 2>&1 || true

  # Keep OpenClash's standard ports, except mixed/http are swapped because
  # mixed-port 7890 was explicitly requested.
  uci -q set openclash.config.lan_interface_name="${HOST_LAN_INTERFACE}"
  uci -q set openclash.config.interface_name="${HOST_LAN_INTERFACE}"
  uci -q set openclash.config.http_port="${HTTP_PROXY_PORT:-7893}"
  uci -q set openclash.config.socks_port="${SOCKS_PROXY_PORT:-7891}"
  uci -q set openclash.config.proxy_port="${REDIR_PROXY_PORT:-7892}"
  uci -q set openclash.config.mixed_port="${MIXED_PROXY_PORT:-7890}"
  uci -q set openclash.config.tproxy_port="${TPROXY_PORT:-7895}"
  uci -q set openclash.config.dns_port="${DNS_PORT:-7874}"
  uci -q set openclash.config.cn_port="${CONTROLLER_PORT:-9090}"
  uci -q set openclash.config.en_mode='fake-ip-tun'
  uci -q set openclash.config.stack_type='system'
  uci -q commit openclash
}

configure_bridge_network() {
  DOCKER_IPV4_CIDR="$(ip -4 -o addr show dev eth0 2>/dev/null | awk 'NR == 1 { print $4 }')"
  DOCKER_IPV4_GATEWAY="$(ip -4 route show default dev eth0 2>/dev/null | awk 'NR == 1 { print $3 }')"

  if [ -z "${DOCKER_IPV4_CIDR}" ]; then
    echo "[entrypoint] Docker did not assign an IPv4 address to eth0" >&2
    exit 1
  fi

  /etc/init.d/network disable >/dev/null 2>&1 || true
  uci -q set openclash.config.lan_interface_name='eth0'
  uci -q commit openclash

  uci -q del_list "firewall.@zone[0].device=eth0" >/dev/null 2>&1 || true
  uci -q add_list "firewall.@zone[0].device=eth0"
  uci -q commit firewall

  restore_docker_network() {
    attempt=0
    while [ "${attempt}" -lt 45 ]; do
      ip link set dev eth0 up >/dev/null 2>&1 || true
      ip -4 addr replace "${DOCKER_IPV4_CIDR}" dev eth0 >/dev/null 2>&1 || true
      if [ -n "${DOCKER_IPV4_GATEWAY}" ]; then
        ip -4 route replace default via "${DOCKER_IPV4_GATEWAY}" dev eth0 >/dev/null 2>&1 || true
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
  }

  restore_docker_network &
}

ensure_root_filesystem_writable
initialize_persistent_data
ensure_system_config
configure_openclash_hooks

if [ "${HOST_NETWORK}" = "1" ]; then
  configure_host_network
else
  configure_bridge_network
fi

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
fi

configure_container_console
configure_root_password
exec "$@"
