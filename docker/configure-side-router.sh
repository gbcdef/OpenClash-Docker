#!/bin/sh
set -eu

LAN_INTERFACE="${HOST_LAN_INTERFACE:-eth0}"
LAN_ADDRESS="${LUCI_BIND:-127.0.0.1}"
MIHOMO_DNS_PORT="${DNS_PORT:-7874}"

mkdir -p /etc/crontabs
touch /etc/crontabs/root

uci -q del_list "firewall.@zone[0].device=eth0" || true
uci -q del_list "firewall.@zone[0].device=${LAN_INTERFACE}" || true
uci -q add_list "firewall.@zone[0].device=${LAN_INTERFACE}"

uci -q delete firewall.side_router_forward || true
uci -q set firewall.side_router_forward='rule'
uci -q set firewall.side_router_forward.name='Allow-SideRouter-Forward'
uci -q set firewall.side_router_forward.src='lan'
uci -q delete firewall.side_router_forward.src_ip || true
uci -q set firewall.side_router_forward.dest='*'
uci -q set firewall.side_router_forward.proto='all'
uci -q set firewall.side_router_forward.family='ipv4'
uci -q set firewall.side_router_forward.target='ACCEPT'

uci -q delete firewall.docker_tun_input || true
uci -q set firewall.docker_tun_input='rule'
uci -q set firewall.docker_tun_input.name='Allow-Docker-TUN-Input'
uci -q set firewall.docker_tun_input.src='*'
uci -q set firewall.docker_tun_input.src_ip='172.16.0.0/12'
uci -q set firewall.docker_tun_input.mark='0x162/0xffffffff'
uci -q set firewall.docker_tun_input.proto='all'
uci -q set firewall.docker_tun_input.family='ipv4'
uci -q set firewall.docker_tun_input.target='ACCEPT'

uci -q delete firewall.docker_dns_hijack || true
uci -q set firewall.docker_dns_hijack='include'
uci -q set firewall.docker_dns_hijack.type='script'
uci -q set firewall.docker_dns_hijack.path='/usr/local/sbin/docker-tun-firewall'
uci -q set firewall.docker_dns_hijack.fw4_compatible='1'
uci -q commit firewall

uci -q set "dhcp.@dnsmasq[0].port=53"
uci -q set "dhcp.@dnsmasq[0].noresolv=1"
uci -q set "dhcp.@dnsmasq[0].bindinterfaces=1"
uci -q set "dhcp.@dnsmasq[0].localservice=0"
uci -q delete "dhcp.@dnsmasq[0].listen_address" || true
uci -q add_list "dhcp.@dnsmasq[0].listen_address=${LAN_ADDRESS}"
uci -q add_list "dhcp.@dnsmasq[0].listen_address=127.0.0.1"
uci -q delete "dhcp.@dnsmasq[0].server" || true
uci -q add_list "dhcp.@dnsmasq[0].server=127.0.0.1#${MIHOMO_DNS_PORT}"
uci -q set dhcp.lan.ignore='1'
uci -q set dhcp.wan.ignore='1'
uci -q commit dhcp

/etc/init.d/firewall enable >/dev/null 2>&1 || true
/etc/init.d/dnsmasq enable >/dev/null 2>&1 || true
