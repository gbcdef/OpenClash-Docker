ARG OPENWRT_IMAGE=openwrt/rootfs:x86_64-24.10.8
FROM ${OPENWRT_IMAGE}

ARG OPENCLASH_RELEASE=0.47.133

COPY docker/prepare-image.sh /usr/local/sbin/prepare-image
COPY vendor/ /tmp/vendor/

RUN chmod 0755 /usr/local/sbin/prepare-image \
    && /usr/local/sbin/prepare-image "${OPENCLASH_RELEASE}" \
    && mkdir -p /usr/local/share/openclash-defaults \
    && mv /etc/config /usr/local/share/openclash-defaults/config \
    && mv /etc/openclash /usr/local/share/openclash-defaults/openclash \
    && mkdir -p /etc/config /etc/openclash \
    && rm -f /usr/local/sbin/prepare-image

COPY docker/entrypoint.sh /usr/local/sbin/container-entrypoint
COPY docker/docker-tun-firewall.sh /usr/local/sbin/docker-tun-firewall
COPY docker/container-healthcheck.sh /usr/local/sbin/container-healthcheck
COPY docker/openclash-healthcheck.sh /usr/local/sbin/openclash-healthcheck
COPY hooks/ /usr/local/share/openclash-hooks/
RUN chmod 0755 \
    /usr/local/sbin/container-entrypoint \
    /usr/local/sbin/docker-tun-firewall \
    /usr/local/sbin/container-healthcheck \
    /usr/local/sbin/openclash-healthcheck \
    /usr/local/share/openclash-hooks/openclash_custom_overwrite.sh \
    /usr/local/share/openclash-hooks/openclash_custom_firewall_rules.sh \
    /usr/local/share/openclash-hooks/hooks.d/*.sh \
    /usr/local/share/openclash-hooks/test-hooks.sh

EXPOSE 80 7890 7891 7874/tcp 7874/udp 9090

ENTRYPOINT ["/usr/local/sbin/container-entrypoint"]
CMD ["/sbin/init"]
