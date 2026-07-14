#!/usr/bin/env bash
#
# Unlimited Rotating IPv6 Proxy Server - one-shot installer.
# Turns a fresh Ubuntu 22.04/24.04 VPS that has a routed (or on-link) IPv6 /64
# into a session-based rotating IPv6 SOCKS5 proxy: every new connection egresses
# from a random address in the subnet, held for the TCP session; concurrent
# connections get distinct addresses. No pre-assigned addresses.
#
# Usage:
#   sudo bash install.sh [options]
#   sudo bash install.sh --uninstall
#
# Options (all optional; sensible values are auto-detected):
#   --subnet CIDR     IPv6 subnet to rotate within (e.g. 2a06:9801:6::/64)
#   --iface NAME      network interface (default: interface of the IPv6 default route)
#   --listen ADDR     address to listen on (default: primary public IPv4, else 0.0.0.0)
#   --port N          listen port (default: 1080)
#   --user NAME       SOCKS5 username (default: kept from existing config, else random)
#   --pass SECRET     SOCKS5 password (default: kept from existing config, else random)
#   --reserved LIST   extra comma-separated addresses (or 0x-prefixed host parts) to never hand out
#   --interval N      seconds between network-prerequisite re-assertions (default: 10)
#   --no-test         skip the post-install self-test
#   --yes             non-interactive; accept detected values
#   --uninstall       remove everything this installer created
#   -h, --help        show this help
set -euo pipefail

PREFIX=/opt/sixrelay
ETCDIR=/etc/sixrelay
ENVFILE="$ETCDIR/sixrelay.env"
SYSCTL_FILE=/etc/sysctl.d/99-sixrelay.conf
NDPPD_CONF=/etc/ndppd.conf
NDPPD_BAK=/etc/ndppd.conf.sixrelay-orig
UNIT_RELAY=/etc/systemd/system/sixrelay.service
UNIT_NET=/etc/systemd/system/sixrelay-net.service
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Wait up to 5 min for the dpkg lock: fresh Ubuntu VPSes routinely run
# unattended-upgrades / apt-daily right after boot, which would otherwise make
# these installs fail spuriously.
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=300"

PORT=""; LISTEN=""; SUBNET=""; PLEN=""; IFACE=""; PUSER=""; PPASS=""; RESERVED_EXTRA=""
INTERVAL=""; ASSUME_YES=0; ACTION=install; RUN_TEST=1; SUBNET_FORCED=0

if [ -t 1 ]; then
  c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[1m'; c_0=$'\033[0m'
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_0=""
fi
log()  { echo -e "${c_g}==>${c_0} $*"; }
warn() { echo -e "${c_y}[warn]${c_0} $*" >&2; }
die()  { echo -e "${c_r}[error]${c_0} $*" >&2; exit 1; }
usage(){ sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }
randstr(){ local n="${1:-16}"; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true; }
valid_cred(){ case "$1" in ""|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --subnet)   SUBNET="$2"; SUBNET_FORCED=1; shift 2;;
    --iface)    IFACE="$2"; shift 2;;
    --listen)   LISTEN="$2"; shift 2;;
    --port)     PORT="$2"; shift 2;;
    --user)     PUSER="$2"; shift 2;;
    --pass)     PPASS="$2"; shift 2;;
    --reserved) RESERVED_EXTRA="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --no-test)  RUN_TEST=0; shift;;
    --yes|-y)   ASSUME_YES=1; shift;;
    --uninstall) ACTION=uninstall; shift;;
    -h|--help)  usage;;
    *) die "unknown option: $1 (see --help)";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)."

# ---------- uninstall --------------------------------------------------------
if [ "$ACTION" = uninstall ]; then
  log "Uninstalling..."
  U_IFACE=""; U_SUBNET=""
  if [ -r "$ENVFILE" ]; then
    U_IFACE=$(sed -n 's/^SIXRELAY_IFACE=//p' "$ENVFILE" | tail -1)
    U_SUBNET=$(sed -n 's/^SIXRELAY_SUBNET=//p' "$ENVFILE" | tail -1)
  fi
  systemctl disable --now sixrelay.service sixrelay-net.service 2>/dev/null || true
  rm -f "$UNIT_RELAY" "$UNIT_NET"
  systemctl daemon-reload 2>/dev/null || true
  if [ -n "$U_SUBNET" ] && [ -n "$U_IFACE" ]; then
    ip -6 route del local "$U_SUBNET" dev "$U_IFACE" 2>/dev/null || true
  fi
  if [ -f "$NDPPD_BAK" ]; then
    mv -f "$NDPPD_BAK" "$NDPPD_CONF"; systemctl restart ndppd 2>/dev/null || true
    log "restored original $NDPPD_CONF"
  else
    systemctl disable --now ndppd 2>/dev/null || true
    rm -f "$NDPPD_CONF"    # was created by this installer
  fi
  rm -rf "$PREFIX" "$ETCDIR" "$SYSCTL_FILE"
  log "Done. (ndppd package left installed; runtime sysctls clear on reboot.)"
  exit 0
