#!/bin/sh
set -eu

OPENCLASH_RELEASE="${1:-}"
OIX_CORE_RELEASE="${2:-Pre-Alpha}"

if [ -z "${OPENCLASH_RELEASE}" ]; then
  echo "[build] OpenClash release is required" >&2
  exit 1
fi

OIX_CORE_RELEASE_URL="https://github.com/vernesong/mihomo-oix/releases/download/${OIX_CORE_RELEASE}"

download_with_sha256() {
  URL="$1"
  TARGET="$2"
  CHECKSUM_FILE="${TARGET}.sha256sum"

  curl -fL --retry 3 --connect-timeout 20 "${URL}" -o "${TARGET}"
  curl -fL --retry 3 --connect-timeout 20 "${URL}.sha256sum" -o "${CHECKSUM_FILE}"
  EXPECTED_SHA256="$(awk 'NR == 1 { print $1 }' "${CHECKSUM_FILE}")"
  ACTUAL_SHA256="$(sha256sum "${TARGET}" | awk '{ print $1 }')"
  rm -f "${CHECKSUM_FILE}"

  if [ -z "${EXPECTED_SHA256}" ] || [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
    echo "[build] Checksum mismatch for ${URL}" >&2
    exit 1
  fi
}

generate_nft_cidr_set() {
  SOURCE="$1"
  SET_NAME="$2"
  ADDRESS_TYPE="$3"
  TARGET="$4"

  awk -v set_name="${SET_NAME}" -v address_type="${ADDRESS_TYPE}" '
    BEGIN {
      print "define " set_name " = {"
      count = 0
      invalid = 0
    }
    /^$/ || /^#/ { next }
    $0 !~ /^[0-9A-Fa-f:.]+\/[0-9]+$/ {
      invalid = 1
      next
    }
    {
      print "    " $0 ","
      count++
    }
    END {
      print "}"
      print "add set inet fw4 " set_name " { type " address_type "; flags interval; auto-merge; }"
      print "add element inet fw4 " set_name " $" set_name
      if (invalid || count < 100) {
        exit 1
      }
    }
  ' "${SOURCE}" > "${TARGET}"
}

mkdir -p /var/lock

# OpenWrt rc.common calls a global sync before service actions. In this Docker
# environment that call can block indefinitely on the host storage layer.
# Container data is already persisted by Docker volumes, so keep a no-op wrapper
# inside this image and retain the original as /bin/sync.real for diagnostics.
mv /bin/sync /bin/sync.real
printf '#!/bin/sh\nexit 0\n' > /bin/sync
chmod 0755 /bin/sync

# Tell package post-install scripts they are populating an offline root. This
# prevents attempts to restart DNS, ubus, and LuCI services during image build.
export IPKG_INSTROOT=/

echo "[build] Refreshing OpenWrt package indexes"
opkg update

# dnsmasq-full 与基础镜像自带的 dnsmasq 冲突；OpenClash 需要 full 版本。
opkg remove dnsmasq >/dev/null 2>&1 || true

echo "[build] Installing OpenClash runtime dependencies"
opkg install \
  bash \
  ca-bundle \
  curl \
  dnsmasq-full \
  ip-full \
  kmod-inet-diag \
  kmod-nft-tproxy \
  kmod-tun \
  luci \
  luci-base \
  luci-compat \
  ruby \
  ruby-yaml \
  unzip

if [ "${OPENCLASH_RELEASE}" = "latest" ]; then
  echo "[build] Resolving latest OpenClash release"
  OPENCLASH_RELEASE_URL="$(curl -fLsS \
    --retry 3 \
    --connect-timeout 20 \
    --output /dev/null \
    --write-out '%{url_effective}' \
    https://github.com/vernesong/OpenClash/releases/latest)"
  OPENCLASH_RELEASE="${OPENCLASH_RELEASE_URL##*/}"
fi

OPENCLASH_VERSION="${OPENCLASH_RELEASE#v}"
case "${OPENCLASH_VERSION}" in
  ''|*[!A-Za-z0-9._-]*)
    echo "[build] Invalid OpenClash release: ${OPENCLASH_RELEASE}" >&2
    exit 1
    ;;
esac
OPENCLASH_ASSET="luci-app-openclash_${OPENCLASH_VERSION}_all.ipk"

if [ -f /tmp/vendor/openclash.ipk ]; then
  echo "[build] Using vendor/openclash.ipk"
  cp /tmp/vendor/openclash.ipk /tmp/openclash.ipk
else
  OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_VERSION}/${OPENCLASH_ASSET}"
  echo "[build] Downloading ${OPENCLASH_URL}"
  curl -fL --retry 3 --connect-timeout 20 "${OPENCLASH_URL}" -o /tmp/openclash.ipk
fi

opkg install /tmp/openclash.ipk

echo "[build] Resolving latest Oix core from ${OIX_CORE_RELEASE}"
curl -fL --retry 3 --connect-timeout 20 \
  "${OIX_CORE_RELEASE_URL}/version.txt" \
  -o /tmp/oix-core-version.txt
