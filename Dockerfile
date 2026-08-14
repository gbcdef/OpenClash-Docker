ARG OPENWRT_IMAGE=openwrt/rootfs:x86_64-24.10.8
FROM ${OPENWRT_IMAGE}

ARG OPENCLASH_RELEASE=latest
ARG OIX_CORE_RELEASE=Pre-Alpha

COPY docker/prepare-image.sh /usr/local/sbin/prepare-image
COPY docker/openclash-oix-sync.sh /usr/local/sbin/openclash-oix-sync
COPY docker/test-oix-sync.sh /usr/local/share/openclash-tests/test-oix-sync.sh
COPY docker/patches/ /tmp/openclash-docker-patches/
COPY vendor/ /tmp/vendor/

RUN chmod 0755 \
      /usr/local/sbin/prepare-image \
      /usr/local/sbin/openclash-oix-sync \
      /usr/local/share/openclash-tests/test-oix-sync.sh \
    && /usr/local/sbin/prepare-image "${OPENCLASH_RELEASE}" "${OIX_CORE_RELEASE}" \
    && mkdir -p /usr/local/share/openclash-defaults \
    && mv /etc/config /usr/local/share/openclash-defaults/config \
    && mv /etc/openclash /usr/local/share/openclash-defaults/openclash \
    && mkdir -p /etc/config /etc/openclash \
    && rm -f /usr/local/sbin/prepare-image

COPY docker/entrypoint.sh /usr/local/sbin/container-entrypoint
COPY docker/docker-tun-firewall.sh /usr/local/sbin/docker-tun-firewall
COPY docker/docker-luci-firewall.sh /usr/local/sbin/docker-luci-firewall
COPY docker/container-healthcheck.sh /usr/local/sbin/container-healthcheck
COPY docker/openclash-healthcheck.sh /usr/local/sbin/openclash-healthcheck
COPY docker/test-docker-luci-firewall.sh /usr/local/share/openclash-tests/test-docker-luci-firewall.sh
COPY hooks/ /usr/local/share/openclash-hooks/
RUN chmod 0755 \
    /usr/local/sbin/container-entrypoint \
    /usr/local/sbin/docker-tun-firewall \
    /usr/local/sbin/docker-luci-firewall \
    /usr/local/sbin/container-healthcheck \
    /usr/local/sbin/openclash-healthcheck \
    /usr/local/share/openclash-tests/test-docker-luci-firewall.sh \
    /usr/local/share/openclash-hooks/openclash_custom_overwrite.sh \
    /usr/local/share/openclash-hooks/openclash_custom_firewall_rules.sh \
    /usr/local/share/openclash-hooks/hooks.d/*.sh \
    /usr/local/share/openclash-hooks/test-hooks.sh

EXPOSE 80 7890 7891 7874/tcp 7874/udp 9090

ENTRYPOINT ["/usr/local/sbin/container-entrypoint"]
CMD ["/sbin/init"]