fi

# ---------- source files present? --------------------------------------------
for f in sixrelay.py sixrelay-net.sh test/selftest.py; do
  [ -f "$SCRIPT_DIR/$f" ] || die "missing $SCRIPT_DIR/$f -- run this from a full checkout of the repo."
done

# ---------- python3 is needed for detection; ensure it first -----------------
if ! command -v python3 >/dev/null 2>&1; then
  log "Installing python3 (required for setup)..."
  $APT update -y >/dev/null 2>&1 || warn "apt-get update reported problems; continuing."
  $APT install -y python3 >/dev/null 2>&1 || die "failed to install python3."
fi

# ---------- detection helpers ------------------------------------------------
det_iface() {
  local i
  i=$(ip -6 route show default 2>/dev/null | awk '{for(x=1;x<=NF;x++) if($x=="dev"){print $(x+1); exit}}' || true)
  [ -n "$i" ] || i=$(ip -o -6 addr show scope global 2>/dev/null | awk '$2!="lo"{print $2; exit}' || true)
  printf '%s' "$i"
}
det_gw()   { ip -6 route show default 2>/dev/null | awk '{for(x=1;x<=NF;x++) if($x=="via"){print $(x+1); exit}}' || true; }
det_prim6() {
  local a
  a=$(ip -6 addr show dev "$1" scope global 2>/dev/null | awk '/inet6/&&!/temporary/&&!/deprecated/{print $2; exit}' || true)
  [ -n "$a" ] || a=$(ip -6 addr show dev "$1" scope global 2>/dev/null | awk '/inet6/{print $2; exit}' || true)
  printf '%s' "$a"
}
det_ipv4() { ip -4 addr show dev "$1" scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1 || true; }
det_subnet_from_routes() {
  ip -6 route show dev "$1" 2>/dev/null | awk '
    { p=$1 }
    p=="default"   { next }
    p ~ /^fe80:/   { next }
    p ~ /\/128$/   { next }
    p ~ /\//       { print p; exit }' || true
}
normalize_subnet() {  # arg: addr/prefix or net/prefix -> sets globals SUBNET, PLEN
  local out
  out=$(python3 - "$1" <<'PY' || true
import sys, ipaddress
try:
    n = ipaddress.IPv6Network(sys.argv[1], strict=False)
    print(n.with_prefixlen, n.prefixlen)
except Exception:
    pass
PY
)
  SUBNET=""; PLEN=""
  read -r SUBNET PLEN <<<"$out" || true
}

# ---------- reuse previous config on re-run (unless overridden on CLI) --------
envget(){ [ -r "$ENVFILE" ] && sed -n "s/^$1=//p" "$ENVFILE" | tail -1 || true; }
if [ -r "$ENVFILE" ]; then
  [ -n "$IFACE" ]  || IFACE="$(envget SIXRELAY_IFACE)"
  [ -n "$LISTEN" ] || LISTEN="$(envget SIXRELAY_LISTEN_HOST)"
  [ -n "$PORT" ]   || PORT="$(envget SIXRELAY_LISTEN_PORT)"
  [ -n "$PUSER" ]  || PUSER="$(envget SIXRELAY_USER)"
  [ -n "$PPASS" ]  || PPASS="$(envget SIXRELAY_PASS)"
  [ -n "$INTERVAL" ] || INTERVAL="$(envget SIXRELAY_NET_INTERVAL)"
  if [ "$SUBNET_FORCED" -eq 0 ] && [ -z "$SUBNET" ]; then
    SUBNET="$(envget SIXRELAY_SUBNET)"; [ -n "$SUBNET" ] && SUBNET_FORCED=1
  fi
fi
[ -n "$PORT" ]     || PORT=1080
[ -n "$INTERVAL" ] || INTERVAL=10

