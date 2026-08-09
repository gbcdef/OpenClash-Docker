#!/bin/sh
set -eu

OPENCLASH_RELEASE="${1:-0.47.133}"
OPENCLASH_IPK_SHA256="${2:-}"

if [ -z "${OPENCLASH_IPK_SHA256}" ]; then
  echo "[build] OPENCLASH_IPK_SHA256 is required" >&2
  exit 1
fi

OPENCLASH_VERSION="${OPENCLASH_RELEASE#v}"
OPENCLASH_ASSET="luci-app-openclash_${OPENCLASH_VERSION}_all.ipk"

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

if [ -f /tmp/vendor/openclash.ipk ]; then
  echo "[build] Using vendor/openclash.ipk"
  cp /tmp/vendor/openclash.ipk /tmp/openclash.ipk
else
  OPENCLASH_URL="https://github.com/vernesong/OpenClash/releases/download/v${OPENCLASH_VERSION}/${OPENCLASH_ASSET}"
  echo "[build] Downloading ${OPENCLASH_URL}"
  curl -fL --retry 3 --connect-timeout 20 "${OPENCLASH_URL}" -o /tmp/openclash.ipk
fi

ACTUAL_IPK_SHA256="$(sha256sum /tmp/openclash.ipk | awk '{print $1}')"
if [ "${ACTUAL_IPK_SHA256}" != "${OPENCLASH_IPK_SHA256}" ]; then
  echo "[build] OpenClash IPK checksum mismatch" >&2
  echo "[build] expected: ${OPENCLASH_IPK_SHA256}" >&2
  echo "[build] actual:   ${ACTUAL_IPK_SHA256}" >&2
  exit 1
fi
echo "[build] Verified OpenClash IPK SHA-256: ${ACTUAL_IPK_SHA256}"

opkg install /tmp/openclash.ipk

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

rm -f /tmp/openclash.ipk
rm -rf /var/opkg-lists/* /tmp/vendor

echo "[build] Image preparation complete"
