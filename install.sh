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
#   --mode MODE       egress mode: routed | address (default: auto-detected)
#                       routed  = provider routes the whole /64 here; sources are
#                                 bound without being assigned to the interface.
#                       address = on-link /64; each source is assigned to the
#                                 interface for the life of its connection.
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
MODE=""; MODE_FORCED=0

if [ -t 1 ]; then
  c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[1m'; c_0=$'\033[0m'
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_0=""
fi
log()  { echo -e "${c_g}==>${c_0} $*"; }
warn() { echo -e "${c_y}[warn]${c_0} $*" >&2; }
die()  { echo -e "${c_r}[error]${c_0} $*" >&2; exit 1; }
usage(){ awk 'NR>=2 && /^#/{sub(/^# ?/,""); print; next} NR>=2{exit}' "${BASH_SOURCE[0]}"; exit 0; }
randstr(){ local n="${1:-16}"; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true; }
valid_cred(){ case "$1" in ""|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --subnet)   SUBNET="$2"; SUBNET_FORCED=1; shift 2;;
    --mode)     MODE="$(printf '%s' "$2" | tr 'A-Z' 'a-z')"; MODE_FORCED=1; shift 2;;
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

if [ "$MODE_FORCED" -eq 1 ]; then
  case "$MODE" in routed|address) : ;; *) die "--mode must be 'routed' or 'address'." ;; esac
fi

# ---------- uninstall --------------------------------------------------------
if [ "$ACTION" = uninstall ]; then
  log "Uninstalling..."
  U_IFACE=""; U_SUBNET=""; U_RESERVED=""
  if [ -r "$ENVFILE" ]; then
    U_IFACE=$(sed -n 's/^SIXRELAY_IFACE=//p' "$ENVFILE" | tail -1)
    U_SUBNET=$(sed -n 's/^SIXRELAY_SUBNET=//p' "$ENVFILE" | tail -1)
    U_RESERVED=$(sed -n 's/^SIXRELAY_RESERVED=//p' "$ENVFILE" | tail -1)
  fi
  systemctl disable --now sixrelay.service sixrelay-net.service 2>/dev/null || true
  rm -f "$UNIT_RELAY" "$UNIT_NET"
  systemctl daemon-reload 2>/dev/null || true
  if [ -n "$U_SUBNET" ] && [ -n "$U_IFACE" ]; then
    ip -6 route del local "$U_SUBNET" dev "$U_IFACE" 2>/dev/null || true
    # address mode may have left pool addresses assigned to the interface (e.g.
    # if the relay was killed mid-connection); remove any in-subnet global
    # address that is not reserved (primary/gateway stay untouched). Require a
    # non-empty reserved list: a real install always records at least the primary
    # there, so if it is missing the env is corrupt and we must not risk deleting
    # the primary -- skip the flush (any strays clear on reboot).
    if [ -n "$U_RESERVED" ] && command -v python3 >/dev/null 2>&1; then
      python3 - "$U_IFACE" "$U_SUBNET" "$U_RESERVED" <<'PY' 2>/dev/null || true
import ipaddress, re, subprocess, sys
iface, subnet, reserved = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    net = ipaddress.IPv6Network(subnet, strict=False)
except ValueError:
    sys.exit(0)
hostmask = (1 << (128 - net.prefixlen)) - 1 if net.prefixlen < 128 else 0
keep = {0, 1}
for tok in reserved.split(","):
    tok = tok.strip()
    if not tok:
        continue
    try:
        keep.add(int(tok, 0) & hostmask); continue
    except ValueError:
        pass
    try:
        keep.add(int(ipaddress.IPv6Address(tok)) & hostmask)
    except ValueError:
        pass
try:
    out = subprocess.run(["ip", "-6", "addr", "show", "dev", iface, "scope", "global"],
                         capture_output=True, text=True).stdout
except OSError:
    sys.exit(0)