curl -fL --retry 3 --connect-timeout 20 \
  "${OIX_CORE_RELEASE_URL}/checksums.txt" \
  -o /tmp/oix-core-checksums.txt

OIX_CORE_VERSION="$(tr -d '\r\n' </tmp/oix-core-version.txt)"
case "${OIX_CORE_VERSION}" in
  ''|*[!A-Za-z0-9._-]*)
    echo "[build] Invalid Oix core version: ${OIX_CORE_VERSION}" >&2
    exit 1
    ;;
esac

OIX_CORE_ASSET="mihomo-linux-amd64-${OIX_CORE_VERSION}.gz"
OIX_CORE_SHA256="$(awk -v asset="./${OIX_CORE_ASSET}" '$2 == asset { print $1 }' /tmp/oix-core-checksums.txt)"
if [ -z "${OIX_CORE_SHA256}" ]; then
  echo "[build] Missing checksum for ${OIX_CORE_ASSET}" >&2
  exit 1
fi

echo "[build] Downloading ${OIX_CORE_ASSET}"
curl -fL --retry 3 --connect-timeout 20 \
  "${OIX_CORE_RELEASE_URL}/${OIX_CORE_ASSET}" \
  -o /tmp/oix-core.gz
ACTUAL_OIX_CORE_SHA256="$(sha256sum /tmp/oix-core.gz | awk '{ print $1 }')"
if [ "${ACTUAL_OIX_CORE_SHA256}" != "${OIX_CORE_SHA256}" ]; then
  echo "[build] Checksum mismatch for ${OIX_CORE_ASSET}" >&2
  exit 1
fi
gzip -t /tmp/oix-core.gz

mkdir -p /etc/openclash/core
gzip -dc /tmp/oix-core.gz > /etc/openclash/core/clash_meta
chmod 0755 /etc/openclash/core/clash_meta
/etc/openclash/core/clash_meta -v
printf '%s\n' "${OIX_CORE_VERSION}" > /etc/openclash/core/.packaged-oix-version

echo "[build] Downloading latest public OpenClash data assets"
download_with_sha256 \
  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
  /etc/openclash/GeoIP.dat
download_with_sha256 \
  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
  /etc/openclash/GeoSite.dat
download_with_sha256 \
  "https://github.com/xishang0128/geoip/releases/latest/download/Country.mmdb" \
  /etc/openclash/Country.mmdb
curl -fL --retry 3 --connect-timeout 20 \
  "https://github.com/xishang0128/geoip/releases/latest/download/GeoLite2-ASN.mmdb" \
  -o /etc/openclash/ASN.mmdb
grep -aq 'MaxMind.com' /etc/openclash/Country.mmdb
grep -aq 'MaxMind.com' /etc/openclash/ASN.mmdb

echo "[build] Downloading latest China route lists"
curl -fL --retry 3 --connect-timeout 20 \
  "https://ispip.clang.cn/all_cn.txt" \
  -o /tmp/china-ipv4.txt
curl -fL --retry 3 --connect-timeout 20 \
  "https://ispip.clang.cn/all_cn_ipv6.txt" \
  -o /tmp/china-ipv6.txt
generate_nft_cidr_set \
  /tmp/china-ipv4.txt \
  china_ip_route \
  ipv4_addr \
  /etc/openclash/china_ip_route.ipset
generate_nft_cidr_set \
  /tmp/china-ipv6.txt \
  china_ip6_route \
  ipv6_addr \
  /etc/openclash/china_ip6_route.ipset

# 服务商若提供定制 IPK，把文件放进 vendor/ 后重建镜像。
for PACKAGE in /tmp/vendor/*.ipk; do
  [ -f "${PACKAGE}" ] || continue
  [ "${PACKAGE}" = "/tmp/vendor/openclash.ipk" ] && continue
  echo "[build] Installing vendor package: ${PACKAGE}"
  opkg install --force-depends --force-overwrite "${PACKAGE}"
done

# 可选的服务商安装脚本。不要在脚本中硬编码订阅令牌或账号密码。
if [ -f /tmp/vendor/install.sh ]; then
  echo "[build] Running vendor/install.sh"
  chmod 0700 /tmp/vendor/install.sh
  /bin/sh /tmp/vendor/install.sh
fi

# Docker 已经配置 eth0；禁止 netifd 重新配置它，否则端口映射可能失效。
/etc/init.d/network disable >/dev/null 2>&1 || true
/etc/init.d/rpcd enable >/dev/null 2>&1 || true
/etc/init.d/uhttpd enable >/dev/null 2>&1 || true

# 保留开机服务钩子，但首次启动保持关闭。用户在 LuCI 启用后，容器重启可自动恢复。
uci -q set openclash.config.enable='0'
uci -q commit openclash
/etc/init.d/openclash enable >/dev/null 2>&1 || true

rm -f \
  /tmp/openclash.ipk \
  /tmp/oix-core.gz \
  /tmp/oix-core-version.txt \
  /tmp/oix-core-checksums.txt \
  /tmp/china-ipv4.txt \
  /tmp/china-ipv6.txt
rm -rf /var/opkg-lists/* /tmp/vendor

echo "[build] Image preparation complete"
