#!/usr/bin/bash
# sixrelay-net - assert the IPv6 routed-subnet prerequisites the proxy needs.
#
# Idempotently (re)applies the sysctls, the `local <subnet>` route (so the host
# accepts/delivers the whole subnet to bound sockets) and keeps ndppd answering
# NDP for the subnet. Runs once, or every SIXRELAY_NET_INTERVAL seconds with
# --loop so it survives network-manager / networkd reconfigurations & flushes.
#
# Config comes from the environment (systemd EnvironmentFile). When run by hand
# without those set, the two required keys are read straight from the env file.
set -u

ENVFILE="${SIXRELAY_ENV:-/etc/sixrelay/sixrelay.env}"
getkey() { sed -n "s/^$1=//p" "$ENVFILE" 2>/dev/null | tail -n1; }

IFACE="${SIXRELAY_IFACE:-$(getkey SIXRELAY_IFACE)}"
SUBNET="${SIXRELAY_SUBNET:-$(getkey SIXRELAY_SUBNET)}"
INTERVAL="${SIXRELAY_NET_INTERVAL:-10}"

if [ -z "$IFACE" ] || [ -z "$SUBNET" ]; then
  echo "sixrelay-net: SIXRELAY_IFACE / SIXRELAY_SUBNET not resolvable" >&2
  exit 2
fi

assert_once() {
  sysctl -qw net.ipv6.ip_nonlocal_bind=1                     2>/dev/null
  sysctl -qw net.ipv6.conf.all.forwarding=1                  2>/dev/null
  sysctl -qw net.ipv6.conf.default.forwarding=1              2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.forwarding=1"           2>/dev/null
  sysctl -qw net.ipv6.conf.all.proxy_ndp=1                   2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.proxy_ndp=1"            2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.accept_dad=0"           2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.dad_transmits=0"        2>/dev/null

  # Make the whole subnet locally deliverable (routed subnets need it; harmless
  # for on-link subnets). ndppd answers NDP for the subnet on the interface.
  ip -6 route replace local "$SUBNET" dev "$IFACE"           2>/dev/null

  systemctl is-active --quiet ndppd 2>/dev/null || \
    systemctl restart ndppd 2>/dev/null || \
    service ndppd restart 2>/dev/null || true
}

if [ "${1:-}" = "--loop" ]; then
  while true; do
    assert_once
    sleep "$INTERVAL"
  done
else
  assert_once
fi
