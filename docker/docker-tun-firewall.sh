#!/bin/sh
set -eu

CHAIN='inet fw4 nat_output'
LAN_ADDRESS="${LUCI_BIND:-127.0.0.1}"

nft list chain ${CHAIN} >/dev/null 2>&1 || exit 0

if ! nft list chain ${CHAIN} | grep -Fq 'OpenClash Docker DNS Hijack UDP'; then
  nft "insert rule inet fw4 nat_output meta skgid != 65534 ip daddr != ${LAN_ADDRESS} udp dport 53 counter redirect to :53 comment \"OpenClash Docker DNS Hijack UDP\""
fi

if ! nft list chain ${CHAIN} | grep -Fq 'OpenClash Docker DNS Hijack TCP'; then
  nft "insert rule inet fw4 nat_output meta skgid != 65534 ip daddr != ${LAN_ADDRESS} tcp dport 53 counter redirect to :53 comment \"OpenClash Docker DNS Hijack TCP\""
fi
