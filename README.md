# Unlimited Rotating IPv6 Proxy Server

Turn a single VPS with a routed **or on-link** IPv6 **/64** into a **session-based rotating IPv6 SOCKS5 proxy** — with one command.

Every new connection egresses from a **random** IPv6 out of the whole `/64` (18 quintillion addresses), that address stays fixed **for the lifetime of the TCP session**, and **concurrent connections always get distinct addresses**. No pool of addresses is pre-created and left to "expire" or churn — the source for a connection exists only while that connection is alive.

```
client ──IPv4/SOCKS5+auth──▶ sixrelay ──IPv6──▶ target
                              per connection: pick a random unused /64 address
                              (held for the session, released on close)
```

The installer **auto-detects** which of two egress modes your provider needs (you can override with `--mode`):

- **routed** — the provider routes the whole `/64` to your host. Sources are bound *without* being assigned to the interface (`ip_nonlocal_bind` + a `local <subnet>` route + `ndppd`). Nothing is ever added to the NIC.
- **address** — the `/64` is *on-link* (a shared L2 segment where the upstream router does neighbor discovery per address). Each source is assigned to the interface (`ip -6 addr add … nodad`) for the life of its connection and removed on close.

## Why this instead of the classic 3proxy setup?

The usual `ipv6-proxy-server` approach assigns thousands of individual `/128` addresses to the NIC and maps one port to each. Those addresses are not owned by the network configuration, so the network manager keeps flushing them and they "die". This project takes the opposite approach:

| | Classic (per-address) | This project |
|---|---|---|
| Addresses on the NIC | thousands of `/128`, permanently | **none** (routed) / **one per live connection** (address) |
| Rotation | one fixed IP per port | **random per connection**, session-stable |
| Concurrency | one IP per port | **every concurrent connection a distinct IP** |
| Pool size | however many you pre-created | the **entire /64** |
| Stability | addresses get flushed / "die" | nothing pre-created to flush |

In **routed** mode it binds otherwise-unassigned addresses (`net.ipv6.ip_nonlocal_bind`), makes the whole subnet locally deliverable (`ip -6 route replace local <subnet>`), and answers neighbor discovery for the subnet with `ndppd`. In **address** mode (on-link `/64`) it instead assigns each source to the interface just for the connection's lifetime — and deliberately does *not* add a `local` route or an ndppd rule for the subnet, so it never claims addresses it isn't actively using on a shared segment. The installer picks the mode automatically.

## Requirements

- Ubuntu **22.04** or **24.04** (fresh install is fine).
- A **routed or on-link IPv6 `/64`** reachable on the server (most IPv6-enabled VPS providers give you one).
- Root access.

> **Note on subnet detection:** the installer derives the subnet from the interface's primary address. Some providers assign a **`/128`** and route a separate **`/64`** that is not visible in `ip addr`. If auto-detection can't find a rotatable subnet, pass it explicitly with `--subnet <your::/64>`.

## Install

```bash
git clone https://github.com/UWASDEV/Unlimited-Rotating-IPv6-Proxy-Server
cd Unlimited-Rotating-IPv6-Proxy-Server
sudo bash install.sh --user yourusername --pass yourpassword
```

The installer auto-detects your interface, subnet, gateway and public IPv4 (see the subnet note above), installs dependencies, sets everything up as systemd services, and runs a self-test. It prints your endpoint and credentials at the end. Re-running it keeps your existing credentials unless you pass `--user`/`--pass`.

Non-interactive / custom:

```bash
sudo bash install.sh --yes \
  --port 1080 --user myuser --pass mysecret \
  --subnet 2a06:9801:6::/64
```

| Option | Meaning |
|---|---|
| `--subnet CIDR` | subnet to rotate within (default: derived from the primary address) |
| `--mode MODE` | `routed` or `address` (default: **auto-detected** by probing egress) |
| `--iface NAME` | interface (default: the IPv6 default-route interface) |
| `--listen ADDR` | listen address (default: primary public IPv4, else `0.0.0.0`) |
| `--port N` | listen port (default: `1080`) |
| `--user` / `--pass` | SOCKS5 credentials (default: randomly generated) |
| `--reserved LIST` | extra comma-separated addresses to never hand out (bare numbers are decimal host parts; use full addresses or `0x…`) |
| `--no-test` | skip the post-install self-test |
| `--no-watchdog` | do not install the IPv6 gateway watchdog (installed by default) |
| `--yes` | accept detected values, non-interactive |
| `--uninstall` | remove everything the installer created |

## Usage