# ---------- detect / validate ------------------------------------------------
log "Detecting network configuration..."
[ -n "$IFACE" ] || IFACE="$(det_iface)"
[ -n "$IFACE" ] || die "could not detect a network interface; pass --iface."
GW="$(det_gw)"
PRIM6="$(det_prim6 "$IFACE")"
[ -n "$PRIM6" ] || die "interface $IFACE has no global IPv6 address; this host needs a routed/on-link IPv6 /64."
PRIM_ADDR="${PRIM6%%/*}"
[ -n "$LISTEN" ] || { LISTEN="$(det_ipv4 "$IFACE")"; [ -n "$LISTEN" ] || LISTEN="0.0.0.0"; }

if [ "$SUBNET_FORCED" -eq 1 ]; then
  normalize_subnet "$SUBNET"
else
  normalize_subnet "$PRIM6"
  # primary is a /128 (or otherwise too small): look for a routed prefix instead
  if [ -z "$SUBNET" ] || ! [ "${PLEN:-999}" -le 120 ] 2>/dev/null; then
    cand="$(det_subnet_from_routes "$IFACE")"
    [ -n "$cand" ] && normalize_subnet "$cand"
  fi
fi
if [ -z "$SUBNET" ] || ! [ "${PLEN:-999}" -le 120 ] 2>/dev/null; then
  die "could not determine a rotatable IPv6 subnet (need prefix <= /120).
  primary address = ${PRIM6:-none}
  If your provider assigns a /128 and routes a separate /64 to this host, pass it:
    sudo bash install.sh --subnet <your::/64>"
fi

# credentials: reused from env above when present; otherwise generate random
[ -n "$PUSER" ] || PUSER="u$(randstr 7)"
[ -n "$PPASS" ] || PPASS="$(randstr 20)"
valid_cred "$PUSER" || die "username must be non-empty and use only [A-Za-z0-9._-]."
valid_cred "$PPASS" || die "password must use only [A-Za-z0-9._-] (no spaces/quotes/backslashes)."

RESERVED="$PRIM_ADDR"
[ -n "$GW" ] && RESERVED="$RESERVED,$GW"
[ -n "$RESERVED_EXTRA" ] && RESERVED="$RESERVED,$RESERVED_EXTRA"
TEST_HOST="$LISTEN"; [ "$LISTEN" = "0.0.0.0" ] && TEST_HOST="127.0.0.1"

cat <<EOF

  ${c_b}Detected configuration${c_0}
    interface : $IFACE
    subnet    : $SUBNET       (rotating pool)
    gateway   : ${GW:-<none>}
    primary   : $PRIM_ADDR   (reserved, never handed out)
    listen    : $LISTEN:$PORT (SOCKS5)
    username  : $PUSER
    password  : $PPASS
EOF
if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "non-interactive input; re-run with --yes to accept the detected values."
  read -r -p "  Proceed with install? [Y/n] " ans || ans="N"
  case "${ans:-Y}" in [Nn]*) die "aborted.";; esac
fi

# ---------- OS + packages ----------------------------------------------------
. /etc/os-release 2>/dev/null || true
case "${VERSION_ID:-}" in
  22.04|24.04) : ;;
  *) warn "untested on '${PRETTY_NAME:-unknown}' (built for Ubuntu 22.04/24.04); continuing." ;;
esac

log "Installing packages (ndppd)..."
$APT update -y >/dev/null 2>&1 || warn "apt-get update reported problems; continuing."
NDPPD_OK=1
$APT install -y ndppd >/dev/null 2>&1 || { NDPPD_OK=0; warn "ndppd not installable; on-link subnets need it. Routed subnets still work."; }

# ---------- lay down files ---------------------------------------------------
log "Installing files..."
install -d -m 0755 "$PREFIX" "$PREFIX/test" "$ETCDIR"
install -m 0644 "$SCRIPT_DIR/sixrelay.py"      "$PREFIX/sixrelay.py"
install -m 0755 "$SCRIPT_DIR/sixrelay-net.sh"  "$PREFIX/sixrelay-net.sh"
install -m 0644 "$SCRIPT_DIR/test/selftest.py" "$PREFIX/test/selftest.py"

