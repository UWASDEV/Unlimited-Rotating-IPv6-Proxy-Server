#!/usr/bin/bash
# sixrelay-net - assert the IPv6 network prerequisites the proxy needs.
#
# Behaviour depends on SIXRELAY_MODE:
#   routed  - the provider routes the whole /64 here. Apply the sysctls, the
#             `local <subnet>` route (so the host delivers the whole subnet to
#             bound sockets) and keep ndppd answering NDP for the subnet.
#   address - the /64 is on-link (shared L2 segment). The relay assigns each
#             source address to the interface itself, so here we DELIBERATELY do
#             NOT add a `local <subnet>` route and do NOT run an ndppd static
#             rule for the subnet: on a shared segment either one would blackhole
#             or hijack traffic for addresses this host does not own. Only the
#             DAD-suppressing sysctls are asserted (they make `ip addr add` on
#             the interface take effect immediately).
#
# Idempotent. Runs once, or every SIXRELAY_NET_INTERVAL seconds with --loop so
# it survives NetworkManager / networkd reconfigurations and flushes.
#
# Config comes from the environment (systemd EnvironmentFile). When run by hand
# without those set, the needed keys are read straight from the env file.
set -u

ENVFILE="${SIXRELAY_ENV:-/etc/sixrelay/sixrelay.env}"
getkey() { sed -n "s/^$1=//p" "$ENVFILE" 2>/dev/null | tail -n1; }

IFACE="${SIXRELAY_IFACE:-$(getkey SIXRELAY_IFACE)}"
SUBNET="${SIXRELAY_SUBNET:-$(getkey SIXRELAY_SUBNET)}"
MODE="${SIXRELAY_MODE:-$(getkey SIXRELAY_MODE)}"
INTERVAL="${SIXRELAY_NET_INTERVAL:-10}"
[ -n "$MODE" ] || MODE=routed

if [ -z "$IFACE" ] || [ -z "$SUBNET" ]; then
  echo "sixrelay-net: SIXRELAY_IFACE / SIXRELAY_SUBNET not resolvable" >&2
  exit 2
fi

assert_once() {
  # DAD suppression is useful in both modes (instant, warning-free assignment).
  sysctl -qw "net.ipv6.conf.${IFACE}.accept_dad=0"           2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.dad_transmits=0"        2>/dev/null

  if [ "$MODE" = address ]; then
    return 0
  fi

  # ---- routed mode only -----------------------------------------------------
  sysctl -qw net.ipv6.ip_nonlocal_bind=1                     2>/dev/null
  sysctl -qw net.ipv6.conf.all.forwarding=1                  2>/dev/null
  sysctl -qw net.ipv6.conf.default.forwarding=1              2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.forwarding=1"           2>/dev/null
  sysctl -qw net.ipv6.conf.all.proxy_ndp=1                   2>/dev/null
  sysctl -qw "net.ipv6.conf.${IFACE}.proxy_ndp=1"            2>/dev/null

  # Make the whole subnet locally deliverable (routed subnets need this for the
  # return path). ndppd answers NDP for the subnet on the interface.
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