Point any SOCKS5 client at the endpoint. Each connection gets its own IPv6:

```bash
# each request → a different source IPv6
curl -x socks5h://user:pass@SERVER_IP:1080 https://ifconfig.co
curl -x socks5h://user:pass@SERVER_IP:1080 https://ifconfig.co

# 20 concurrent requests → 20 distinct source IPv6 addresses
seq 20 | xargs -P20 -I_ curl -s -x socks5h://user:pass@SERVER_IP:1080 https://ifconfig.co
```

> Don't add curl's `-6` here: `SERVER_IP` is the proxy's (usually IPv4) address, and `-6` forces curl to reach the *proxy* over IPv6, so it fails to connect before any traffic flows. Egress is IPv6 regardless — the proxy resolves the target (`socks5h`) and has only an IPv6 upstream.

- Protocol: **SOCKS5** (TCP `CONNECT`), username/password auth.
- Egress is **IPv6-only** (targets must have an AAAA record). IPv4-only targets are not reachable.

## How it works

- **sixrelay** (`/opt/sixrelay/sixrelay.py`): an asyncio SOCKS5 server. For each connection it draws a random, currently-unused host part of the subnet, binds the upstream socket to that address, and relays. An in-use set guarantees uniqueness across concurrent sessions; the address is released on close. In **address** mode it also assigns the address to the interface before binding and removes it afterwards (and flushes any strays on startup and shutdown, so a crash or `systemctl stop` never leaves addresses behind).
- **Mode auto-detection (address-first)**: on a fresh install the installer first probes real egress from an *interface-assigned* source. If that reaches the internet it chooses **address** — the safer default, since it works on both routed and on-link `/64`s and carries none of the routed NDP hazards. Only if the assigned-source probe fails does it apply the routed prerequisites and probe an *unassigned* source, choosing **routed** if that works. A re-run keeps the mode already chosen (stored in the env file) rather than re-probing.
- **Self-sufficient (no reboot)**: in address mode the installer explicitly sets `forwarding`/`proxy_ndp`/`ip_nonlocal_bind` to `0` and verifies at runtime that no other sysctl source (including `/etc/sysctl.conf`, `/run/sysctl.d`, `/usr/lib/sysctl.d`) forces them back to `1`; conflicting lines it owns are commented out (with a backup) so the hardening persists across reboot without one. It also raises the IPv6 neighbour table thresholds, since the relay churns many neighbours.
- **IPv6 gateway watchdog** (`/opt/sixrelay/ipv6-watchdog.sh` + `sixrelay-watchdog.timer`, every 30s; `--no-watchdog` to skip): providers that send no Router Advertisements make the static default route + a resolvable gateway neighbour the single point of failure. On *total* IPv6 loss the watchdog flushes and re-probes the gateway neighbour and restores the default route if it went missing; it is a no-op when healthy and logs to `journalctl -t sixrelay-watchdog`.
- **sixrelay-net** (`/opt/sixrelay/sixrelay-net.sh`): a tiny loop that re-asserts the network prerequisites so they survive network reconfigurations and reboots. In routed mode that is the sysctls, the `local <subnet>` route and ndppd; in address mode it only suppresses duplicate-address detection (the relay manages addresses itself) and never adds a subnet-wide route or ndppd rule.
- **ndppd** (routed mode only): answers IPv6 neighbor discovery for the whole subnet, needed when the provider treats the `/64` as on-link but routes it entirely to your host. If it can't be installed the installer continues; the self-test's external-egress check tells you whether return traffic actually works. Address mode does not use ndppd.
- Configuration lives in `/etc/sixrelay/sixrelay.env` (including `SIXRELAY_MODE`); both services read it. Edit and `systemctl restart sixrelay`.

## Management

```bash
systemctl status sixrelay          # relay
systemctl status sixrelay-net      # network prerequisites
journalctl -u sixrelay -f          # live logs
python3 /opt/sixrelay/test/selftest.py   # re-run gates (needs env, see install output)
```

## Security notes

- Authentication is **mandatory**; there is no anonymous mode.
- An authenticated client can reach any IPv6 the host can, including provider-internal ranges. Keep the credentials private, and firewall the listen port to trusted clients if needed.
- The listener binds your public IP; restrict with `--listen` or a firewall as appropriate.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Removes the services, files, routes, sysctl drop-in and the gateway watchdog, and restores `/etc/sysctl.conf` if the installer had edited it. The `ndppd` package is left installed; runtime sysctls clear on reboot.

## License

MIT — see [LICENSE](LICENSE).