umask 077
cat > "$ENVFILE" <<EOF
SIXRELAY_IFACE=$IFACE
SIXRELAY_SUBNET=$SUBNET
SIXRELAY_LISTEN_HOST=$LISTEN
SIXRELAY_LISTEN_PORT=$PORT
SIXRELAY_USER=$PUSER
SIXRELAY_PASS=$PPASS
SIXRELAY_RESERVED=$RESERVED
SIXRELAY_NET_INTERVAL=$INTERVAL
EOF
chmod 0640 "$ENVFILE"
umask 022

cat > "$SYSCTL_FILE" <<EOF
# Managed by Unlimited Rotating IPv6 Proxy Server
net.ipv6.ip_nonlocal_bind=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.$IFACE.proxy_ndp=1
net.ipv6.conf.$IFACE.accept_dad=0
net.ipv6.conf.$IFACE.dad_transmits=0
EOF
sysctl --system >/dev/null 2>&1 || true

if [ "$NDPPD_OK" -eq 1 ]; then
  [ -f "$NDPPD_CONF" ] && [ ! -f "$NDPPD_BAK" ] && cp -a "$NDPPD_CONF" "$NDPPD_BAK"
  cat > "$NDPPD_CONF" <<EOF
route-ttl 30000
proxy $IFACE {
    router no
    timeout 500
    ttl 30000
    rule $SUBNET {
        static
    }
}
EOF
fi

cat > "$UNIT_NET" <<'EOF'
[Unit]
Description=sixrelay IPv6 routed-subnet prerequisites
After=network-online.target
Wants=network-online.target
Before=sixrelay.service

[Service]
Type=simple
EnvironmentFile=/etc/sixrelay/sixrelay.env
ExecStart=/usr/bin/bash /opt/sixrelay/sixrelay-net.sh --loop
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > "$UNIT_RELAY" <<'EOF'
[Unit]
Description=sixrelay session-based rotating IPv6 SOCKS5 proxy
After=network-online.target sixrelay-net.service
Wants=network-online.target sixrelay-net.service

[Service]
Type=simple
EnvironmentFile=/etc/sixrelay/sixrelay.env
ExecStart=/usr/bin/python3 /opt/sixrelay/sixrelay.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

# ---------- start services ---------------------------------------------------
log "Starting services..."
systemctl daemon-reload
if [ "$NDPPD_OK" -eq 1 ]; then
  systemctl enable ndppd >/dev/null 2>&1 || true
  systemctl restart ndppd >/dev/null 2>&1 || true
fi
systemctl enable --now sixrelay-net.service >/dev/null 2>&1 || die "failed to start sixrelay-net.service (journalctl -u sixrelay-net)"
systemctl enable --now sixrelay.service     >/dev/null 2>&1 || die "failed to start sixrelay.service (journalctl -u sixrelay)"

# ---------- self-test --------------------------------------------------------
TEST_RC=0
if [ "$RUN_TEST" -eq 1 ]; then
  log "Running self-test..."
  set +e
  RELAY_HOST="$TEST_HOST" RELAY_PORT="$PORT" \
  SIXRELAY_USER="$PUSER" SIXRELAY_PASS="$PPASS" SIXRELAY_SUBNET="$SUBNET" \
  ECHO_ADDR="$PRIM_ADDR" ECHO_PORT=45678 \
  python3 "$PREFIX/test/selftest.py"
  TEST_RC=$?
  set -e
fi

echo
if [ "$TEST_RC" -eq 0 ]; then
  echo -e "${c_g}${c_b}Installation complete.${c_0}"
else
  echo -e "${c_y}${c_b}Installed, but the self-test did not fully pass (rc=$TEST_RC).${c_0}"
  echo    "Check:  journalctl -u sixrelay -n 50 --no-pager"
  [ "$NDPPD_OK" -eq 0 ] && echo "Note: ndppd is not installed; on-link subnets require it."
fi
cat <<EOF

  ${c_b}Endpoint${c_0}  socks5://$PUSER:$PPASS@$LISTEN:$PORT
  ${c_b}Rotation${c_0}  random IPv6 from $SUBNET per connection, stable for the TCP session,
            distinct per concurrent connection.
  ${c_b}Manage${c_0}    systemctl status|restart sixrelay
            journalctl -u sixrelay -f
  ${c_b}Config${c_0}    $ENVFILE   (edit then: systemctl restart sixrelay)
  ${c_b}Remove${c_0}    sudo bash install.sh --uninstall

  Test it:  curl -x socks5h://$PUSER:$PPASS@$LISTEN:$PORT -6 https://ifconfig.co
EOF
exit "$TEST_RC"