for m in re.finditer(r"inet6 ([0-9A-Fa-f:]+)/(\d+)", out):
    try:
        a = ipaddress.IPv6Address(m.group(1))
    except ValueError:
        continue
    if a in net and (int(a) & hostmask) not in keep:
        subprocess.run(["ip", "-6", "addr", "del", f"{a}/{net.prefixlen}", "dev", iface],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
    fi
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
  # keep the previously chosen mode on a re-run (avoids re-probing / flips)
  if [ "$MODE_FORCED" -eq 0 ] && [ -z "$MODE" ]; then
    MODE="$(envget SIXRELAY_MODE)"; [ -n "$MODE" ] && MODE_FORCED=1
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

if [ "$MODE_FORCED" -eq 1 ]; then MODE_DISP="$MODE"; else MODE_DISP="auto-detect"; fi

cat <<EOF

  ${c_b}Detected configuration${c_0}
    interface : $IFACE
    subnet    : $SUBNET       (rotating pool)
    gateway   : ${GW:-<none>}
    primary   : $PRIM_ADDR   (reserved, never handed out)
    listen    : $LISTEN:$PORT (SOCKS5)
    mode      : $MODE_DISP   (routed=bind unassigned / address=assign per conn)
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
$APT install -y ndppd >/dev/null 2>&1 || { NDPPD_OK=0; warn "ndppd not installable; needed only for routed on-link subnets. Continuing."; }

# ---------- egress-mode helpers ----------------------------------------------
write_ndppd_conf() {
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
}
restore_ndppd_conf() {   # undo write_ndppd_conf (restore original, else remove ours)
  systemctl stop ndppd 2>/dev/null || true
  if [ -f "$NDPPD_BAK" ]; then mv -f "$NDPPD_BAK" "$NDPPD_CONF"; else rm -f "$NDPPD_CONF"; fi
}
apply_routed_live() {    # live-apply the routed prerequisites needed to PROBE.
  # NB: forwarding is intentionally NOT set here. It is only needed by the
  # persisted routed config, and setting it live would flip accept_ra to 0 on a
  # SLAAC-configured box (which is exactly the on-link/address case we may fall
  # back to), risking loss of its RA default route. The relay only originates
  # connections, so egress works without forwarding.
  sysctl -qw net.ipv6.ip_nonlocal_bind=1                2>/dev/null || true
  sysctl -qw net.ipv6.conf.all.proxy_ndp=1              2>/dev/null || true
  sysctl -qw "net.ipv6.conf.${IFACE}.proxy_ndp=1"       2>/dev/null || true
  sysctl -qw "net.ipv6.conf.${IFACE}.accept_dad=0"      2>/dev/null || true
  sysctl -qw "net.ipv6.conf.${IFACE}.dad_transmits=0"   2>/dev/null || true
  ip -6 route replace local "$SUBNET" dev "$IFACE"      2>/dev/null || true
  if [ "$NDPPD_OK" -eq 1 ]; then write_ndppd_conf; systemctl restart ndppd 2>/dev/null || true; fi
}
remove_routed_live() {   # withdraw the bits that would hijack a shared on-link /64
  ip -6 route del local "$SUBNET" dev "$IFACE" 2>/dev/null || true
  restore_ndppd_conf
}
# probe_egress MODE [TIMEOUT] -> exit 0 if a random in-subnet source can reach
# the internet. In address mode the source is assigned to the interface for the
# probe; in routed mode it relies on the routed prerequisites already being live.
probe_egress() {
  python3 - "$1" "$IFACE" "$SUBNET" "$PLEN" "${2:-5}" <<'PY'
import ipaddress, secrets, socket, subprocess, sys
mode, iface, subnet, plen = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
timeout = float(sys.argv[5])
net = ipaddress.IPv6Network(subnet, strict=False)
hostbits = 128 - net.prefixlen
hostmask = (1 << hostbits) - 1 if hostbits else 0
h = (secrets.randbits(hostbits) if hostbits else 0) & hostmask
if hostbits > 16:
    h |= 0x10000           # roomy subnets: stay well clear of low reserved hosts
    h &= hostmask
if h in (0, 1):            # never probe the anycast / conventional-gateway hosts
    h = 2 & hostmask
src = str(ipaddress.IPv6Address(int(net.network_address) | h))
TARGETS = [("2001:4860:4860::8888", 53), ("2606:4700:4700::1111", 53)]
FREEBIND = getattr(socket, "IPV6_FREEBIND", 78)
assigned = False
try:
    if mode == "address":
        r = subprocess.run(["ip", "-6", "addr", "add", f"{src}/{plen}", "dev", iface, "nodad"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assigned = r.returncode in (0, 2)
        if not assigned:
            sys.exit(1)
    for host, port in TARGETS:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        try:
            try: s.setsockopt(socket.IPPROTO_IPV6, FREEBIND, 1)
            except OSError: pass
            s.bind((src, 0))
            s.settimeout(timeout)
            s.connect((host, port))
            sys.exit(0)
        except OSError:
            continue
        finally:
            s.close()
    sys.exit(1)
finally:
    if assigned:
        subprocess.run(["ip", "-6", "addr", "del", f"{src}/{plen}", "dev", iface],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
}

# ---------- determine egress mode --------------------------------------------
if [ "$MODE_FORCED" -eq 1 ]; then
  log "Egress mode: $MODE (specified)."
else
  log "Detecting egress mode (routed vs address)..."
  # Apply routed prerequisites, let ndppd settle, then a single tightly-bounded
  # probe. The routed setup (local route + ndppd static rule) is briefly live on
  # the segment during this window; on a shared on-link /64 (where the routed
  # probe fails anyway) it is withdrawn immediately below, keeping exposure short.
  apply_routed_live
  sleep 2
  if probe_egress routed 4; then
    MODE=routed
    log "  -> routed: an unassigned in-subnet source reaches the internet."
  else
    remove_routed_live
    if probe_egress address; then
      MODE=address
      log "  -> address: only interface-assigned sources egress (on-link /64)."
    else
      MODE=address
      warn "could not confirm IPv6 egress in either mode; defaulting to address."
      warn "the self-test below will show whether egress works (verify provider IPv6 routing if it fails)."
    fi
  fi
fi

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
SIXRELAY_MODE=$MODE
SIXRELAY_LISTEN_HOST=$LISTEN
SIXRELAY_LISTEN_PORT=$PORT
SIXRELAY_USER=$PUSER
SIXRELAY_PASS=$PPASS
SIXRELAY_RESERVED=$RESERVED
SIXRELAY_NET_INTERVAL=$INTERVAL
EOF
chmod 0640 "$ENVFILE"
umask 022

if [ "$MODE" = routed ]; then
  cat > "$SYSCTL_FILE" <<EOF
# Managed by Unlimited Rotating IPv6 Proxy Server (routed mode)
net.ipv6.ip_nonlocal_bind=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.$IFACE.proxy_ndp=1
net.ipv6.conf.$IFACE.accept_dad=0
net.ipv6.conf.$IFACE.dad_transmits=0
EOF
else
  cat > "$SYSCTL_FILE" <<EOF
# Managed by Unlimited Rotating IPv6 Proxy Server (address mode)
# On-link /64: each source is assigned to the interface, so ip_nonlocal_bind,
# forwarding and proxy_ndp are intentionally omitted (proxying NDP for the whole
# subnet would hijack a shared segment). DAD is suppressed so per-connection
# assignment is instant and warning-free.
net.ipv6.conf.$IFACE.accept_dad=0
net.ipv6.conf.$IFACE.dad_transmits=0
EOF
fi
sysctl --system >/dev/null 2>&1 || true

# ndppd config: routed mode only. Address mode must NOT proxy NDP for the subnet.
if [ "$MODE" = routed ] && [ "$NDPPD_OK" -eq 1 ]; then
  write_ndppd_conf
elif [ "$MODE" = address ]; then
  # withdraw any routed-mode leftovers (e.g. forcing --mode address on a box
  # previously installed routed): the subnet-wide local route and ndppd rule
  # must never remain on a shared on-link segment.
  ip -6 route del local "$SUBNET" dev "$IFACE" 2>/dev/null || true
  [ -f "$NDPPD_BAK" ] && restore_ndppd_conf
fi

cat > "$UNIT_NET" <<'EOF'
[Unit]
Description=sixrelay IPv6 network prerequisites (mode-aware)
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
TimeoutStopSec=20
LimitNOFILE=1048576
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

# ---------- start services ---------------------------------------------------
log "Starting services..."
systemctl daemon-reload
if [ "$MODE" = routed ] && [ "$NDPPD_OK" -eq 1 ]; then
  systemctl enable ndppd >/dev/null 2>&1 || true
  systemctl restart ndppd >/dev/null 2>&1 || true
elif [ "$MODE" = address ]; then
  systemctl disable --now ndppd >/dev/null 2>&1 || true   # no NDP proxying on-link
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
  SIXRELAY_MODE="$MODE" \
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

  Test it:  curl -x socks5h://$PUSER:$PPASS@$LISTEN:$PORT https://ifconfig.co
EOF
exit "$TEST_RC"
